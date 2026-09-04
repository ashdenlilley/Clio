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
        if let registry {
            return try await registry.withSettledDocumentIO(for: document.id) {
                try await self.resolveSettled(
                    choice,
                    document: document,
                    workspace: workspace,
                    registry: registry
                )
            }
        }
        return try await resolveSettled(
            choice,
            document: document,
            workspace: workspace,
            registry: nil
        )
    }

    func detachAfterExternalDeletion(
        _ document: Document,
        workspace: Workspace,
        registry: DocumentBufferRegistry?
    ) async throws {
        if let registry {
            try await registry.withSettledDocumentIO(for: document.id) {
                try await self.detachSettledAfterExternalDeletion(
                    document,
                    workspace: workspace,
                    registry: registry
                )
            }
            return
        }
        try await detachSettledAfterExternalDeletion(
            document,
            workspace: workspace,
            registry: nil
        )
    }
}

private extension ConflictResolver {
    func resolveSettled(
        _ choice: ConflictChoice,
        document: Document,
        workspace: Workspace,
        registry: DocumentBufferRegistry?
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
        var current = try await validatedDiskState(
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
            current = try await validatedDiskState(
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
            current = try await validatedDiskState(
                document: document,
                workspace: workspace,
                conflictID: conflictID,
                generation: generation,
                expectedExternal: expectedExternal
            )
            do {
                _ = try await workspace.replaceAfterConflictInBackground(
                    document,
                    conflictID: conflictID,
                    expectedExternalRevision: current.revision
                )
            } catch Workspace.WorkspaceError.externalConflict {
                throw ResolutionError.conflictChanged
            }
            await releaseRetainedFiles(in: conflict.external)

        case .loadExternal:
            let localSnapshot = document.snapshot()
            let localData = await Task.detached(priority: .utility) {
                Data(localSnapshot.text.utf8)
            }.value
            try validateDocumentGeneration(
                document,
                conflictID: conflictID,
                generation: generation
            )
            receipt = try await recoveryStore.preserve(
                documentID: document.id,
                filename: document.filename,
                data: localData,
                sourceModificationDate: nil
            )
            current = try await validatedDiskState(
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
                revision: current.revision,
                utf8ByteCount: current.data.count
            )
            await releaseRetainedFiles(in: conflict.external)

        case .keepBoth:
            current = try await validatedDiskState(
                document: document,
                workspace: workspace,
                conflictID: conflictID,
                generation: generation,
                expectedExternal: expectedExternal
            )
            receipt = nil
            do {
                _ = try await workspace.saveConflictCopyInBackground(
                    document,
                    conflictID: conflictID,
                    expectedExternalRevision: current.revision
                )
            } catch Workspace.WorkspaceError.externalConflict {
                throw ResolutionError.conflictChanged
            }
            registry?.detach(document.id, from: conflict.locator)
            await releaseRetainedFiles(in: conflict.external)
        }

        registry?.updateAliases(for: document, in: workspace)
        return receipt
    }

    func detachSettledAfterExternalDeletion(
        _ document: Document,
        workspace: Workspace,
        registry: DocumentBufferRegistry?
    ) async throws {
        try await workspace.checkpointCrashRecoveryInBackground(
            for: document,
            reason: .externalDeletion
        )
        var preservedDigests: Set<String> = []
        var locator = document.conflict?.locator ?? document.previousLocator

        while let conflict = document.conflict {
            locator = conflict.locator
            let versions = (conflict.additionalExternalVersions ?? []) + [conflict.external]
            var pending: [(side: ConflictSide, digest: String)] = []
            for side in versions {
                let digest = await Self.digest(for: side)
                if !preservedDigests.contains(digest) {
                    pending.append((side, digest))
                }
            }
            guard !pending.isEmpty else { break }
            for item in pending {
                _ = try await preserveAndRelease(
                    item.side,
                    documentID: document.id,
                    filename: document.filename
                )
                preservedDigests.insert(item.digest)
            }
        }

        guard let finalConflict = document.conflict, let locator else { return }
        if let fileURL = document.fileURL,
           await workspace.fileExistsInBackground(at: fileURL) {
            try await workspace.reconcileExternalChangeInBackground(for: document)
            throw ResolutionError.conflictChanged
        }
        for side in (finalConflict.additionalExternalVersions ?? []) + [finalConflict.external] {
            if preservedDigests.contains(await Self.digest(for: side)) {
                await releaseRetainedFiles(in: side)
            }
        }
        document.markUnbacked(previous: locator)
        registry?.detach(document.id, from: locator)
    }

    func validatedDiskState(
        document: Document,
        workspace: Workspace,
        conflictID: UUID,
        generation: BufferGeneration,
        expectedExternal: DiskRevision
    ) async throws -> WorkspaceDiskState {
        let current = try await workspace.readDiskSnapshotInBackground(
            for: document,
            conflictID: conflictID
        )
        if !Workspace.sameContent(current.revision, expectedExternal) {
            try await workspace.reconcileExternalChangeInBackground(for: document)
            throw ResolutionError.conflictChanged
        }
        try validateDocumentGeneration(
            document,
            conflictID: conflictID,
            generation: generation
        )
        return current
    }

    func validateDocumentGeneration(
        _ document: Document,
        conflictID: UUID,
        generation: BufferGeneration
    ) throws {
        guard document.conflict?.id == conflictID,
              document.id.rawValue == generation.bufferID,
              document.revision == generation.revision else {
            throw ResolutionError.conflictChanged
        }
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
        await releaseRetainedFiles(in: side)
        return receipt
    }

    func releaseRetainedFiles(in side: ConflictSide) async {
        let retainedURLs = side.retainedURLs
        await Task.detached(priority: .utility) {
            for url in retainedURLs {
                if url.lastPathComponent.hasPrefix(AtomicWriteTransactions.temporaryPrefix) {
                    try? AtomicWriteTransactions.discardRetainedSidecar(at: url)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }.value
    }

    nonisolated static func digest(for side: ConflictSide) async -> String {
        if let digest = side.revision?.contentDigest { return digest }
        let data = side.data
        return await Task.detached(priority: .utility) {
            DocumentRevisionReader.digest(data)
        }.value
    }
}

extension DocumentConflict {
    var conciseDiff: String {
        let preview = ConflictPreviewBuilder.makePreview(
            local: clio.data,
            external: external.data
        )
        return preview == "The text is identical." ? "" : preview
    }
}
