import Darwin
import Foundation

private struct SelfWriteRecord {
    let token: UUID
    let revision: DiskRevision
    let expiresAt: Date
}

private enum WorkspacePreparedSave: Sendable {
    case saved(url: URL, revision: DiskRevision)
    case conflict(DocumentConflict)
    case deleted(URL)
}

private enum WorkspacePreparedExternalChange: Sendable {
    case missing
    case unchanged(DiskRevision)
    case clean(source: String, revision: DiskRevision, utf8ByteCount: Int)
    case conflict(local: Data, external: Data, revision: DiskRevision)

    var diskRevision: DiskRevision? {
        switch self {
        case .missing:
            nil
        case .unchanged(let revision),
             .clean(_, let revision, _),
             .conflict(_, _, let revision):
            revision
        }
    }
}

struct WorkspaceDiskState: Sendable {
    let data: Data
    let source: String?
    let revision: DiskRevision
}

struct PreparedDocumentHydration: Sendable {
    let fileURL: URL
    let canonicalPath: String
    let identity: PhysicalFileIdentity
    let source: String
    let utf8ByteCount: Int
    let revision: DiskRevision
}

@MainActor
final class Workspace {
    struct BookmarkResolution: Sendable, Equatable {
        let url: URL
        let isStale: Bool
    }

    enum WorkspaceError: LocalizedError, Equatable {
        case rootDoesNotExist(URL)
        case rootIsNotDirectory(URL)
        case securityScopedAccessDenied(URL)
        case fileOutsideWorkspace(URL)
        case noAvailableFilename(String)
        case externalConflict(DocumentConflict)
        case documentDeleted(URL)
        case detachedDocumentRequiresExplicitRestore(DocumentLocator)
        case saveTargetChanged(URL)
        case externalChangeUnstable(URL)
        case backgroundOperationRequired(URL)

        var errorDescription: String? {
            switch self {
            case .rootDoesNotExist(let url):
                return "The workspace does not exist at \(url.path)."
            case .rootIsNotDirectory(let url):
                return "The workspace root is not a folder: \(url.path)."
            case .securityScopedAccessDenied(let url):
                return "Clio no longer has permission to access \(url.path)."
            case .fileOutsideWorkspace(let url):
                return "The file is outside the current workspace: \(url.path)."
            case .noAvailableFilename(let filename):
                return "Could not find an available filename for \(filename)."
            case .externalConflict:
                return "This document changed outside Clio. Choose which version to keep."
            case .documentDeleted(let url):
                return "\(url.lastPathComponent) was deleted outside Clio. Its buffer remains open."
            case .detachedDocumentRequiresExplicitRestore(let locator):
                return "\(locator.relativePath) was removed. Choose Restore or Save As before writing it to disk again."
            case .saveTargetChanged(let url):
                return "\(url.lastPathComponent) moved while Clio was saving it. The newer buffer remains unsaved."
            case .externalChangeUnstable(let url):
                return "\(url.lastPathComponent) kept changing while Clio was reading it. Try again when the outside edit is complete."
            case .backgroundOperationRequired(let url):
                return "\(url.lastPathComponent) requires Clio’s background file-operation path."
            }
        }
    }

    nonisolated static var preferredDefaultURL: URL {
        let physicalHomeURL = FileManager.default.homeDirectory(forUser: NSUserName())
            ?? FileManager.default.homeDirectoryForCurrentUser
        return physicalHomeURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Clio", isDirectory: true)
    }

    let id: WorkspaceID
    let rootURL: URL
    let isSecurityScopedAccessActive: Bool

    private let fileManager: FileManager
    private let atomicWriter: any AtomicFileWriting
    private let crashRecoveryJournal: CrashRecoveryJournal?
    private let fileExecutor: WorkspaceFileExecutor
    private var selfWrites: [String: SelfWriteRecord] = [:]
    private let securityScopedURL: URL?

