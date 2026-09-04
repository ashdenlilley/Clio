import Foundation

/// Serializes export commits away from MainActor. Existing-destination hashes,
/// staged-file mapping, recovery checkpoint copies, and fsync work therefore
/// never consume the editor's frame budget.
actor DocumentExportInstaller {
    private let fileManager: FileManager
    private let recoveryCheckpointStore: any ExportRecoveryCheckpointing
    private let directoryWriter: any AtomicFileWriting
    private let fileGrantWriter: any AtomicFileWriting

    init(
        fileManager: FileManager = .default,
        recoveryCheckpointStore: any ExportRecoveryCheckpointing = ExportRecoveryCheckpointStore.shared,
        directoryWriter: any AtomicFileWriting = AtomicFileWriter(),
        fileGrantWriter: any AtomicFileWriting = ExportFileGrantWriter()
    ) {
        self.fileManager = fileManager
        self.recoveryCheckpointStore = recoveryCheckpointStore
        self.directoryWriter = directoryWriter
        self.fileGrantWriter = fileGrantWriter
    }

    func install(
        _ staged: StagedDocumentExport,
        strategy: ExportRecoveryStrategy
    ) async throws -> ExportReceipt {
        let checkpoint: ExportRecoveryCheckpoint?
        if strategy == .appContainerCheckpoint {
            checkpoint = try await recoveryCheckpointStore.checkpoint(staged)
            if Task.isCancelled {
                if let checkpoint {
                    try? await recoveryCheckpointStore.complete(checkpoint)
                }
                throw CancellationError()
            }
        } else {
            checkpoint = nil
        }

        do {
            // Synchronous by design: after the last cancellation check the
            // filesystem commit and receipt are one non-suspending boundary.
            let receipt = try staged.install(
                fileManager: fileManager,
                writer: strategy == .appContainerCheckpoint
                    ? fileGrantWriter
                    : directoryWriter
            )
            if let checkpoint {
                Task(priority: .utility) { [recoveryCheckpointStore] in
                    try? await recoveryCheckpointStore.complete(checkpoint)
                }
            }
            return receipt
        } catch {
            if let checkpoint {
                try? await recoveryCheckpointStore.complete(checkpoint)
            }
            throw error
        }
    }

    func discard(_ staged: StagedDocumentExport) {
        staged.discard(fileManager: fileManager)
    }
}
