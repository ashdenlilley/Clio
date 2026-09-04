import AppKit
import Foundation

@MainActor
final class DocumentMover {
    enum MoveError: LocalizedError {
        case destinationChanged(URL)

        var errorDescription: String? {
            switch self {
            case .destinationChanged(let url):
                "\(url.lastPathComponent) changed while Clio was preparing the move. Nothing was replaced."
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
        registry: DocumentBufferRegistry? = nil
    ) async throws -> FileMutationOutcome {
        guard let sourceURL = document.fileURL else { return .cancelled }
        _ = try sourceWorkspace.save(document)
        registry?.suspendAutosave(for: document.id)
        defer { registry?.resumeAutosave(for: document.id) }

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
                let displacedDocument = registry?.document(
                    at: destinationURL,
                    in: destinationWorkspace
                )
                if let displacedDocument,
                   displacedDocument !== document,
                   displacedDocument.isDirty {
                    _ = try await recoveryStore.preserve(
                        documentID: displacedDocument.id,
                        filename: displacedDocument.filename,
                        data: Data(displacedDocument.text.utf8),
                        sourceModificationDate: nil
                    )
                }
                _ = try await recoveryStore.preserve(
                    documentID: document.id,
                    filename: destinationURL.lastPathComponent,
                    data: replaced.data,
                    sourceModificationDate: replaced.revision.modificationDate
                )
                let installedData = Data(document.text.utf8)
                let replaceOutcome = try await fileIO.replace(
                    contents: installedData,
                    at: destinationURL,
                    onlyIf: replaced.revision
                )
                guard case .replaced = replaceOutcome else {
                    if case .revisionMismatch(let retainedURL?) = replaceOutcome {
                        let retained = try await fileIO.snapshot(at: retainedURL)
                        _ = try await recoveryStore.preserve(
                            documentID: document.id,
                            filename: destinationURL.lastPathComponent,
                            data: retained.data,
                            sourceModificationDate: retained.revision.modificationDate
                        )
                        try await fileIO.remove(at: retainedURL)
                    }
                    throw MoveError.destinationChanged(destinationURL)
                }
                try await fileIO.remove(at: sourceURL)
                if let displacedDocument, displacedDocument !== document {
                    displacedDocument.markUnbacked(previous: proposedLocator)
                    registry?.detach(displacedDocument.id, from: proposedLocator)
                }
                return try await finishMove(
                    document,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceWorkspace: sourceWorkspace,
                    destinationWorkspace: destinationWorkspace,
                    installedData: installedData,
                    registry: registry
                )
            }
        }

        try await fileIO.move(from: sourceURL, to: destinationURL)
        return try await finishMove(
            document,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            sourceWorkspace: sourceWorkspace,
            destinationWorkspace: destinationWorkspace,
            installedData: nil,
            registry: registry
        )
    }

    @discardableResult
    func moveToTrash(
        _ document: Document,
        workspace: Workspace,
        registry: DocumentBufferRegistry? = nil
    ) throws -> URL? {
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

    func reveal(_ document: Document) {
        guard let fileURL = document.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
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
        try destinationWorkspace.reconcileExternalChange(for: document)
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

    func snapshot(at url: URL) throws -> (data: Data, revision: DiskRevision) {
        try DocumentRevisionReader.snapshot(at: url)
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

    func remove(at url: URL) throws {
        try fileManager.removeItem(at: url)
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
