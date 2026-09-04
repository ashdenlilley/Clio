import Foundation

@MainActor
final class ConflictResolver {
    enum ResolutionError: LocalizedError, Equatable {
        case noConflict
        case conflictChanged

        var errorDescription: String? {
            switch self {
            case .noConflict:
                "This document no longer has an external-edit conflict."
            case .conflictChanged:
                "The outside version changed again. Review the refreshed conflict before continuing."
            }
        }
    }

    private let recoveryStore: any RecoveryPersisting

    init(recoveryStore: any RecoveryPersisting = RecoveryStore()) {
        self.recoveryStore = recoveryStore
    }

    @discardableResult
    func resolve(
        _ choice: ConflictChoice,
        document: Document,
        workspace: Workspace,
        registry: DocumentBufferRegistry? = nil
    ) async throws -> RecoveryReceipt? {
        guard let conflict = document.conflict,
              let expectedExternal = conflict.external.revision else {
            throw ResolutionError.noConflict
        }

        let conflictID = conflict.id
        let generation = BufferGeneration(
            bufferID: document.id.rawValue,
            revision: document.revision
        )
        var current = try validatedDiskState(
            document: document,
            workspace: workspace,
            conflictID: conflictID,
            generation: generation,
            expectedExternal: expectedExternal
        )

        // A rare double interleaving can displace more than one outside
        // revision. Preserve those before applying any selected resolution.
        for side in conflict.additionalExternalVersions ?? [] {
            _ = try await preserveAndRelease(
                side,
                documentID: document.id,
                filename: document.filename
            )
            current = try validatedDiskState(
                document: document,
                workspace: workspace,
                conflictID: conflictID,
                generation: generation,
                expectedExternal: expectedExternal
            )
        }

        let receipt: RecoveryReceipt?
        switch choice {
        case .keepClio:
            receipt = try await recoveryStore.preserve(
                documentID: document.id,
                filename: document.filename,
                data: current.data,
                sourceModificationDate: current.revision.modificationDate
            )
            current = try validatedDiskState(
                document: document,
                workspace: workspace,
                conflictID: conflictID,
                generation: generation,
                expectedExternal: expectedExternal
            )
            _ = try workspace.replaceAfterConflict(
                document,
                expectedExternalRevision: current.revision
            )
            releaseRetainedFiles(in: conflict.external)

        case .loadExternal:
            let localData = Data(document.text.utf8)
            receipt = try await recoveryStore.preserve(
                documentID: document.id,
                filename: document.filename,
                data: localData,
                sourceModificationDate: nil
            )
            current = try validatedDiskState(
                document: document,
                workspace: workspace,
                conflictID: conflictID,
                generation: generation,
                expectedExternal: expectedExternal
            )
            guard let source = current.source else {
                throw Document.ReadError.invalidUTF8(document.fileURL ?? workspace.rootURL)
            }
            document.applyExternal(
                source: source,
                revision: current.revision
            )
            releaseRetainedFiles(in: conflict.external)

        case .keepBoth:
            _ = try validatedDiskState(
                document: document,
                workspace: workspace,
                conflictID: conflictID,
                generation: generation,
                expectedExternal: expectedExternal
            )
            receipt = nil
            _ = try workspace.saveConflictCopy(document)
            registry?.detach(document.id, from: conflict.locator)
            releaseRetainedFiles(in: conflict.external)
        }

        registry?.updateAliases(for: document, in: workspace)
        return receipt
    }

    func detachAfterExternalDeletion(
        _ document: Document,
        workspace: Workspace,
        registry: DocumentBufferRegistry?
    ) async throws {
        try workspace.checkpointCrashRecovery(
            for: document,
            reason: .externalDeletion
        )
        var preservedDigests: Set<String> = []
        var locator = document.conflict?.locator ?? document.previousLocator

        while let conflict = document.conflict {
            locator = conflict.locator
            let versions = (conflict.additionalExternalVersions ?? []) + [conflict.external]
            let pending = versions.filter {
                !preservedDigests.contains(Self.digest(for: $0))
            }
            guard !pending.isEmpty else { break }
            for side in pending {
                _ = try await preserveAndRelease(
                    side,
                    documentID: document.id,
                    filename: document.filename
                )
                preservedDigests.insert(Self.digest(for: side))
            }
        }

        guard let finalConflict = document.conflict, let locator else { return }
        if let fileURL = document.fileURL,
           FileManager.default.fileExists(atPath: fileURL.path) {
            try workspace.reconcileExternalChange(for: document)
            throw ResolutionError.conflictChanged
        }
        for side in (finalConflict.additionalExternalVersions ?? []) + [finalConflict.external]
        where preservedDigests.contains(Self.digest(for: side)) {
            releaseRetainedFiles(in: side)
        }
        document.markUnbacked(previous: locator)
        registry?.detach(document.id, from: locator)
    }
}

private extension ConflictResolver {
    typealias CurrentDiskState = (data: Data, source: String?, revision: DiskRevision)

    func validatedDiskState(
        document: Document,
        workspace: Workspace,
        conflictID: UUID,
        generation: BufferGeneration,
        expectedExternal: DiskRevision
    ) throws -> CurrentDiskState {
        let current = try workspace.readDiskSnapshot(for: document)
        if !Workspace.sameContent(current.revision, expectedExternal) {
            try workspace.reconcileExternalChange(for: document)
            throw ResolutionError.conflictChanged
        }
        guard document.conflict?.id == conflictID,
              document.id.rawValue == generation.bufferID,
              document.revision == generation.revision else {
            throw ResolutionError.conflictChanged
        }
        return current
    }

    func preserveAndRelease(
        _ side: ConflictSide,
        documentID: DocumentID,
        filename: String
    ) async throws -> RecoveryReceipt {
        let receipt = try await recoveryStore.preserve(
            documentID: documentID,
            filename: filename,
            data: side.data,
            sourceModificationDate: side.modificationDate
        )
        releaseRetainedFiles(in: side)
        return receipt
    }

    func releaseRetainedFiles(in side: ConflictSide) {
        for url in side.retainedURLs {
            if url.lastPathComponent.hasPrefix(AtomicWriteTransactions.temporaryPrefix) {
                try? AtomicWriteTransactions.discardRetainedSidecar(at: url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    nonisolated static func digest(for side: ConflictSide) -> String {
        side.revision?.contentDigest ?? DocumentRevisionReader.digest(side.data)
    }
}

extension DocumentConflict {
    var conciseDiff: String {
        let localLines = clio.source.split(separator: "\n", omittingEmptySubsequences: false)
        let externalLines = external.source.split(separator: "\n", omittingEmptySubsequences: false)
        let maximum = max(localLines.count, externalLines.count)
        var removed: [String] = []
        var added: [String] = []

        for index in 0..<maximum {
            let local = index < localLines.count ? String(localLines[index]) : nil
            let outside = index < externalLines.count ? String(externalLines[index]) : nil
            guard local != outside else { continue }
            if let local, removed.count < 3 { removed.append("− \(local)") }
            if let outside, added.count < 3 { added.append("+ \(outside)") }
        }

        let changed = (0..<maximum).reduce(into: 0) { count, index in
            let local = index < localLines.count ? localLines[index] : nil
            let outside = index < externalLines.count ? externalLines[index] : nil
            if local != outside { count += 1 }
        }
        let preview = (removed + added).joined(separator: "\n")
        return changed > 6 ? "\(preview)\n… \(changed - 6) more changed lines" : preview
    }
}
