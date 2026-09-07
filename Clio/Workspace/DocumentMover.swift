import AppKit
import Darwin
import Foundation

@MainActor
final class DocumentMover {
    private struct SettledSource {
        let snapshot: Document.Snapshot
        let disk: (data: Data, revision: DiskRevision)
    }

    enum MoveError: LocalizedError {
        case destinationChanged(URL)
        case sourceChanged(URL)

        var errorDescription: String? {
            switch self {
            case .destinationChanged(let url):
                "\(url.lastPathComponent) changed while Clio was preparing the move. Nothing was replaced."
            case .sourceChanged(let url):
                "\(url.lastPathComponent) changed outside Clio while the move was being prepared. Review the conflict before moving it."
            }
        }
    }
    private let recoveryStore: any RecoveryPersisting
    private let fileManager: FileManager
    private let fileIO: FileMutationExecutor
    private let trashOperation: ((URL) throws -> URL?)?

    init(
        recoveryStore: any RecoveryPersisting = RecoveryStore(),
        fileManager: FileManager = .default,
        writer: any AtomicFileWriting = AtomicFileWriter(),
        trashOperation: ((URL) throws -> URL?)? = nil
    ) {
        self.recoveryStore = recoveryStore
        self.fileManager = fileManager
        fileIO = FileMutationExecutor(fileManager: fileManager, writer: writer)
        self.trashOperation = trashOperation
    }