    init(
        id: WorkspaceID = WorkspaceID(),
        rootURL: URL,
        accessSecurityScopedResource: Bool = true,
        fileManager: FileManager = .default,
        atomicWriter: any AtomicFileWriting = AtomicFileWriter(),
        crashRecoveryJournal: CrashRecoveryJournal? = nil,
        recoverWorkspaceTransactions: Bool = true
    ) throws {
        let scopedURL = rootURL.standardizedFileURL
        let didStartSecurityScopedAccess = accessSecurityScopedResource
            ? scopedURL.startAccessingSecurityScopedResource()
            : false

        do {
            if accessSecurityScopedResource, !didStartSecurityScopedAccess {
                throw WorkspaceError.securityScopedAccessDenied(scopedURL)
            }

            let resolvedURL = scopedURL.resolvingSymlinksInPath()
            var isDirectory = ObjCBool(false)

            guard fileManager.fileExists(
                atPath: resolvedURL.path,
                isDirectory: &isDirectory
            ) else {
                throw WorkspaceError.rootDoesNotExist(resolvedURL)
            }

            guard isDirectory.boolValue else {
                throw WorkspaceError.rootIsNotDirectory(resolvedURL)
            }

            self.id = id
            self.rootURL = resolvedURL
            self.fileManager = fileManager
            self.atomicWriter = atomicWriter
            self.crashRecoveryJournal = crashRecoveryJournal
            fileExecutor = WorkspaceFileExecutor(
                workspaceID: id,
                rootURL: resolvedURL,
                fileManager: fileManager,
                writer: atomicWriter,
                crashRecoveryJournal: crashRecoveryJournal
            )
            isSecurityScopedAccessActive = didStartSecurityScopedAccess
            securityScopedURL = didStartSecurityScopedAccess ? scopedURL : nil
            if recoverWorkspaceTransactions, let crashRecoveryJournal {
                _ = try AtomicWriteTransactions.recoverInterruptedTransactions(
                    in: resolvedURL,
                    journal: crashRecoveryJournal
                )
                _ = try InterruptedMoveTransactions.recover(
                    in: resolvedURL,
                    journal: crashRecoveryJournal
                )
            }
        } catch {
            if didStartSecurityScopedAccess {
                scopedURL.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    deinit {
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    nonisolated static func makeSecurityScopedBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    nonisolated static func resolveSecurityScopedBookmark(
        _ data: Data
    ) throws -> BookmarkResolution {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [
                .withSecurityScope,
                .withoutImplicitStartAccessing,
                .withoutUI,
            ],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return BookmarkResolution(url: url.standardizedFileURL, isStale: isStale)
    }

    func documentURLs() throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles,
            .skipsPackageDescendants,
        ]

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options
        ) else {
            return []
        }

        var results: [(url: URL, modificationDate: Date)] = []

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: resourceKeys)

            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values.isDirectory == true {
                if url.lastPathComponent == "node_modules" {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else { continue }

            let pathExtension = url.pathExtension.lowercased()
            if Self.documentExtensions.contains(pathExtension) {
                results.append(
                    (
                        url: url.standardizedFileURL,
                        modificationDate: values.contentModificationDate ?? .distantPast
                    )
                )
            }
        }

        return results.sorted { lhs, rhs in
            if lhs.modificationDate != rhs.modificationDate {
                return lhs.modificationDate > rhs.modificationDate
            }

            return relativePath(for: lhs.url) < relativePath(for: rhs.url)
        }.map(\.url)
    }

    func loadDocument(at fileURL: URL, id: DocumentID = DocumentID()) throws -> Document {
        let fileURL = fileURL.standardizedFileURL
        guard contains(fileURL) else {
            throw WorkspaceError.fileOutsideWorkspace(fileURL)
        }
        return try Document(contentsOf: fileURL, id: id)
    }

    /// Bounded, no-follow hydration for picker/search/restoration and large
    /// launch documents. Reading, hashing, and UTF-8 decoding happen on the
    /// workspace file actor; callers register only a subsequently confirmed
    /// path/identity/revision.
    func prepareDocumentInBackground(
        at fileURL: URL
    ) async throws -> PreparedDocumentHydration {
        let fileURL = fileURL.standardizedFileURL
        guard contains(fileURL) else {
            throw WorkspaceError.fileOutsideWorkspace(fileURL)
        }
        return try await fileExecutor.hydrateDocument(at: fileURL)
    }

    func confirmPreparedDocument(
        _ prepared: PreparedDocumentHydration
    ) async throws -> Bool {
        guard contains(prepared.fileURL) else { return false }
        return try await fileExecutor.isCurrent(prepared)
    }

    func loadDocumentInBackground(
        at fileURL: URL,
        id: DocumentID = DocumentID()
    ) async throws -> Document {
        for _ in 0..<8 {
            let prepared = try await prepareDocumentInBackground(at: fileURL)
            guard try await confirmPreparedDocument(prepared) else { continue }
            return Document(
                text: prepared.source,
                fileURL: prepared.fileURL,
                preferredFilename: prepared.fileURL.lastPathComponent,
                id: id,
                expectedDiskRevision: prepared.revision,
                utf8ByteCount: prepared.utf8ByteCount
            )
        }
        throw WorkspaceError.externalChangeUnstable(fileURL.standardizedFileURL)
    }

    func locator(for fileURL: URL) throws -> DocumentLocator {
        let resolvedURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(resolvedURL), resolvedURL != rootURL else {
            throw WorkspaceError.fileOutsideWorkspace(resolvedURL)
        }
        return try DocumentLocator(
            workspaceID: id,
            relativePath: relativePath(for: resolvedURL)
        )
    }

    func fileURL(for locator: DocumentLocator) throws -> URL {
        guard locator.workspaceID == id else {
            throw WorkspaceError.fileOutsideWorkspace(rootURL)
        }
        let url = rootURL.appendingPathComponent(locator.relativePath).standardizedFileURL
        guard contains(url) else { throw WorkspaceError.fileOutsideWorkspace(url) }
        return url
    }

    func relativePath(for fileURL: URL) -> String {
        let resolvedURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(resolvedURL) else {
            return resolvedURL.lastPathComponent
        }

        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return String(resolvedURL.path.dropFirst(rootPath.count))
    }

    func contains(_ fileURL: URL) -> Bool {
        let resolvedURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        if resolvedURL == rootURL {
            return true
        }

        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return resolvedURL.path.hasPrefix(rootPath)
    }

    /// Atomically persists the current document revision. An unbacked empty
    /// document remains in memory; an unbacked non-empty document receives the
    /// first collision-safe variant of its preferred filename.
    @discardableResult
    func save(
        _ document: Document,
        allowingDetachedRestore: Bool = false
    ) throws -> URL? {
        let snapshot = document.snapshot()

        guard snapshot.isDirty else {
            return snapshot.fileURL
        }
        guard snapshot.utf8ByteCount <= Document.maximumSynchronousByteCount else {
            throw WorkspaceError.backgroundOperationRequired(
                snapshot.fileURL ?? rootURL
            )
        }

        try checkpointCrashRecovery(snapshot, reason: .dirtyBuffer)

        if let conflict = document.conflict {
            throw WorkspaceError.externalConflict(conflict)
        }

        if let previousLocator = snapshot.previousLocator,
           snapshot.fileURL == nil,
           !allowingDetachedRestore {
            throw WorkspaceError.detachedDocumentRequiresExplicitRestore(previousLocator)
        }

        guard snapshot.fileURL != nil || !snapshot.text.isEmpty else {
            document.didSkipEmptyUnbackedWrite(snapshot)
            return nil
        }

        let data = Data(snapshot.text.utf8)
        let destinationURL: URL

        if let fileURL = snapshot.fileURL {
            guard contains(fileURL) else {
                throw WorkspaceError.fileOutsideWorkspace(fileURL)
            }

            guard fileManager.fileExists(atPath: fileURL.path) else {
                document.markUnbacked(previous: try? locator(for: fileURL))
                throw WorkspaceError.documentDeleted(fileURL)
            }

            let current = try synchronousDocumentSnapshot(at: fileURL)
            if let expected = snapshot.expectedDiskRevision,
               !Self.sameContent(current.revision, expected) {
                let conflict = try makeConflict(
                    document: document,
                    snapshot: snapshot,
                    externalData: current.data,
                    externalRevision: current.revision
                )
                document.registerConflict(conflict)
                throw WorkspaceError.externalConflict(conflict)
            }

            document.willWrite(snapshot)
            do {
                let replaceOutcome = try atomicWriter.replace(
                    contents: data,
                    at: fileURL,
                    onlyIf: current.revision
                )
                if case .revisionMismatch(let retainedURL) = replaceOutcome {
                    let latest = try synchronousDocumentSnapshot(at: fileURL)
                    let conflict = try makeConflict(
                        document: document,
                        snapshot: snapshot,
                        externalData: latest.data,
                        externalRevision: latest.revision,
                        additionalExternalVersions: try retainedURL.map {
                            [try retainedConflictSide(at: $0)]
                        }
                    )
                    document.registerConflict(conflict)
                    throw WorkspaceError.externalConflict(conflict)
                }
            } catch {
                if document.conflict == nil { document.didFailWrite(snapshot) }
                throw error
            }
            destinationURL = fileURL
        } else {
            document.willWrite(snapshot)
            do {
                if allowingDetachedRestore,
                   let previousLocator = snapshot.previousLocator,
                   previousLocator.workspaceID == id {
                    destinationURL = try restoreDetachedDocument(
                        data,
                        locator: previousLocator,
                        preferredFilename: snapshot.preferredFilename
                    )
                } else {
                    destinationURL = try writeNewDocument(
                        data,
                        preferredFilename: snapshot.preferredFilename
                    )
                }
            } catch {
                document.didFailWrite(snapshot)
                throw error
            }
        }

        let diskRevision = try DocumentRevisionReader.revision(at: destinationURL)
        let token = UUID()
        selfWrites[destinationURL.standardizedFileURL.path] = SelfWriteRecord(
            token: token,
            revision: diskRevision,
            expiresAt: Date().addingTimeInterval(5)
        )
        document.didWrite(snapshot, to: destinationURL, revision: diskRevision)
        crashRecoveryJournal?.clear(
            documentID: snapshot.documentID,
            through: snapshot.revision
        )
        return destinationURL
    }

    /// Serializes UTF-8 materialization, hashing, crash checkpointing, and
    /// fsync-backed installation away from the UI executor. Observable buffer
    /// state is applied only after its document identity and target path have
    /// been revalidated on MainActor.
    @discardableResult
    func saveInBackground(
        _ document: Document,
        allowingDetachedRestore: Bool = false
    ) async throws -> URL? {
        for _ in 0..<8 {
            let snapshot = document.snapshot()
            guard snapshot.isDirty else { return snapshot.fileURL }

            if let conflict = document.conflict {
                throw WorkspaceError.externalConflict(conflict)
            }
            if let previousLocator = snapshot.previousLocator,
               snapshot.fileURL == nil,
               !allowingDetachedRestore {
                throw WorkspaceError.detachedDocumentRequiresExplicitRestore(previousLocator)
            }
            guard snapshot.fileURL != nil || snapshot.utf8ByteCount > 0 else {
                document.didSkipEmptyUnbackedWrite(snapshot)
                return nil
            }

            let locator = try snapshot.fileURL.map { try self.locator(for: $0) }
            document.willWrite(snapshot)
            let prepared: WorkspacePreparedSave
            do {
                prepared = try await fileExecutor.save(
                    snapshot,
                    locator: locator,
                    allowingDetachedRestore: allowingDetachedRestore
                )
            } catch {
                document.didFailWrite(snapshot)
                throw error
            }

            switch prepared {
            case .saved(let url, let revision):
                guard Self.sameTarget(document.fileURL, snapshot.fileURL) else {
                    document.didFailWrite(snapshot)
                    throw WorkspaceError.saveTargetChanged(snapshot.fileURL ?? url)
                }
                selfWrites[url.standardizedFileURL.path] = SelfWriteRecord(
                    token: UUID(),
                    revision: revision,
                    expiresAt: Date().addingTimeInterval(5)
                )
                document.didWrite(snapshot, to: url, revision: revision)
                crashRecoveryJournal?.clear(
                    documentID: snapshot.documentID,
                    through: snapshot.revision
                )
                return url

            case .conflict(let conflict):
                guard Self.matches(document, snapshot: snapshot) else {
                    document.didFailWrite(snapshot)
                    continue
                }
                document.registerConflict(conflict)
                throw WorkspaceError.externalConflict(conflict)

            case .deleted(let url):
                guard Self.matches(document, snapshot: snapshot) else {
                    document.didFailWrite(snapshot)
                    continue
                }
                document.markUnbacked(previous: locator)
                throw WorkspaceError.documentDeleted(url)
            }
        }

        throw WorkspaceError.externalChangeUnstable(
            document.fileURL ?? rootURL
        )
    }

    /// Reads and decodes outside bytes on the workspace's serial file actor,
    /// confirms that exact disk revision after the suspension point, then applies it
    /// only if the URL and in buffer generation are still current.
    func reconcileExternalChangeInBackground(for document: Document) async throws {
        for _ in 0..<8 {
            guard let fileURL = document.fileURL else { return }
            let snapshot = document.snapshot()
            let conflictID = document.conflict?.id
            let locator = try locator(for: fileURL)
            let prepared = try await fileExecutor.prepareExternalChange(
                snapshot,
                at: fileURL
            )
            let confirmed = try await fileExecutor.revisionIfPresent(at: fileURL)

            guard confirmed == prepared.diskRevision else { continue }
            guard Self.matches(
                document,
                snapshot: snapshot,
                conflictID: conflictID
            ) else { continue }

            if let revision = prepared.diskRevision,
               consumeSelfWrite(at: fileURL, revision: revision) != nil {
                return
            }

            switch prepared {
            case .missing:
                if let conflict = document.conflict {
                    throw WorkspaceError.externalConflict(conflict)
                }
                document.markUnbacked(previous: locator)
                return

            case .unchanged:
                return

            case .clean(let source, let revision, let byteCount):
                document.applyExternal(
                    source: source,
                    revision: revision,
                    utf8ByteCount: byteCount
                )
                return

            case .conflict(let local, let external, let revision):
                let conflict = Self.makePreparedConflict(
                    snapshot: snapshot,
                    locator: locator,
                    localData: local,
                    externalData: external,
                    externalRevision: revision
                )
                document.registerConflict(conflict)
                return
            }
        }

        throw WorkspaceError.externalChangeUnstable(
            document.fileURL ?? rootURL
        )
    }

    /// Reconciles a correlated outside rename without ever hydrating the new
    /// file on MainActor. The old path, new path, disk revision, and canonical
    /// buffer generation must all still match before retargeting the buffer.
    func reconcileExternalMoveInBackground(
        for document: Document,
        from oldURL: URL,
        to newURL: URL
    ) async throws {
        let oldURL = oldURL.standardizedFileURL
        let newURL = newURL.standardizedFileURL
        guard contains(newURL) else {
            throw WorkspaceError.fileOutsideWorkspace(newURL)
        }
        // A discovered cross-workspace move is reconciled by the destination
        // workspace, so its source URL can legitimately sit outside this root.
        // The prior locator is only recovery metadata for a missing destination;
        // never make it a prerequisite for adopting a valid destination.
        let oldLocator = try? locator(for: oldURL)

        for _ in 0..<8 {
            guard document.fileURL?.standardizedFileURL == oldURL else { return }
            let snapshot = document.snapshot()
            let conflictID = document.conflict?.id
            let newLocator = try locator(for: newURL)
            let prepared = try await fileExecutor.prepareExternalChange(
                snapshot,
                at: newURL
            )
            let confirmed = try await fileExecutor.revisionIfPresent(at: newURL)

            guard confirmed == prepared.diskRevision else { continue }
            guard Self.matches(
                document,
                snapshot: snapshot,
                conflictID: conflictID
            ), document.fileURL?.standardizedFileURL == oldURL else { continue }

            switch prepared {
            case .missing:
                document.markUnbacked(previous: oldLocator)
                throw WorkspaceError.documentDeleted(oldURL)

            case .unchanged(let revision):
                document.prepareForExternalMove(to: newURL)
                document.didMove(to: newURL, revision: revision)
                return

            case .clean(let source, let revision, let byteCount):
                document.prepareForExternalMove(to: newURL)
                document.applyExternal(
                    source: source,
                    revision: revision,
                    utf8ByteCount: byteCount
                )
                return

            case .conflict(let local, let external, let revision):
                document.prepareForExternalMove(to: newURL)
                let movedSnapshot = document.snapshot()
                let conflict = Self.makePreparedConflict(
                    snapshot: movedSnapshot,
                    locator: newLocator,
                    localData: local,
                    externalData: external,
                    externalRevision: revision
                )
                document.registerConflict(conflict)
                return
            }
        }

        throw WorkspaceError.externalChangeUnstable(newURL)
    }

    func checkpointCrashRecoveryInBackground(
        for document: Document,
        reason: CrashRecoveryReason
    ) async throws {
        for _ in 0..<8 {
            let snapshot = document.snapshot()
            let conflictID = document.conflict?.id
            try await fileExecutor.checkpoint(snapshot, reason: reason)
            if Self.matches(
                document,
                snapshot: snapshot,
                conflictID: conflictID
            ) {
                return
            }
        }
        throw WorkspaceError.externalChangeUnstable(
            document.fileURL ?? rootURL
        )
    }

    @discardableResult
    func checkpointCrashRecoveryInBackground(
        data: Data,
        documentID: DocumentID,
        generation: BufferGeneration,
        filename: String,
        targetURL: URL?,
        reason: CrashRecoveryReason
    ) async throws -> URL? {
        try await fileExecutor.checkpoint(
            data: data,
            documentID: documentID,
            generation: generation,
            filename: filename,
            targetURL: targetURL,
            reason: reason
        )
    }

    func fileExistsInBackground(at url: URL) async -> Bool {
        await fileExecutor.fileExists(at: url)
    }

    func scheduleCrashRecovery(for document: Document) {
        guard let crashRecoveryJournal else { return }
        let snapshot = document.snapshot()
        guard snapshot.isDirty else { return }
        crashRecoveryJournal.schedule(CrashRecoverySnapshot(
            documentID: snapshot.documentID,
            generation: BufferGeneration(
                bufferID: snapshot.documentID.rawValue,
                revision: snapshot.revision
            ),
            filename: snapshot.preferredFilename,
            targetURL: snapshot.fileURL,
            reason: .dirtyBuffer,
            source: snapshot.text
        ))
    }

    func checkpointCrashRecovery(
        for document: Document,
        reason: CrashRecoveryReason
    ) throws {
        let snapshot = document.snapshot()
        guard snapshot.utf8ByteCount <= Document.maximumSynchronousByteCount else {
            throw WorkspaceError.backgroundOperationRequired(
                snapshot.fileURL ?? rootURL
            )
        }
        try checkpointCrashRecovery(snapshot, reason: reason)
    }

    @discardableResult
    func checkpointCrashRecovery(
        data: Data,
        documentID: DocumentID,
        generation: BufferGeneration,
        filename: String,
        targetURL: URL?,
        reason: CrashRecoveryReason
    ) throws -> URL? {
        guard data.count <= Document.maximumSynchronousByteCount else {
            throw WorkspaceError.backgroundOperationRequired(targetURL ?? rootURL)
        }
        guard let crashRecoveryJournal else { return nil }
        return try crashRecoveryJournal.checkpoint(CrashRecoveryRecord(
            documentID: documentID,
            generation: generation,
            filename: filename,
            targetURL: targetURL,
            reason: reason,
            data: data
        ))
    }

    /// Returns the originating token once for a matching recent Clio write.
    func consumeSelfWrite(at fileURL: URL, revision: DiskRevision) -> UUID? {
        let now = Date()
        selfWrites = selfWrites.filter { $0.value.expiresAt > now }
        let key = fileURL.standardizedFileURL.path
        guard let record = selfWrites[key],
              Self.sameContent(record.revision, revision) else { return nil }
        selfWrites.removeValue(forKey: key)
        return record.token
    }

    /// Applies an outside change only when the buffer is clean. Dirty buffers
    /// enter a conflict and stop autosave until the user chooses a side.
    func reconcileExternalChange(for document: Document) throws {
        guard let fileURL = document.fileURL else { return }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            if let conflict = document.conflict {
                throw WorkspaceError.externalConflict(conflict)
            }
            document.markUnbacked(previous: try? locator(for: fileURL))
            return
        }
        guard document.utf8ByteCount <= Document.maximumSynchronousByteCount else {
            throw WorkspaceError.backgroundOperationRequired(fileURL)
        }

        let disk = try synchronousDocumentSnapshot(at: fileURL)
        if consumeSelfWrite(at: fileURL, revision: disk.revision) != nil {
            return
        }
        if let expected = document.expectedDiskRevision,
           Self.sameContent(expected, disk.revision) {
            return
        }

        if document.isDirty {
            try checkpointCrashRecovery(for: document, reason: .externalConflict)
            let conflict = try makeConflict(
                document: document,
                snapshot: document.snapshot(),
                externalData: disk.data,
                externalRevision: disk.revision
            )
            document.registerConflict(conflict)
        } else {
            guard let externalSource = String(data: disk.data, encoding: .utf8) else {
                throw Document.ReadError.invalidUTF8(fileURL)
            }
            document.applyExternal(source: externalSource, revision: disk.revision)
        }
    }

