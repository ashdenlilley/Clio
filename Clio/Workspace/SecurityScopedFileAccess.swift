import Foundation

/// Retains the exact Powerbox grant for a file until its tab either closes or
/// adopts a broader, bookmarked workspace. The bookmark travels with session
/// restoration so declining the parent-folder prompt never turns the file
/// into an unresolvable blank tab on relaunch.
final class SecurityScopedFileLease: @unchecked Sendable {
    let url: URL
    let bookmark: Data
    let isSecurityScopeActive: Bool

    private let accessURL: URL
    private let lock = NSLock()
    private let stopAccess: @Sendable (URL) -> Void
    private var isReleased = false

    init(
        url: URL,
        bookmark: Data,
        isSecurityScopeActive: Bool,
        stopAccess: @escaping @Sendable (URL) -> Void
    ) {
        accessURL = url
        self.url = url.standardizedFileURL
        self.bookmark = bookmark
        self.isSecurityScopeActive = isSecurityScopeActive
        self.stopAccess = stopAccess
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        let shouldStop = isSecurityScopeActive
        lock.unlock()
        if shouldStop { stopAccess(accessURL) }
    }

    deinit {
        release()
    }
}

struct SecurityScopedFileAccessController: Sendable {
    enum AccessError: LocalizedError {
        case accessDenied(URL)

        var errorDescription: String? {
            switch self {
            case let .accessDenied(url):
                "Clio could not retain access to \(url.lastPathComponent)."
            }
        }
    }

    private let bookmarkMaker: @Sendable (URL) throws -> Data
    private let bookmarkResolver: @Sendable (Data) throws -> Workspace.BookmarkResolution
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void

    init(
        bookmarkMaker: @escaping @Sendable (URL) throws -> Data = Workspace.makeSecurityScopedBookmark,
        bookmarkResolver: @escaping @Sendable (Data) throws -> Workspace.BookmarkResolution = Workspace.resolveSecurityScopedBookmark,
        startAccess: @escaping @Sendable (URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        stopAccess: @escaping @Sendable (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) {
        self.bookmarkMaker = bookmarkMaker
        self.bookmarkResolver = bookmarkResolver
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    func acquireSelectedFile(at fileURL: URL) throws -> SecurityScopedFileLease {
        do {
            return SecurityScopedFileLease(
                url: fileURL,
                bookmark: try bookmarkMaker(fileURL),
                isSecurityScopeActive: true,
                stopAccess: stopAccess
            )
        } catch {
            // NSOpenPanel/Dock hand the app one already-started scope. Failure
            // to capture its bookmark must balance that implicit grant now.
            stopAccess(fileURL)
            throw error
        }
    }

    /// Balances an already-started Powerbox/Dock grant when the incoming URL
    /// is routed to an existing tab or an already-bookmarked workspace.
    func releaseIncomingSelection(at fileURL: URL) {
        stopAccess(fileURL)
    }

    func acquireRestoredFile(from bookmark: Data) throws -> SecurityScopedFileLease {
        let resolution = try bookmarkResolver(bookmark)
        let url = resolution.url
        guard startAccess(url) else { throw AccessError.accessDenied(url) }
        let retainedBookmark: Data
        do {
            retainedBookmark = resolution.isStale ? try bookmarkMaker(url) : bookmark
        } catch {
            stopAccess(url)
            throw error
        }
        return SecurityScopedFileLease(
            url: url,
            bookmark: retainedBookmark,
            isSecurityScopeActive: true,
            stopAccess: stopAccess
        )
    }
}