    func move(
        _ document: Document,
        from sourceWorkspace: Workspace,
        to destinationWorkspace: Workspace,
        parentRelativePath: String = "",
        preferredFilename: String? = nil,
        collisionChoice: CollisionChoice? = nil,
        approvedCollision: FileCollision? = nil,
        registry: DocumentBufferRegistry? = nil,
        validateAuthority: @MainActor () throws -> Void = {}
    ) async throws -> FileMutationOutcome {
        try validateAuthority()
        registry?.suspendAutosave(for: document.id)
        defer { registry?.resumeAutosave(for: document.id) }
        if let registry {
            repeat {
                try await registry.settlePendingEditorEdits(for: document.id)
                await registry.settlePendingFileIO(for: document.id)
            } while registry.hasUnsettledEditorEdits(for: document.id)
                || registry.hasActiveFileIO(for: document.id)
        }

        var sourceAtApproval = try await settledSourceSnapshot(
            document,
            workspace: sourceWorkspace,
            registry: registry
        )
        guard let sourceURL = sourceAtApproval.snapshot.fileURL else {
            return .cancelled
        }

        let filename = Workspace.safeFilename(
            from: preferredFilename ?? sourceURL.lastPathComponent
        )
        let relativePath = [parentRelativePath, filename]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        let proposedLocator = try DocumentLocator(
            workspaceID: destinationWorkspace.id,
            relativePath: relativePath
        )
        var destinationURL = try destinationWorkspace.fileURL(for: proposedLocator)

        if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL {
            return .completed(proposedLocator)
        }

        try validateAuthority()
        try await fileIO.createParentDirectory(
            for: destinationURL,
            inside: destinationWorkspace.rootURL
        )

        if await fileIO.fileExists(at: destinationURL) {
            let collision = FileCollision(
                proposedLocator: proposedLocator,
                existingRevision: try? await fileIO.revision(at: destinationURL)
            )
            guard let collisionChoice else { return .collision(collision) }
            switch collisionChoice {
            case .cancel:
                return .cancelled
            case .keepBoth:
                destinationURL = try await fileIO.availableSibling(for: destinationURL)
            case .replace:
                let replaced = try await fileIO.snapshot(at: destinationURL)
                guard approvedCollision?.proposedLocator == proposedLocator,
                      let approvedRevision = approvedCollision?.existingRevision,
                      replaced.revision == approvedRevision else {
                    return .collision(FileCollision(
                        proposedLocator: proposedLocator,
                        existingRevision: replaced.revision
                    ))
                }
                let displacedDocument = registry?.document(
                    at: destinationURL,
                    in: destinationWorkspace
                )
                let displacedSnapshot: Document.Snapshot?
                if let displacedDocument, displacedDocument !== document,
                   let registry {
                    displacedSnapshot = try await registry.withSettledEditorEdits(
                        for: displacedDocument.id
                    ) {
                        displacedDocument.snapshot()
                    }
                } else {
                    displacedSnapshot = nil
                }
                if let displacedSnapshot, displacedSnapshot.isDirty {
                    let displacedData = await Task.detached(priority: .utility) {
                        Data(displacedSnapshot.text.utf8)
                    }.value
                    _ = try await recoveryStore.preserve(
                        documentID: displacedSnapshot.documentID,
                        filename: displacedSnapshot.preferredFilename,
                        data: displacedData,
                        sourceModificationDate: nil
                    )
                }
                _ = try await recoveryStore.preserve(
                    documentID: document.id,
                    filename: destinationURL.lastPathComponent,
                    data: replaced.data,
                    sourceModificationDate: replaced.revision.modificationDate
                )
                sourceAtApproval = try await settledSourceSnapshot(
                    document,
                    workspace: sourceWorkspace,
                    registry: registry
                )
                let installedData = sourceAtApproval.disk.data
                let snapshot = sourceAtApproval.snapshot
                let moveTransaction = try await fileIO.beginMoveTransaction(
                    documentID: document.id,
                    generation: BufferGeneration(
                        bufferID: document.id.rawValue,
                        revision: snapshot.revision
                    ),
                    sourceRootURL: sourceWorkspace.rootURL,
                    destinationRootURL: destinationWorkspace.rootURL,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceRevision: sourceAtApproval.disk.revision,
                    destinationRevision: replaced.revision,
                    candidate: installedData
                )
                let replaceOutcome: AtomicReplaceOutcome
                do {
                    replaceOutcome = try await fileIO.replace(
                        contents: installedData,
                        at: destinationURL,
                        onlyIf: replaced.revision
                    )
                } catch {
                    _ = try? await fileIO.abortMoveTransactionIfUncommitted(moveTransaction)
                    throw error
                }
                guard case .replaced = replaceOutcome else {
                    if case .revisionMismatch(let retainedURL?) = replaceOutcome {
                        let retained = try await fileIO.snapshot(at: retainedURL)
                        _ = try await recoveryStore.preserve(
                            documentID: document.id,
                            filename: destinationURL.lastPathComponent,
                            data: retained.data,
                            sourceModificationDate: retained.revision.modificationDate
                        )
                        try await fileIO.discardRetainedSidecar(at: retainedURL)
                    }
                    _ = try? await fileIO.abortMoveTransactionIfUncommitted(moveTransaction)
                    throw MoveError.destinationChanged(destinationURL)
                }

                let recoveryNotice = await quarantineAndValidateSource(
                    moveTransaction,
                    approvedSource: sourceAtApproval.disk.revision,
                    document: document,
                    sourceWorkspace: sourceWorkspace
                )
                if let displacedDocument, displacedDocument !== document {
                    displacedDocument.markUnbacked(previous: proposedLocator)
                    registry?.detach(displacedDocument.id, from: proposedLocator)
                }
                let result = try await finishMove(
                    document,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceWorkspace: sourceWorkspace,
                    destinationWorkspace: destinationWorkspace,
                    installedData: installedData,
                    registry: registry
                )
                if let recoveryNotice, case .completed(let locator) = result {
                    return .completedWithRecovery(locator, recoveryNotice)
                }
                return result
            }
        }

        sourceAtApproval = try await settledSourceSnapshot(
            document,
            workspace: sourceWorkspace,
            registry: registry
        )
        let installedData = sourceAtApproval.disk.data
        let moveTransaction = try await fileIO.beginMoveTransaction(
            documentID: document.id,
            generation: BufferGeneration(
                bufferID: document.id.rawValue,
                revision: sourceAtApproval.snapshot.revision
            ),
            sourceRootURL: sourceWorkspace.rootURL,
            destinationRootURL: destinationWorkspace.rootURL,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            sourceRevision: sourceAtApproval.disk.revision,
            destinationRevision: nil,
            candidate: installedData
        )
        let created: Bool
        do {
            try validateAuthority()
            created = try await fileIO.create(contents: installedData, at: destinationURL)
        } catch {
            _ = try? await fileIO.abortMoveTransactionIfUncommitted(moveTransaction)
            throw error
        }
        guard created else {
            try? await fileIO.finishMoveTransaction(
                moveTransaction,
                removeQuarantine: false
            )
            let locator = try destinationWorkspace.locator(for: destinationURL)
            return .collision(FileCollision(
                proposedLocator: locator,
                existingRevision: try? await fileIO.revision(at: destinationURL)
            ))
        }
        let recoveryNotice = await quarantineAndValidateSource(
            moveTransaction,
            approvedSource: sourceAtApproval.disk.revision,
            document: document,
            sourceWorkspace: sourceWorkspace
        )
        let result = try await finishMove(
            document,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            sourceWorkspace: sourceWorkspace,
            destinationWorkspace: destinationWorkspace,
            installedData: installedData,
            registry: registry
        )
        if let recoveryNotice, case .completed(let locator) = result {
            return .completedWithRecovery(locator, recoveryNotice)
        }
        return result
    }