    /// Reconciles an outside rename and its bytes as one transaction. The old
    /// path is never saved after this returns: a clean buffer adopts changed
    /// bytes, while a dirty buffer retains its text and enters conflict.
    func reconcileExternalMove(
        for document: Document,
        from oldURL: URL,
        to newURL: URL
    ) throws {
        let oldURL = oldURL.standardizedFileURL
        let newURL = newURL.standardizedFileURL
        guard contains(newURL) else { throw WorkspaceError.fileOutsideWorkspace(newURL) }
        guard document.fileURL?.standardizedFileURL == oldURL else { return }
        guard fileManager.fileExists(atPath: newURL.path) else {
            document.markUnbacked(previous: try? locator(for: oldURL))
            throw WorkspaceError.documentDeleted(oldURL)
        }
        guard document.utf8ByteCount <= Document.maximumSynchronousByteCount else {
            throw WorkspaceError.backgroundOperationRequired(newURL)
        }

        let prior = document.snapshot()
        let disk = try synchronousDocumentSnapshot(at: newURL)
        let contentChanged = prior.expectedDiskRevision.map {
            !Self.sameContent($0, disk.revision)
        } ?? true

        document.prepareForExternalMove(to: newURL)
        if !contentChanged {
            document.didMove(to: newURL, revision: disk.revision)
            return
        }

        if prior.isDirty {
            try checkpointCrashRecovery(prior, reason: .externalConflict)
            let movedSnapshot = document.snapshot()
            let conflict = try makeConflict(
                document: document,
                snapshot: movedSnapshot,
                externalData: disk.data,
                externalRevision: disk.revision
            )
            document.registerConflict(conflict)
            return
        }

        guard let source = String(data: disk.data, encoding: .utf8) else {
            throw Document.ReadError.invalidUTF8(newURL)
        }
        document.applyExternal(source: source, revision: disk.revision)
    }

