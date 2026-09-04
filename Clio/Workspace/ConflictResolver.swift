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

    private let recoveryStore: RecoveryStore

    init(recoveryStore: RecoveryStore = RecoveryStore()) {
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

        let current = try workspace.readDiskSnapshot(for: document)
        guard Workspace.sameContent(current.revision, expectedExternal) else {
            try workspace.reconcileExternalChange(for: document)
            throw ResolutionError.conflictChanged
        }

        // A rare double interleaving can displace more than one outside
        // revision. Preserve those before applying any selected resolution.
        for side in conflict.additionalExternalVersions ?? [] {
            _ = try await recoveryStore.preserve(
                documentID: document.id,
                filename: document.filename,
                source: side.source,
                date: side.modificationDate
            )
        }

        let receipt: RecoveryReceipt?
        switch choice {
        case .keepClio:
            receipt = try await recoveryStore.preserve(
                documentID: document.id,
                filename: document.filename,
                source: current.source,
                date: current.revision.modificationDate
            )
            _ = try workspace.replaceAfterConflict(
                document,
                expectedExternalRevision: current.revision
            )

        case .loadExternal:
            receipt = try await recoveryStore.preserve(
                documentID: document.id,
                filename: document.filename,
                source: document.text,
                date: Date()
            )
            document.applyExternal(
                source: current.source,
                revision: current.revision
            )

        case .keepBoth:
            receipt = nil
            _ = try workspace.saveConflictCopy(document)
            registry?.detach(document.id, from: conflict.locator)
        }

        registry?.updateAliases(for: document, in: workspace)
        try await recoveryStore.pruneExpired()
        return receipt
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
