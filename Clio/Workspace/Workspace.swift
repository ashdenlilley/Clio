import Darwin
import Foundation

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

    let rootURL: URL
    let isSecurityScopedAccessActive: Bool

    private let fileManager: FileManager
    private let securityScopedURL: URL?

    init(
        rootURL: URL,
        accessSecurityScopedResource: Bool = true,
        fileManager: FileManager = .default
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

            self.rootURL = resolvedURL
            self.fileManager = fileManager
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

    func loadDocument(at fileURL: URL) throws -> Document {
        let fileURL = fileURL.standardizedFileURL
        guard contains(fileURL) else {
            throw WorkspaceError.fileOutsideWorkspace(fileURL)
        }
        return try Document(contentsOf: fileURL)
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
    func save(_ document: Document) throws -> URL? {
        let snapshot = document.snapshot()

        guard snapshot.isDirty else {
            return snapshot.fileURL
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

            try data.write(to: fileURL, options: .atomic)
            destinationURL = fileURL
        } else {
            destinationURL = try writeNewDocument(
                data,
                preferredFilename: snapshot.preferredFilename
            )
        }

        document.didWrite(snapshot, to: destinationURL)
        return destinationURL
    }
}

private extension Workspace {
    static let documentExtensions: Set<String> = ["md", "markdown", "txt"]
    static let maximumCollisionAttempts = 10_000

    func writeNewDocument(_ data: Data, preferredFilename: String) throws -> URL {
        let filename = Self.safeFilename(from: preferredFilename)
        let filenameURL = URL(fileURLWithPath: filename)
        let pathExtension = filenameURL.pathExtension
        let basename = filenameURL.deletingPathExtension().lastPathComponent
        let temporaryURL = rootURL.appendingPathComponent(
            ".clio-save-\(UUID().uuidString)",
            isDirectory: false
        )

        try data.write(to: temporaryURL, options: .atomic)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        for attempt in 1...Self.maximumCollisionAttempts {
            let candidateName: String
            if attempt == 1 {
                candidateName = filename
            } else if pathExtension.isEmpty {
                candidateName = "\(basename) \(attempt)"
            } else {
                candidateName = "\(basename) \(attempt).\(pathExtension)"
            }

            let candidateURL = rootURL.appendingPathComponent(candidateName)

            let renameResult = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
                candidateURL.withUnsafeFileSystemRepresentation { destinationPath in
                    renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                }
            }

            if renameResult == 0 {
                return candidateURL.standardizedFileURL
            }

            let errorNumber = errno
            if errorNumber == EEXIST {
                continue
            }

            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorNumber),
                userInfo: [NSFilePathErrorKey: candidateURL.path]
            )
        }

        throw WorkspaceError.noAvailableFilename(filename)
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