    /// Hydrates one stable disk generation on the serial file executor. The
    /// caller receives it only while the same document target, buffer
    /// generation, expected base, and conflict identity are still current.
    func readDiskSnapshotInBackground(
        for document: Document,
        conflictID: UUID?
    ) async throws -> WorkspaceDiskState {
        for _ in 0..<8 {
            guard let fileURL = document.fileURL else {
                throw WorkspaceError.documentDeleted(rootURL)
            }
            let snapshot = document.snapshot()
            let state = try await fileExecutor.diskStateIfPresent(at: fileURL)
            let confirmed = try await fileExecutor.revisionIfPresent(at: fileURL)

            guard Self.matches(
                document,
                snapshot: snapshot,
                conflictID: conflictID
            ) else { continue }
            guard let state, let confirmed else {
                throw WorkspaceError.documentDeleted(fileURL)
            }
            guard Self.sameContent(state.revision, confirmed) else { continue }
            return state
        }

        throw WorkspaceError.externalChangeUnstable(
            document.fileURL ?? rootURL
        )
    }

    /// Installs the approved Clio side of a conflict without materializing or
    /// hashing the document on MainActor. The compare-and-swap protects every
    /// outside revision; `didWrite` conditionally advances a newer local edit
    /// against the bytes actually installed by this generation.
    @discardableResult
    func replaceAfterConflictInBackground(
        _ document: Document,
        conflictID: UUID,
        expectedExternalRevision: DiskRevision
    ) async throws -> URL {
        guard document.conflict?.id == conflictID else {
            throw WorkspaceError.externalChangeUnstable(
                document.fileURL ?? rootURL
            )
        }
        let snapshot = document.snapshot()
        guard let destinationURL = snapshot.fileURL else {
            throw WorkspaceError.documentDeleted(rootURL)
        }
        let locator = try self.locator(for: destinationURL)
        document.willWrite(snapshot)

        let prepared: WorkspacePreparedSave
        do {
            prepared = try await fileExecutor.replaceAfterConflict(
                snapshot,
                locator: locator,
                expectedExternalRevision: expectedExternalRevision
            )
        } catch {
            document.didFailWrite(snapshot)
            throw error
        }

        switch prepared {
        case .saved(let url, let revision):
            guard document.id == snapshot.documentID,
                  Self.sameTarget(document.fileURL, snapshot.fileURL),
                  document.conflict?.id == conflictID else {
                document.didFailWrite(snapshot)
                throw WorkspaceError.externalChangeUnstable(destinationURL)
            }
            selfWrites[url.standardizedFileURL.path] = SelfWriteRecord(
                token: UUID(),
                revision: revision,
                expiresAt: Date().addingTimeInterval(5)
            )
            document.didWrite(snapshot, to: url, revision: revision)
            crashRecoveryJournal?.clear(
                documentID: snapshot.documentID,
                through: snapshot.revision
            )
            return url

        case .conflict(let conflict):
            guard document.id == snapshot.documentID,
                  Self.sameTarget(document.fileURL, snapshot.fileURL),
                  document.conflict?.id == conflictID else {
                document.didFailWrite(snapshot)
                throw WorkspaceError.externalChangeUnstable(destinationURL)
            }
            document.registerConflict(conflict)
            throw WorkspaceError.externalConflict(conflict)

        case .deleted(let url):
            guard document.id == snapshot.documentID,
                  Self.sameTarget(document.fileURL, snapshot.fileURL),
                  document.conflict?.id == conflictID else {
                document.didFailWrite(snapshot)
                throw WorkspaceError.externalChangeUnstable(url)
            }
            document.markUnbacked(previous: locator)
            throw WorkspaceError.documentDeleted(url)
        }
    }

