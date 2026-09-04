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
    private let recoveryStore: RecoveryStore
    private let fileManager: FileManager
    private let writer: any AtomicFileWriting
    private let trashOperation: ((URL) throws -> URL?)?

    init(
        recoveryStore: RecoveryStore = RecoveryStore(),
        fileManager: FileManager = .default,
        writer: any AtomicFileWriting = AtomicFileWriter(),
        trashOperation: ((URL) throws -> URL?)? = nil
    ) {
        self.recoveryStore = recoveryStore
        self.fileManager = fileManager
        self.writer = writer
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

        if fileManager.fileExists(atPath: destinationURL.path) {
            let collision = FileCollision(
                proposedLocator: proposedLocator,
                existingRevision: try? DocumentRevisionReader.revision(at: destinationURL)
            )
            guard let collisionChoice else { return .collision(collision) }
            switch collisionChoice {
            case .cancel:
                return .cancelled
            case .keepBoth:
                destinationURL = try availableSibling(for: destinationURL)
            case .replace:
                let replaced = try DocumentRevisionReader.snapshot(at: destinationURL)
                let replacedSource = String(data: replaced.data, encoding: .utf8)
                    ?? "[The replaced file was not valid UTF-8.]"
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
                        source: displacedDocument.text,
                        date: Date()
                    )
                }
                _ = try await recoveryStore.preserve(
                    documentID: document.id,
                    filename: destinationURL.lastPathComponent,
                    source: replacedSource,
                    date: replaced.revision.modificationDate
                )
                let replaceOutcome = try writer.replace(
                    contents: Data(document.text.utf8),
                    at: destinationURL,
                    onlyIf: replaced.revision
                )
                guard case .replaced = replaceOutcome else {
                    if case .revisionMismatch(let retainedURL?) = replaceOutcome {
                        let retained = try DocumentRevisionReader.snapshot(at: retainedURL)
                        let source = String(data: retained.data, encoding: .utf8)
                            ?? "[The displaced file was not valid UTF-8.]"
                        _ = try await recoveryStore.preserve(
                            documentID: document.id,
                            filename: destinationURL.lastPathComponent,
                            source: source,
                            date: retained.revision.modificationDate
                        )
                        try fileManager.removeItem(at: retainedURL)
                    }
                    throw MoveError.destinationChanged(destinationURL)
                }
                try fileManager.removeItem(at: sourceURL)
                if let displacedDocument, displacedDocument !== document {
                    displacedDocument.markUnbacked(previous: proposedLocator)
                    registry?.detach(displacedDocument.id, from: proposedLocator)
                }
                return try finishMove(
                    document,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceWorkspace: sourceWorkspace,
                    destinationWorkspace: destinationWorkspace,
                    registry: registry
                )
            }
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        return try finishMove(
            document,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            sourceWorkspace: sourceWorkspace,
            destinationWorkspace: destinationWorkspace,
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
        registry: DocumentBufferRegistry?
    ) throws -> FileMutationOutcome {
        let oldLocator = try sourceWorkspace.locator(for: sourceURL)
        let newLocator = try destinationWorkspace.locator(for: destinationURL)
        let revision = try DocumentRevisionReader.revision(at: destinationURL)
        document.didMove(to: destinationURL, revision: revision)
        registry?.removeLocator(oldLocator, for: document.id)
        registry?.updateAliases(for: document, in: destinationWorkspace)
        return .completed(newLocator)
    }

    private func availableSibling(for url: URL) throws -> URL {
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
