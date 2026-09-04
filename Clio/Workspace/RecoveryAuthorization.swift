import Foundation

struct DefaultFolderGrants: Sendable, Equatable {
    let workspaceURL: URL
    let recoveryURL: URL
    let workspaceBookmark: Data
    let recoveryBookmark: Data
}

enum RecoveryAuthorization {
    enum AuthorizationError: LocalizedError {
        case accessDenied(URL)

        var errorDescription: String? {
            switch self {
            case .accessDenied(let url):
                "Clio could not retain access to the recovery folder at \(url.path)."
            }
        }
    }

    static func createDefaultGrants(
        in selectedURL: URL,
        fileManager: FileManager = .default
    ) throws -> DefaultFolderGrants {
        let selected = selectedURL.standardizedFileURL
        let documentsURL = selected.lastPathComponent.caseInsensitiveCompare("Clio") == .orderedSame
            ? selected.deletingLastPathComponent()
            : selected
        let workspaceURL = documentsURL.appendingPathComponent("Clio", isDirectory: true)
        let recoveryURL = documentsURL.appendingPathComponent("Clio Recovery", isDirectory: true)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
        return DefaultFolderGrants(
            workspaceURL: workspaceURL,
            recoveryURL: recoveryURL,
            workspaceBookmark: try Workspace.makeSecurityScopedBookmark(for: workspaceURL),
            recoveryBookmark: try Workspace.makeSecurityScopedBookmark(for: recoveryURL)
        )
    }

    static func restore(
        bookmark: Data
    ) throws -> (store: RecoveryStore, bookmarkToPersist: Data) {
        let resolution = try Workspace.resolveSecurityScopedBookmark(bookmark)
        let store = RecoveryStore(
            rootURL: resolution.url,
            accessSecurityScopedResource: true
        )
        guard store.isSecurityScopedAccessActive else {
            throw AuthorizationError.accessDenied(resolution.url)
        }
        return (
            store,
            try bookmarkForPersistence(
                original: bookmark,
                resolution: resolution
            )
        )
    }

    static func bookmarkForPersistence(
        original: Data,
        resolution: Workspace.BookmarkResolution,
        refresh: (URL) throws -> Data = Workspace.makeSecurityScopedBookmark
    ) throws -> Data {
        resolution.isStale ? try refresh(resolution.url) : original
    }
}