    /// Writes the approved local side to a collision-safe sibling after
    /// confirming that the outside side is still the reviewed revision.
    @discardableResult
    func saveConflictCopyInBackground(
        _ document: Document,
        conflictID: UUID,
        expectedExternalRevision: DiskRevision
    ) async throws -> URL {
        guard document.conflict?.id == conflictID else {
            throw WorkspaceError.externalChangeUnstable(
                document.fileURL ?? rootURL
            )
        }
        let snapshot = document.snapshot()
        guard let originalURL = snapshot.fileURL else {
            throw WorkspaceError.documentDeleted(rootURL)
        }
        let locator = try self.locator(for: originalURL)
        document.willWrite(snapshot)

        let prepared: WorkspacePreparedSave
        do {
            prepared = try await fileExecutor.saveConflictCopy(
                snapshot,
                originalURL: originalURL,
                locator: locator,
                expectedExternalRevision: expectedExternalRevision
            )
        } catch {
            document.didFailWrite(snapshot)
            throw error
        }

        switch prepared {
        case .saved(let url, let revision):
            guard document.id == snapshot.documentID,
                  Self.sameTarget(document.fileURL, snapshot.fileURL),
                  document.conflict?.id == conflictID else {
                document.didFailWrite(snapshot)
                throw WorkspaceError.externalChangeUnstable(originalURL)
            }
            selfWrites[url.standardizedFileURL.path] = SelfWriteRecord(
                token: UUID(),
                revision: revision,
                expiresAt: Date().addingTimeInterval(5)
            )
            document.didWrite(snapshot, to: url, revision: revision)
            crashRecoveryJournal?.clear(
                documentID: snapshot.documentID,
                through: snapshot.revision
            )
            return url

        case .conflict(let conflict):
            guard document.id == snapshot.documentID,
                  Self.sameTarget(document.fileURL, snapshot.fileURL),
                  document.conflict?.id == conflictID else {
                document.didFailWrite(snapshot)
                throw WorkspaceError.externalChangeUnstable(originalURL)
            }
            document.registerConflict(conflict)
            throw WorkspaceError.externalConflict(conflict)

        case .deleted(let url):
            guard document.id == snapshot.documentID,
                  Self.sameTarget(document.fileURL, snapshot.fileURL),
                  document.conflict?.id == conflictID else {
                document.didFailWrite(snapshot)
                throw WorkspaceError.externalChangeUnstable(url)
            }
            document.markUnbacked(previous: locator)
            throw WorkspaceError.documentDeleted(url)
        }
    }

}

extension Workspace {
    nonisolated static let documentExtensions: Set<String> = ["md", "markdown", "txt"]
    nonisolated static let maximumCollisionAttempts = 10_000

    func writeNewDocument(_ data: Data, preferredFilename: String) throws -> URL {
        try writeNewDocument(
            data,
            in: rootURL,
            preferredFilename: preferredFilename
        )
    }