    @discardableResult
    func moveToTrash(
        _ document: Document,
        workspace: Workspace,
        registry: DocumentBufferRegistry? = nil
    ) throws -> URL? {
        if registry?.hasUnsettledEditorEdits(for: document.id) == true {
            throw EditorSynchronizationError.editorMaterializationInProgress
        }
        if registry?.hasActiveFileIO(for: document.id) == true
            || document.utf8ByteCount > Document.maximumSynchronousByteCount {
            throw Autosaver.SaveError.backgroundSaveInProgress
        }
        guard let fileURL = document.fileURL else { return nil }
        _ = try workspace.save(document)
        registry?.cancelAutosave(for: document.id)
        let oldLocator = try workspace.locator(for: fileURL)
        let resultingURL: URL?
        if let trashOperation {
            resultingURL = try trashOperation(fileURL)
        } else {
            var trashedURL: NSURL?
            try fileManager.trashItem(at: fileURL, resultingItemURL: &trashedURL)
            resultingURL = trashedURL as URL?
        }
        document.markUnbacked(previous: oldLocator)
        registry?.detach(document.id, from: oldLocator)
        return resultingURL
    }

    /// Awaitable user-command path. Dirty bytes are durably settled before
    /// the filesystem mutation, while a synchronous window/quit callback can
    /// continue to refuse instead of blocking MainActor on a large document.
    @discardableResult
    func moveToTrashInBackground(
        _ document: Document,
        workspace: Workspace,
        registry: DocumentBufferRegistry? = nil
    ) async throws -> URL? {
        registry?.suspendAutosave(for: document.id)
        defer { registry?.resumeAutosave(for: document.id) }

        if let registry {
            repeat {
                try await registry.settlePendingEditorEdits(for: document.id)
                await registry.settlePendingFileIO(for: document.id)
            } while registry.hasUnsettledEditorEdits(for: document.id)
                || registry.hasActiveFileIO(for: document.id)
        }

        for _ in 0..<8 {
            guard let fileURL = document.fileURL else { return nil }
            if document.isDirty {
                _ = try await workspace.saveInBackground(document)
            }
            if let registry {
                try await registry.settlePendingEditorEdits(for: document.id)
            }
            let snapshot = document.snapshot()
            guard !snapshot.isDirty,
                  snapshot.fileURL?.standardizedFileURL
                    == fileURL.standardizedFileURL else { continue }

            let oldLocator = try workspace.locator(for: fileURL)
            let resultingURL: URL?
            if let trashOperation {
                // Test/custom adapters are expected to be bounded. The app's
                // real FileManager operation always runs on `fileIO` below.
                resultingURL = try trashOperation(fileURL)
            } else {
                resultingURL = try await fileIO.trash(
                    at: fileURL,
                    expectedRevision: snapshot.expectedDiskRevision
                )
            }
            guard document.fileURL?.standardizedFileURL
                    == fileURL.standardizedFileURL else {
                throw MoveError.sourceChanged(fileURL)
            }
            registry?.cancelAutosave(for: document.id)
            document.markUnbacked(previous: oldLocator)
            registry?.detach(document.id, from: oldLocator)
            return resultingURL
        }

        throw MoveError.sourceChanged(document.fileURL ?? workspace.rootURL)
    }

