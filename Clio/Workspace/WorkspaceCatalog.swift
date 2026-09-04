import Foundation
import Observation

/// Owns the app-wide set of folder grants. A catalog is shared by every
/// window; each retained `Workspace` keeps its security scope active for as
/// long as the folder remains bookmarked.
@MainActor
@Observable
final class WorkspaceCatalog {
    struct AuthorizationFailure: Identifiable, Equatable {
        let id: WorkspaceID
        let folderName: String
        let message: String
    }

    private(set) var descriptors: [WorkspaceDescriptor] = []
    private(set) var authorizationFailures: [AuthorizationFailure] = []

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private let bookmarkMaker: @MainActor (URL) throws -> Data

    @ObservationIgnored
    private let bookmarkResolver: @MainActor (Data) throws -> Workspace.BookmarkResolution

    @ObservationIgnored
    private let workspaceFactory: @MainActor (URL) throws -> Workspace

    @ObservationIgnored
    private var activeWorkspaces: [WorkspaceID: Workspace] = [:]

    init(
        defaults: UserDefaults = .standard,
        bookmarkMaker: @escaping @MainActor (URL) throws -> Data = Workspace.makeSecurityScopedBookmark,
        bookmarkResolver: @escaping @MainActor (Data) throws -> Workspace.BookmarkResolution = Workspace.resolveSecurityScopedBookmark,
        workspaceFactory: @escaping @MainActor (URL) throws -> Workspace = { try Workspace(rootURL: $0) }
    ) {
        self.defaults = defaults
        self.bookmarkMaker = bookmarkMaker
        self.bookmarkResolver = bookmarkResolver
        self.workspaceFactory = workspaceFactory
        restore()
    }

    var workspaces: [Workspace] {
        descriptors.compactMap { activeWorkspaces[$0.id] }
    }

    func workspace(id: WorkspaceID) -> Workspace? {
        activeWorkspaces[id]
    }

    func descriptor(containing fileURL: URL) -> WorkspaceDescriptor? {
        descriptors
            .filter { descriptor in
                activeWorkspaces[descriptor.id]?.contains(fileURL) == true
            }
            .max { $0.rootURL.path.count < $1.rootURL.path.count }
    }

    /// Stores a Powerbox-authorized folder. The caller remains responsible for
    /// balancing the temporary scope supplied by `NSOpenPanel`.
    @discardableResult
    func addAuthorizedFolder(
        _ folderURL: URL,
        bookmark suppliedBookmark: Data? = nil
    ) throws -> WorkspaceDescriptor {
        let standardizedURL = folderURL.standardizedFileURL
        if let existing = descriptors.first(where: {
            $0.rootURL == standardizedURL.resolvingSymlinksInPath()
        }) {
            return existing
        }

        let bookmark = try suppliedBookmark ?? bookmarkMaker(standardizedURL)
        let resolution = try bookmarkResolver(bookmark)
        let workspace = try workspaceFactory(resolution.url)
        let descriptor = WorkspaceDescriptor(rootURL: workspace.rootURL)
        let refreshedBookmark = resolution.isStale
            ? try bookmarkMaker(resolution.url)
            : bookmark

        activeWorkspaces[descriptor.id] = workspace
        descriptors.append(descriptor)
        descriptors.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        persist(adding: StoredWorkspace(descriptor: descriptor, bookmark: refreshedBookmark))
        return descriptor
    }

    func remove(_ id: WorkspaceID) {
        descriptors.removeAll { $0.id == id }
        activeWorkspaces[id] = nil
        authorizationFailures.removeAll { $0.id == id }
        persistCurrentEntries()
    }

    /// Replaces a stale or revoked grant without changing the workspace's
    /// logical identity, so restored tabs and index identities remain valid.
    func reauthorize(_ id: WorkspaceID, with folderURL: URL) throws {
        let bookmark = try bookmarkMaker(folderURL.standardizedFileURL)
        let resolution = try bookmarkResolver(bookmark)
        let workspace = try workspaceFactory(resolution.url)
        let previous = storedEntries().first { $0.id == id }
        let descriptor = WorkspaceDescriptor(
            id: id,
            rootURL: workspace.rootURL,
            displayName: previous?.displayName ?? workspace.rootURL.lastPathComponent
        )
        let refreshedBookmark = resolution.isStale
            ? try bookmarkMaker(resolution.url)
            : bookmark

        activeWorkspaces[id] = workspace
        descriptors.removeAll { $0.id == id }
        descriptors.append(descriptor)
        descriptors.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        authorizationFailures.removeAll { $0.id == id }
        persist(adding: StoredWorkspace(descriptor: descriptor, bookmark: refreshedBookmark))
    }

    func dismissAuthorizationFailure(_ id: WorkspaceID) {
        authorizationFailures.removeAll { $0.id == id }
    }
}

private extension WorkspaceCatalog {
    struct StoredWorkspace: Codable, Equatable {
        let id: WorkspaceID
        let displayName: String
        let bookmark: Data

        init(descriptor: WorkspaceDescriptor, bookmark: Data) {
            id = descriptor.id
            displayName = descriptor.displayName
            self.bookmark = bookmark
        }
    }

    enum Keys {
        static let bookmarkedWorkspaces = "workspace.bookmarkedFolders.v2"
    }

    func restore() {
        guard let data = defaults.data(forKey: Keys.bookmarkedWorkspaces),
              let stored = try? JSONDecoder().decode([StoredWorkspace].self, from: data) else {
            return
        }

        var retainedEntries: [StoredWorkspace] = []
        for entry in stored {
            do {
                let resolution = try bookmarkResolver(entry.bookmark)
                let workspace = try workspaceFactory(resolution.url)
                let descriptor = WorkspaceDescriptor(
                    id: entry.id,
                    rootURL: workspace.rootURL,
                    displayName: entry.displayName
                )
                let bookmark = resolution.isStale
                    ? try bookmarkMaker(resolution.url)
                    : entry.bookmark
                activeWorkspaces[entry.id] = workspace
                descriptors.append(descriptor)
                retainedEntries.append(StoredWorkspace(descriptor: descriptor, bookmark: bookmark))
            } catch {
                retainedEntries.append(entry)
                authorizationFailures.append(
                    AuthorizationFailure(
                        id: entry.id,
                        folderName: entry.displayName,
                        message: error.localizedDescription
                    )
                )
            }
        }
        descriptors.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        save(retainedEntries)
    }

    func persist(adding newEntry: StoredWorkspace) {
        var entries = storedEntries().filter { $0.id != newEntry.id }
        entries.append(newEntry)
        save(entries)
    }

    func persistCurrentEntries() {
        let retainedIDs = Set(descriptors.map(\.id) + authorizationFailures.map(\.id))
        save(storedEntries().filter { retainedIDs.contains($0.id) })
    }

    func storedEntries() -> [StoredWorkspace] {
        guard let data = defaults.data(forKey: Keys.bookmarkedWorkspaces) else { return [] }
        return (try? JSONDecoder().decode([StoredWorkspace].self, from: data)) ?? []
    }

    func save(_ entries: [StoredWorkspace]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Keys.bookmarkedWorkspaces)
    }
}