    func writeNewDocument(
        _ data: Data,
        in parentURL: URL,
        preferredFilename: String
    ) throws -> URL {
        let filename = Self.safeFilename(from: preferredFilename)
        let filenameURL = URL(fileURLWithPath: filename)
        let pathExtension = filenameURL.pathExtension
        let basename = filenameURL.deletingPathExtension().lastPathComponent

        for attempt in 1...Self.maximumCollisionAttempts {
            let candidateName: String
            if attempt == 1 {
                candidateName = filename
            } else if pathExtension.isEmpty {
                candidateName = "\(basename) (\(attempt))"
            } else {
                candidateName = "\(basename) (\(attempt)).\(pathExtension)"
            }

            let candidateURL = parentURL.appendingPathComponent(candidateName)
            if try atomicWriter.create(contents: data, at: candidateURL) {
                return candidateURL.standardizedFileURL
            }
        }

        throw WorkspaceError.noAvailableFilename(filename)
    }

    func restoreDetachedDocument(
        _ data: Data,
        locator: DocumentLocator,
        preferredFilename: String
    ) throws -> URL {
        let desiredURL = try fileURL(for: locator)
        let parentURL = desiredURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        if try atomicWriter.create(contents: data, at: desiredURL) {
            return desiredURL.standardizedFileURL
        }
        return try writeNewDocument(
            data,
            in: parentURL,
            preferredFilename: preferredFilename
        )
    }

    func makeConflict(
        document: Document,
        snapshot: Document.Snapshot,
        externalData: Data,
        externalRevision: DiskRevision,
        additionalExternalVersions: [ConflictSide]? = nil
    ) throws -> DocumentConflict {
        guard let fileURL = snapshot.fileURL else {
            throw WorkspaceError.documentDeleted(rootURL)
        }
        return DocumentConflict(
            documentID: document.id,
            locator: try locator(for: fileURL),
            generation: BufferGeneration(
                bufferID: snapshot.documentID.rawValue,
                revision: snapshot.revision
            ),
            clio: ConflictSide(
                modificationDate: Date(),
                revision: snapshot.expectedDiskRevision,
                data: Data(snapshot.text.utf8)
            ),
            external: ConflictSide(
                modificationDate: externalRevision.modificationDate,
                revision: externalRevision,
                data: externalData
            ),
            additionalExternalVersions: additionalExternalVersions
        )
    }

    func retainedConflictSide(at url: URL) throws -> ConflictSide {
        let retained = try synchronousDocumentSnapshot(at: url)
        return ConflictSide(
            modificationDate: retained.revision.modificationDate,
            revision: retained.revision,
            data: retained.data,
            retainedURLs: [url]
        )
    }

    func synchronousDocumentSnapshot(
        at url: URL
    ) throws -> (data: Data, revision: DiskRevision) {
        do {
            return try DocumentRevisionReader.snapshot(
                at: url,
                maximumByteCount: Int64(Document.maximumSynchronousByteCount)
            )
        } catch DocumentRevisionReader.RevisionError.fileTooLarge {
            throw WorkspaceError.backgroundOperationRequired(url)
        }
    }

    func checkpointCrashRecovery(
        _ snapshot: Document.Snapshot,
        reason: CrashRecoveryReason
    ) throws {
        guard snapshot.utf8ByteCount <= Document.maximumSynchronousByteCount else {
            throw WorkspaceError.backgroundOperationRequired(
                snapshot.fileURL ?? rootURL
            )
        }
        guard let crashRecoveryJournal else { return }
        _ = try crashRecoveryJournal.checkpoint(recoveryRecord(snapshot, reason: reason))
    }

    func recoveryRecord(
        _ snapshot: Document.Snapshot,
        reason: CrashRecoveryReason
    ) -> CrashRecoveryRecord {
        CrashRecoveryRecord(
            documentID: snapshot.documentID,
            generation: BufferGeneration(
                bufferID: snapshot.documentID.rawValue,
                revision: snapshot.revision
            ),
            filename: snapshot.preferredFilename,
            targetURL: snapshot.fileURL,
            reason: reason,
            data: Data(snapshot.text.utf8)
        )
    }

    nonisolated static func sameContent(_ lhs: DiskRevision, _ rhs: DiskRevision) -> Bool {
        DocumentRevisionReader.sameContent(lhs, rhs)
    }

    nonisolated static func sameTarget(_ lhs: URL?, _ rhs: URL?) -> Bool {
        lhs?.standardizedFileURL == rhs?.standardizedFileURL
    }

    static func matches(
        _ document: Document,
        snapshot: Document.Snapshot,
        conflictID: UUID? = nil
    ) -> Bool {
        document.id == snapshot.documentID
            && document.revision == snapshot.revision
            && sameTarget(document.fileURL, snapshot.fileURL)
            && document.expectedDiskRevision == snapshot.expectedDiskRevision
            && document.isDirty == snapshot.isDirty
            && document.previousLocator == snapshot.previousLocator
            && document.conflict?.id == conflictID
    }

    nonisolated static func makePreparedConflict(
        snapshot: Document.Snapshot,
        locator: DocumentLocator,
        localData: Data,
        externalData: Data,
        externalRevision: DiskRevision,
        additionalExternalVersions: [ConflictSide]? = nil
    ) -> DocumentConflict {
        DocumentConflict(
            documentID: snapshot.documentID,
            locator: locator,
            generation: BufferGeneration(
                bufferID: snapshot.documentID.rawValue,
                revision: snapshot.revision
            ),
            clio: ConflictSide(
                modificationDate: Date(),
                revision: snapshot.expectedDiskRevision,
                data: localData
            ),
            external: ConflictSide(
                modificationDate: externalRevision.modificationDate,
                revision: externalRevision,
                data: externalData
            ),
            additionalExternalVersions: additionalExternalVersions
        )
    }

    nonisolated static func safeFilename(from suggestion: String) -> String {
        var filename = (suggestion as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let disallowedScalars = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "/:"))
        filename.unicodeScalars.removeAll { disallowedScalars.contains($0) }

        if filename.isEmpty || filename == "." || filename == ".." || filename.hasPrefix(".") {
            filename = Document.defaultFilename
        }

        if URL(fileURLWithPath: filename).pathExtension.isEmpty {
            filename += ".md"
        }

        return filename
    }
}

