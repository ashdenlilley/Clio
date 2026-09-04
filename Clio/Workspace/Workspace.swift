import Darwin
import Foundation

private struct SelfWriteRecord {
    let token: UUID
    let revision: DiskRevision
    let expiresAt: Date
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
    private var selfWrites: [String: SelfWriteRecord] = [:]
    private let securityScopedURL: URL?

    init(
        id: WorkspaceID = WorkspaceID(),
        rootURL: URL,
        accessSecurityScopedResource: Bool = true,
        fileManager: FileManager = .default,
        atomicWriter: any AtomicFileWriting = AtomicFileWriter()
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
            isSecurityScopedAccessActive = didStartSecurityScopedAccess
            securityScopedURL = didStartSecurityScopedAccess ? scopedURL : nil
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

    func locator(for fileURL: URL) throws -> DocumentLocator {
        let standardizedURL = fileURL.standardizedFileURL
        guard contains(standardizedURL), standardizedURL != rootURL else {
            throw WorkspaceError.fileOutsideWorkspace(standardizedURL)
        }
        return try DocumentLocator(
            workspaceID: id,
            relativePath: relativePath(for: standardizedURL)
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
        let standardizedURL = fileURL.standardizedFileURL
        guard contains(standardizedURL) else {
            return standardizedURL.lastPathComponent
        }

        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return String(standardizedURL.path.dropFirst(rootPath.count))
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

            let current = try DocumentRevisionReader.snapshot(at: fileURL)
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
                    let latest = try DocumentRevisionReader.snapshot(at: fileURL)
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
        return destinationURL
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

        let disk = try DocumentRevisionReader.snapshot(at: fileURL)
        if consumeSelfWrite(at: fileURL, revision: disk.revision) != nil {
            return
        }
        if let expected = document.expectedDiskRevision,
           Self.sameContent(expected, disk.revision) {
            return
        }

        if document.isDirty {
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

        let prior = document.snapshot()
        let disk = try DocumentRevisionReader.snapshot(at: newURL)
        let contentChanged = prior.expectedDiskRevision.map {
            !Self.sameContent($0, disk.revision)
        } ?? true

        document.prepareForExternalMove(to: newURL)
        if !contentChanged {
            document.didMove(to: newURL, revision: disk.revision)
            return
        }

        if prior.isDirty {
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

    func readDiskSnapshot(
        for document: Document
    ) throws -> (data: Data, source: String?, revision: DiskRevision) {
        guard let fileURL = document.fileURL else {
            throw WorkspaceError.documentDeleted(rootURL)
        }
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw WorkspaceError.documentDeleted(fileURL)
        }
        let disk = try DocumentRevisionReader.snapshot(at: fileURL)
        return (disk.data, String(data: disk.data, encoding: .utf8), disk.revision)
    }

    func replaceAfterConflict(
        _ document: Document,
        expectedExternalRevision: DiskRevision
    ) throws -> URL {
        guard let destinationURL = document.fileURL else {
            throw WorkspaceError.documentDeleted(rootURL)
        }
        let current = try DocumentRevisionReader.revision(at: destinationURL)
        guard Self.sameContent(current, expectedExternalRevision) else {
            try reconcileExternalChange(for: document)
            if let refreshedConflict = document.conflict {
                throw WorkspaceError.externalConflict(refreshedConflict)
            }
            throw WorkspaceError.documentDeleted(destinationURL)
        }
        let snapshot = document.snapshot()
        document.willWrite(snapshot)
        do {
            let replaceOutcome = try atomicWriter.replace(
                contents: Data(snapshot.text.utf8),
                at: destinationURL,
                onlyIf: current
            )
            guard case .replaced = replaceOutcome else {
                let latest = try DocumentRevisionReader.snapshot(at: destinationURL)
                let retainedURL: URL?
                if case .revisionMismatch(let url) = replaceOutcome {
                    retainedURL = url
                } else {
                    retainedURL = nil
                }
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
            document.didFailWrite(snapshot)
            throw error
        }
        let revision = try DocumentRevisionReader.revision(at: destinationURL)
        selfWrites[destinationURL.path] = SelfWriteRecord(
            token: UUID(),
            revision: revision,
            expiresAt: Date().addingTimeInterval(5)
        )
        document.didWrite(snapshot, to: destinationURL, revision: revision)
        return destinationURL
    }

    func saveConflictCopy(_ document: Document) throws -> URL {
        let snapshot = document.snapshot()
        let destinationURL = try writeNewDocument(
            Data(snapshot.text.utf8),
            preferredFilename: snapshot.fileURL?.lastPathComponent
                ?? snapshot.preferredFilename
        )
        let revision = try DocumentRevisionReader.revision(at: destinationURL)
        selfWrites[destinationURL.path] = SelfWriteRecord(
            token: UUID(),
            revision: revision,
            expiresAt: Date().addingTimeInterval(5)
        )
        document.didWrite(snapshot, to: destinationURL, revision: revision)
        return destinationURL
    }
}

extension Workspace {
    static let documentExtensions: Set<String> = ["md", "markdown", "txt"]
    static let maximumCollisionAttempts = 10_000

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
        let retained = try DocumentRevisionReader.snapshot(at: url)
        return ConflictSide(
            modificationDate: retained.revision.modificationDate,
            revision: retained.revision,
            data: retained.data,
            retainedURLs: [url]
        )
    }

    nonisolated static func sameContent(_ lhs: DiskRevision, _ rhs: DiskRevision) -> Bool {
        lhs.byteCount == rhs.byteCount && lhs.contentDigest == rhs.contentDigest
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