    func reveal(_ document: Document) {
        guard let fileURL = document.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func settledSourceSnapshot(
        _ document: Document,
        workspace: Workspace,
        registry: DocumentBufferRegistry?
    ) async throws -> SettledSource {
        for _ in 0..<8 {
            if let registry {
                try await registry.settlePendingEditorEdits(for: document.id)
                await registry.settlePendingFileIO(for: document.id)
            }
            if document.isDirty {
                _ = try await workspace.saveInBackground(document)
            }
            if let registry {
                try await registry.settlePendingEditorEdits(for: document.id)
            }

            let snapshot = document.snapshot()
            guard !snapshot.isDirty, let sourceURL = snapshot.fileURL else {
                continue
            }
            let disk = try await fileIO.snapshot(at: sourceURL)
            guard document.revision == snapshot.revision,
                  document.fileURL?.standardizedFileURL
                    == sourceURL.standardizedFileURL,
                  !document.isDirty else {
                continue
            }
            if let expected = snapshot.expectedDiskRevision,
               !Workspace.sameContent(disk.revision, expected) {
                try await workspace.reconcileExternalChangeInBackground(for: document)
                throw MoveError.sourceChanged(sourceURL)
            }
            return SettledSource(snapshot: snapshot, disk: disk)
        }
        throw MoveError.sourceChanged(document.fileURL ?? workspace.rootURL)
    }

    private func quarantineAndValidateSource(
        _ transaction: InterruptedMoveContext,
        approvedSource: DiskRevision,
        document: Document,
        sourceWorkspace: Workspace
    ) async -> FileRecoveryNotice? {
        let sourceURL = transaction.manifest.sourceURL
        do {
            try await fileIO.quarantineSource(transaction)
            if try await fileIO.finishMoveTransactionIfSourceMatches(
                transaction,
                revision: approvedSource
            ) {
                return nil
            }

            let quarantined = try await fileIO.quarantinedSnapshot(transaction)
            var journalURL: URL?
            do {
                journalURL = try await sourceWorkspace.checkpointCrashRecoveryInBackground(
                    data: quarantined.data,
                    documentID: document.id,
                    generation: transaction.manifest.generation,
                    filename: sourceURL.lastPathComponent,
                    targetURL: sourceURL,
                    reason: .interruptedMove
                )
                if journalURL != nil {
                    try await fileIO.finishMoveTransaction(
                        transaction,
                        removeQuarantine: true
                    )
                }
            } catch {
                // The manifest and quarantine remain discoverable. If the WAL
                // write succeeded, report that durable location even when
                // subsequent cleanup failed.
            }
            return FileRecoveryNotice(
                transactionID: transaction.manifest.id,
                sourceURL: sourceURL,
                retainedURL: journalURL ?? transaction.manifest.quarantineURL
            )
        } catch {
            return FileRecoveryNotice(
                transactionID: transaction.manifest.id,
                sourceURL: sourceURL,
                retainedURL: fileManager.fileExists(
                    atPath: transaction.manifest.quarantineURL.path
                ) ? transaction.manifest.quarantineURL : sourceURL
            )
        }
    }

    private func finishMove(
        _ document: Document,
        sourceURL: URL,
        destinationURL: URL,
        sourceWorkspace: Workspace,
        destinationWorkspace: Workspace,
        installedData: Data?,
        registry: DocumentBufferRegistry?
    ) async throws -> FileMutationOutcome {
        let oldLocator = try sourceWorkspace.locator(for: sourceURL)
        let newLocator = try destinationWorkspace.locator(for: destinationURL)
        let baseRevision: DiskRevision?
        if let installedData {
            baseRevision = await fileIO.contentRevision(for: installedData)
        } else {
            baseRevision = document.expectedDiskRevision
        }
        document.didMove(to: destinationURL, revision: baseRevision)
        registry?.removeLocator(oldLocator, for: document.id)
        registry?.updateAliases(for: document, in: destinationWorkspace)
        registry?.retarget(document, to: destinationWorkspace)
        try await destinationWorkspace.reconcileExternalChangeInBackground(for: document)
        if document.conflict != nil {
            registry?.cancelAutosave(for: document.id)
        }
        return .completed(newLocator)
    }

}

/// Serial background executor for hydration, hashing, fsync-backed swaps, and
/// physical moves. Observable document state remains MainActor-confined.
private actor FileMutationExecutor {
    private let fileManager: FileManager
    private let writer: any AtomicFileWriting

    init(fileManager: FileManager, writer: any AtomicFileWriting) {
        self.fileManager = fileManager
        self.writer = writer
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func createParentDirectory(
        for url: URL,
        inside rootURL: URL
    ) throws {
        try RootConfinedDirectoryCreator.createParent(
            of: url,
            inside: rootURL
        )
    }

    func snapshot(at url: URL) throws -> (data: Data, revision: DiskRevision) {
        try DocumentRevisionReader.documentSnapshot(at: url)
    }

    func revision(at url: URL) throws -> DiskRevision {
        try DocumentRevisionReader.revision(at: url)
    }

    func contentRevision(for data: Data) -> DiskRevision {
        DiskRevision(
            modificationDate: .distantPast,
            byteCount: Int64(data.count),
            contentDigest: DocumentRevisionReader.digest(data)
        )
    }

    func replace(
        contents: Data,
        at url: URL,
        onlyIf revision: DiskRevision
    ) throws -> AtomicReplaceOutcome {
        try writer.replace(contents: contents, at: url, onlyIf: revision)
    }

    func create(contents: Data, at url: URL) throws -> Bool {
        try writer.create(contents: contents, at: url)
    }

    func remove(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func trash(
        at url: URL,
        expectedRevision: DiskRevision?
    ) throws -> URL? {
        if let expectedRevision {
            let current = try DocumentRevisionReader.revision(at: url)
            guard Workspace.sameContent(current, expectedRevision) else {
                throw DocumentMover.MoveError.sourceChanged(url)
            }
        }
        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    func discardRetainedSidecar(at url: URL) throws {
        try AtomicWriteTransactions.discardRetainedSidecar(at: url)
    }

    func beginMoveTransaction(
        documentID: DocumentID,
        generation: BufferGeneration,
        sourceRootURL: URL,
        destinationRootURL: URL,
        sourceURL: URL,
        destinationURL: URL,
        sourceRevision: DiskRevision,
        destinationRevision: DiskRevision?,
        candidate: Data
    ) throws -> InterruptedMoveContext {
        try InterruptedMoveTransactions.begin(
            documentID: documentID,
            generation: generation,
            sourceRootURL: sourceRootURL,
            destinationRootURL: destinationRootURL,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            sourceRevision: sourceRevision,
            destinationRevision: destinationRevision,
            candidate: candidate
        )
    }

    func quarantineSource(_ context: InterruptedMoveContext) throws {
        try InterruptedMoveTransactions.quarantineSource(context)
    }

    func quarantinedSnapshot(
        _ context: InterruptedMoveContext
    ) throws -> (data: Data, revision: DiskRevision) {
        try DocumentRevisionReader.documentSnapshot(
            at: context.manifest.quarantineURL
        )
    }

    func finishMoveTransactionIfSourceMatches(
        _ context: InterruptedMoveContext,
        revision expected: DiskRevision
    ) throws -> Bool {
        let current = try DocumentRevisionReader.revision(
            at: context.manifest.quarantineURL
        )
        guard Workspace.sameContent(current, expected) else { return false }
        try InterruptedMoveTransactions.finish(context, removeQuarantine: true)
        return true
    }

    func finishMoveTransaction(
        _ context: InterruptedMoveContext,
        removeQuarantine: Bool
    ) throws {
        try InterruptedMoveTransactions.finish(
            context,
            removeQuarantine: removeQuarantine
        )
    }

    func abortMoveTransactionIfUncommitted(
        _ context: InterruptedMoveContext
    ) throws -> Bool {
        try InterruptedMoveTransactions.abortIfDestinationUnchanged(context)
    }

    func move(from sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func availableSibling(for url: URL) throws -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        for number in 2...10_000 {
            let name = ext.isEmpty
                ? "\(stem) (\(number))"
                : "\(stem) (\(number)).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        throw Workspace.WorkspaceError.noAvailableFilename(url.lastPathComponent)
    }
}

/// Creates missing destination folders from a descriptor anchored at the
/// authorized workspace root. Every component is opened with `O_NOFOLLOW`, so
/// a concurrent symlink replacement cannot redirect creation outside the
/// workspace grant.
enum RootConfinedDirectoryCreator {
    static func createParent(
        of destinationURL: URL,
        inside rootURL: URL,
        beforeOpeningComponent: ((URL) throws -> Void)? = nil
    ) throws {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destinationURL.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        let rootComponents = root.pathComponents
        let parentComponents = parent.pathComponents
        guard parentComponents.count >= rootComponents.count,
              Array(parentComponents.prefix(rootComponents.count)) == rootComponents else {
            throw invalidPath(destination)
        }

        let rootDescriptor = open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { throw posixError(for: root) }
        var currentDescriptor = rootDescriptor
        defer {
            if currentDescriptor != rootDescriptor { close(currentDescriptor) }
            close(rootDescriptor)
        }

        var inspectedURL = root
        for component in parentComponents.dropFirst(rootComponents.count) {
            guard component != ".", component != "..", component != "/" else {
                throw invalidPath(destination)
            }
            inspectedURL.appendPathComponent(component, isDirectory: true)
            try beforeOpeningComponent?(inspectedURL)

            var nextDescriptor = component.withCString {
                openat(
                    currentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if nextDescriptor < 0, errno == ENOENT {
                let created = component.withCString {
                    mkdirat(currentDescriptor, $0, mode_t(0o755))
                }
                guard created == 0 || errno == EEXIST else {
                    throw posixError(for: inspectedURL)
                }
                nextDescriptor = component.withCString {
                    openat(
                        currentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
            }
            guard nextDescriptor >= 0 else {
                throw posixError(for: inspectedURL)
            }
            if currentDescriptor != rootDescriptor { close(currentDescriptor) }
            currentDescriptor = nextDescriptor
        }
    }

    private static func invalidPath(_ url: URL) -> CocoaError {
        CocoaError(
            .fileWriteInvalidFileName,
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }

    private static func posixError(for url: URL) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }
}