/// Per-workspace serialized file executor. No method touches observable
/// document state; all potentially 50 MiB reads, UTF-8 conversions, hashes,
/// crash checkpoints, and durable writes stay off MainActor.
private actor WorkspaceFileExecutor {
    private let workspaceID: WorkspaceID
    private let rootURL: URL
    private let fileManager: FileManager
    private let writer: any AtomicFileWriting
    private let crashRecoveryJournal: CrashRecoveryJournal?

    init(
        workspaceID: WorkspaceID,
        rootURL: URL,
        fileManager: FileManager,
        writer: any AtomicFileWriting,
        crashRecoveryJournal: CrashRecoveryJournal?
    ) {
        self.workspaceID = workspaceID
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
        self.writer = writer
        self.crashRecoveryJournal = crashRecoveryJournal
    }

    func save(
        _ snapshot: Document.Snapshot,
        locator: DocumentLocator?,
        allowingDetachedRestore: Bool
    ) throws -> WorkspacePreparedSave {
        let data = Data(snapshot.text.utf8)
        try checkpoint(snapshot, data: data, reason: .dirtyBuffer)

        let destinationURL: URL
        if let fileURL = snapshot.fileURL?.standardizedFileURL {
            guard contains(fileURL) else {
                throw Workspace.WorkspaceError.fileOutsideWorkspace(fileURL)
            }
            guard let current = try revisionIfPresent(at: fileURL) else {
                return .deleted(fileURL)
            }

            if let expected = snapshot.expectedDiskRevision,
               !Workspace.sameContent(current, expected) {
                guard let disk = try documentSnapshotIfPresent(at: fileURL) else {
                    return .deleted(fileURL)
                }
                return .conflict(
                    makeConflict(
                        snapshot: snapshot,
                        locator: try requiredLocator(locator, for: fileURL),
                        localData: data,
                        externalData: disk.data,
                        externalRevision: disk.revision
                    )
                )
            }

            let replaceOutcome = try writer.replace(
                contents: data,
                at: fileURL,
                onlyIf: current
            )
            if case .revisionMismatch(let retainedURL) = replaceOutcome {
                guard let latest = try documentSnapshotIfPresent(at: fileURL) else {
                    return .deleted(fileURL)
                }
                let additional = try retainedURL.map { url -> [ConflictSide] in
                    guard let retained = try documentSnapshotIfPresent(at: url) else {
                        return []
                    }
                    return [ConflictSide(
                        modificationDate: retained.revision.modificationDate,
                        revision: retained.revision,
                        data: retained.data,
                        retainedURLs: [url]
                    )]
                }
                return .conflict(
                    makeConflict(
                        snapshot: snapshot,
                        locator: try requiredLocator(locator, for: fileURL),
                        localData: data,
                        externalData: latest.data,
                        externalRevision: latest.revision,
                        additionalExternalVersions: additional
                    )
                )
            }
            destinationURL = fileURL
        } else if allowingDetachedRestore,
                  let previous = snapshot.previousLocator,
                  previous.workspaceID == workspaceID {
            destinationURL = try restoreDetachedDocument(
                data,
                locator: previous,
                preferredFilename: snapshot.preferredFilename
            )
        } else {
            destinationURL = try writeNewDocument(
                data,
                in: rootURL,
                preferredFilename: snapshot.preferredFilename
            )
        }

        return .saved(
            url: destinationURL,
            revision: try DocumentRevisionReader.revision(at: destinationURL)
        )
    }

    func hydrateDocument(at fileURL: URL) throws -> PreparedDocumentHydration {
        let fileURL = fileURL.standardizedFileURL
        for _ in 0..<8 {
            try Task.checkCancellation()
            let canonicalBefore = fileURL.resolvingSymlinksInPath().path
            let identityBefore = PhysicalFileIdentity.authorizedFile(at: fileURL)
            guard contains(fileURL) else {
                throw Workspace.WorkspaceError.fileOutsideWorkspace(fileURL)
            }
            let disk = try DocumentRevisionReader.documentSnapshot(at: fileURL)
            guard let source = String(data: disk.data, encoding: .utf8) else {
                throw Document.ReadError.invalidUTF8(fileURL)
            }
            try Task.checkCancellation()
            let canonicalAfter = fileURL.resolvingSymlinksInPath().path
            let identityAfter = PhysicalFileIdentity.authorizedFile(at: fileURL)
            guard canonicalBefore == canonicalAfter,
                  identityBefore == identityAfter else { continue }
            return PreparedDocumentHydration(
                fileURL: fileURL,
                canonicalPath: canonicalAfter,
                identity: identityAfter,
                source: source,
                utf8ByteCount: disk.data.count,
                revision: disk.revision
            )
        }
        throw Workspace.WorkspaceError.externalChangeUnstable(fileURL)
    }

    func isCurrent(_ prepared: PreparedDocumentHydration) throws -> Bool {
        try Task.checkCancellation()
        guard contains(prepared.fileURL),
              prepared.fileURL.resolvingSymlinksInPath().path
                == prepared.canonicalPath,
              PhysicalFileIdentity.authorizedFile(at: prepared.fileURL)
                == prepared.identity,
              let revision = try revisionIfPresent(at: prepared.fileURL),
              Workspace.sameContent(revision, prepared.revision) else {
            return false
        }
        try Task.checkCancellation()
        return true
    }

    func replaceAfterConflict(
        _ snapshot: Document.Snapshot,
        locator: DocumentLocator,
        expectedExternalRevision: DiskRevision
    ) throws -> WorkspacePreparedSave {
        guard let destinationURL = snapshot.fileURL?.standardizedFileURL else {
            return .deleted(rootURL)
        }
        let data = Data(snapshot.text.utf8)
        try checkpoint(snapshot, data: data, reason: .externalConflict)
        guard let current = try revisionIfPresent(at: destinationURL) else {
            return .deleted(destinationURL)
        }
        guard Workspace.sameContent(current, expectedExternalRevision) else {
            guard let latest = try documentSnapshotIfPresent(at: destinationURL) else {
                return .deleted(destinationURL)
            }
            return .conflict(makeConflict(
                snapshot: snapshot,
                locator: locator,
                localData: data,
                externalData: latest.data,
                externalRevision: latest.revision
            ))
        }

        let replaceOutcome = try writer.replace(
            contents: data,
            at: destinationURL,
            onlyIf: current
        )
        if case .revisionMismatch(let retainedURL) = replaceOutcome {
            guard let latest = try documentSnapshotIfPresent(at: destinationURL) else {
                return .deleted(destinationURL)
            }
            let additional = try retainedURL.map { url -> [ConflictSide] in
                guard let retained = try documentSnapshotIfPresent(at: url) else {
                    return []
                }
                return [ConflictSide(
                    modificationDate: retained.revision.modificationDate,
                    revision: retained.revision,
                    data: retained.data,
                    retainedURLs: [url]
                )]
            }
            return .conflict(makeConflict(
                snapshot: snapshot,
                locator: locator,
                localData: data,
                externalData: latest.data,
                externalRevision: latest.revision,
                additionalExternalVersions: additional
            ))
        }

        return .saved(
            url: destinationURL,
            revision: try DocumentRevisionReader.revision(at: destinationURL)
        )
    }

    func saveConflictCopy(
        _ snapshot: Document.Snapshot,
        originalURL: URL,
        locator: DocumentLocator,
        expectedExternalRevision: DiskRevision
    ) throws -> WorkspacePreparedSave {
        let data = Data(snapshot.text.utf8)
        try checkpoint(snapshot, data: data, reason: .externalConflict)
        guard let current = try revisionIfPresent(at: originalURL) else {
            return .deleted(originalURL)
        }
        guard Workspace.sameContent(current, expectedExternalRevision) else {
            guard let latest = try documentSnapshotIfPresent(at: originalURL) else {
                return .deleted(originalURL)
            }
            return .conflict(makeConflict(
                snapshot: snapshot,
                locator: locator,
                localData: data,
                externalData: latest.data,
                externalRevision: latest.revision
            ))
        }

        let destinationURL = try writeNewDocument(
            data,
            in: rootURL,
            preferredFilename: originalURL.lastPathComponent
        )
        return .saved(
            url: destinationURL,
            revision: try DocumentRevisionReader.revision(at: destinationURL)
        )
    }

    func prepareExternalChange(
        _ snapshot: Document.Snapshot,
        at fileURL: URL
    ) throws -> WorkspacePreparedExternalChange {
        guard let disk = try documentSnapshotIfPresent(at: fileURL) else {
            return .missing
        }
        if let expected = snapshot.expectedDiskRevision,
           Workspace.sameContent(expected, disk.revision) {
            return .unchanged(disk.revision)
        }

        if snapshot.isDirty {
            let local = Data(snapshot.text.utf8)
            try checkpoint(snapshot, data: local, reason: .externalConflict)
            return .conflict(
                local: local,
                external: disk.data,
                revision: disk.revision
            )
        }

        guard let source = String(data: disk.data, encoding: .utf8) else {
            throw Document.ReadError.invalidUTF8(fileURL)
        }
        return .clean(
            source: source,
            revision: disk.revision,
            utf8ByteCount: disk.data.count
        )
    }

    func checkpoint(
        _ snapshot: Document.Snapshot,
        reason: CrashRecoveryReason
    ) throws {
        try checkpoint(
            snapshot,
            data: Data(snapshot.text.utf8),
            reason: reason
        )
    }

    func checkpoint(
        data: Data,
        documentID: DocumentID,
        generation: BufferGeneration,
        filename: String,
        targetURL: URL?,
        reason: CrashRecoveryReason
    ) throws -> URL? {
        guard let crashRecoveryJournal else { return nil }
        return try crashRecoveryJournal.checkpoint(CrashRecoveryRecord(
            documentID: documentID,
            generation: generation,
            filename: filename,
            targetURL: targetURL,
            reason: reason,
            data: data
        ))
    }

    func revisionIfPresent(at url: URL) throws -> DiskRevision? {
        do {
            return try DocumentRevisionReader.revision(at: url)
        } catch {
            if Self.isMissingFileError(error) { return nil }
            throw error
        }
    }

    func diskStateIfPresent(at url: URL) throws -> WorkspaceDiskState? {
        guard let disk = try documentSnapshotIfPresent(at: url) else { return nil }
        return WorkspaceDiskState(
            data: disk.data,
            source: String(data: disk.data, encoding: .utf8),
            revision: disk.revision
        )
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
}

private extension WorkspaceFileExecutor {
    func documentSnapshotIfPresent(
        at url: URL
    ) throws -> (data: Data, revision: DiskRevision)? {
        do {
            return try DocumentRevisionReader.documentSnapshot(at: url)
        } catch {
            if Self.isMissingFileError(error) { return nil }
            throw error
        }
    }

    func checkpoint(
        _ snapshot: Document.Snapshot,
        data: Data,
        reason: CrashRecoveryReason
    ) throws {
        guard let crashRecoveryJournal else { return }
        _ = try crashRecoveryJournal.checkpoint(CrashRecoveryRecord(
            documentID: snapshot.documentID,
            generation: BufferGeneration(
                bufferID: snapshot.documentID.rawValue,
                revision: snapshot.revision
            ),
            filename: snapshot.preferredFilename,
            targetURL: snapshot.fileURL,
            reason: reason,
            data: data
        ))
    }

    func makeConflict(
        snapshot: Document.Snapshot,
        locator: DocumentLocator,
        localData: Data,
        externalData: Data,
        externalRevision: DiskRevision,
        additionalExternalVersions: [ConflictSide]? = nil
    ) -> DocumentConflict {
        Workspace.makePreparedConflict(
            snapshot: snapshot,
            locator: locator,
            localData: localData,
            externalData: externalData,
            externalRevision: externalRevision,
            additionalExternalVersions: additionalExternalVersions
        )
    }

    func requiredLocator(
        _ locator: DocumentLocator?,
        for fileURL: URL
    ) throws -> DocumentLocator {
        guard let locator else {
            throw Workspace.WorkspaceError.documentDeleted(fileURL)
        }
        return locator
    }

    func restoreDetachedDocument(
        _ data: Data,
        locator: DocumentLocator,
        preferredFilename: String
    ) throws -> URL {
        guard locator.workspaceID == workspaceID else {
            throw Workspace.WorkspaceError.fileOutsideWorkspace(rootURL)
        }
        let desiredURL = rootURL
            .appendingPathComponent(locator.relativePath)
            .standardizedFileURL
        guard contains(desiredURL) else {
            throw Workspace.WorkspaceError.fileOutsideWorkspace(desiredURL)
        }
        let parentURL = desiredURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        if try writer.create(contents: data, at: desiredURL) {
            return desiredURL
        }
        return try writeNewDocument(
            data,
            in: parentURL,
            preferredFilename: preferredFilename
        )
    }

    func writeNewDocument(
        _ data: Data,
        in parentURL: URL,
        preferredFilename: String
    ) throws -> URL {
        let filename = Workspace.safeFilename(from: preferredFilename)
        let filenameURL = URL(fileURLWithPath: filename)
        let pathExtension = filenameURL.pathExtension
        let basename = filenameURL.deletingPathExtension().lastPathComponent

        for attempt in 1...Workspace.maximumCollisionAttempts {
            let candidateName: String
            if attempt == 1 {
                candidateName = filename
            } else if pathExtension.isEmpty {
                candidateName = "\(basename) (\(attempt))"
            } else {
                candidateName = "\(basename) (\(attempt)).\(pathExtension)"
            }
            let candidateURL = parentURL.appendingPathComponent(candidateName)
            if try writer.create(contents: data, at: candidateURL) {
                return candidateURL.standardizedFileURL
            }
        }
        throw Workspace.WorkspaceError.noAvailableFilename(filename)
    }

    func contains(_ fileURL: URL) -> Bool {
        let resolved = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        if resolved == rootURL { return true }
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return resolved.path.hasPrefix(prefix)
    }

    static func isMissingFileError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return error.code == Int(ENOENT) || error.code == Int(ENOTDIR)
        }
        return error.domain == NSCocoaErrorDomain
            && (error.code == CocoaError.fileNoSuchFile.rawValue
                || error.code == CocoaError.fileReadNoSuchFile.rawValue)
    }
}
