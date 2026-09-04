import Foundation
import Observation

/// Owns the app-wide set of folder grants. A catalog is shared by every
/// window; each retained `Workspace` keeps its security scope active for as
/// long as the folder remains bookmarked.
@MainActor
@Observable
final class WorkspaceCatalog {
    enum CatalogError: LocalizedError, Equatable {
        case workspaceUnavailable(WorkspaceID)
        case mismatchedWorkspaceReference
        case mismatchedWorkspaceIdentity(expected: WorkspaceID, actual: WorkspaceID)

        var errorDescription: String? {
            switch self {
            case .workspaceUnavailable:
                "The folder for this document is no longer available."
            case .mismatchedWorkspaceReference:
                "The document reference does not belong to its workspace."
            case .mismatchedWorkspaceIdentity:
                "The authorized workspace did not retain its stored identity."
            }
        }
    }

    struct AuthorizationFailure: Identifiable, Equatable {
        let id: WorkspaceID
        let folderName: String
        let message: String
    }

    private(set) var descriptors: [WorkspaceDescriptor] = []
    private(set) var authorizationFailures: [AuthorizationFailure] = []
    private(set) var recoveryFailureMessage: String?
    private(set) var recoveredInterruptedMoveCount = 0

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private let bookmarkMaker: @MainActor (URL) throws -> Data

    @ObservationIgnored
    private let bookmarkResolver: @MainActor (Data) throws -> Workspace.BookmarkResolution

    @ObservationIgnored
    private let workspaceFactory: @MainActor (
        WorkspaceID,
        URL,
        CrashRecoveryJournal
    ) throws -> Workspace

    @ObservationIgnored
    private let crashRecoveryJournal: CrashRecoveryJournal

    @ObservationIgnored
    private var activeWorkspaces: [WorkspaceID: Workspace] = [:]

    @ObservationIgnored
    private var moveRecoveryTask: Task<Void, Never>?

    @ObservationIgnored
    private var moveRecoveryRescanRequested = false

    init(
        defaults: UserDefaults = .standard,
        bookmarkMaker: @escaping @MainActor (URL) throws -> Data = Workspace.makeSecurityScopedBookmark,
        bookmarkResolver: @escaping @MainActor (Data) throws -> Workspace.BookmarkResolution = Workspace.resolveSecurityScopedBookmark,
        crashRecoveryJournal: CrashRecoveryJournal = .shared,
        workspaceFactory: @escaping @MainActor (
            WorkspaceID,
            URL,
            CrashRecoveryJournal
        ) throws -> Workspace = {
            try Workspace(id: $0, rootURL: $1, crashRecoveryJournal: $2)
        }
    ) {
        self.defaults = defaults
        self.bookmarkMaker = bookmarkMaker
        self.bookmarkResolver = bookmarkResolver
        self.workspaceFactory = workspaceFactory
        self.crashRecoveryJournal = crashRecoveryJournal
        restore()
        scheduleInterruptedMoveRecovery()
    }

    deinit {
        moveRecoveryTask?.cancel()
    }

    var workspaces: [Workspace] {
        descriptors.compactMap { activeWorkspaces[$0.id] }
    }

    func workspace(id: WorkspaceID) -> Workspace? {
        activeWorkspaces[id]
    }

    /// Resolves discovery identities through the canonical buffer registry.
    /// The result's proposed ID is adopted only for a file that has no prior
    /// physical or locator mapping.
    func openDocument(
        for file: WorkspaceFile,
        registry: DocumentBufferRegistry
    ) throws -> Document {
        guard let workspace = activeWorkspaces[file.locator.workspaceID] else {
            throw CatalogError.workspaceUnavailable(file.locator.workspaceID)
        }
        guard file.relativePath == file.locator.relativePath else {
            throw CatalogError.mismatchedWorkspaceReference
        }
        let url = try workspace.fileURL(for: file.locator)
        return try registry.open(url, in: workspace, preferredID: file.documentID)
    }

    func openDocumentInBackground(
        for file: WorkspaceFile,
        registry: DocumentBufferRegistry
    ) async throws -> Document {
        guard let workspace = activeWorkspaces[file.locator.workspaceID] else {
            throw CatalogError.workspaceUnavailable(file.locator.workspaceID)
        }
        guard file.relativePath == file.locator.relativePath else {
            throw CatalogError.mismatchedWorkspaceReference
        }
        let url = try workspace.fileURL(for: file.locator)
        return try await registry.openInBackground(
            url,
            in: workspace,
            preferredID: file.documentID
        )
    }

    func openDocument(
        for result: WorkspaceSearchResult,
        registry: DocumentBufferRegistry
    ) throws -> Document {
        guard let workspace = activeWorkspaces[result.workspaceID] else {
            throw CatalogError.workspaceUnavailable(result.workspaceID)
        }
        let locator = try DocumentLocator(
            workspaceID: result.workspaceID,
            relativePath: result.relativePath
        )
        let url = try workspace.fileURL(for: locator)
        return try registry.open(url, in: workspace, preferredID: result.documentID)
    }

    func openDocumentInBackground(
        for result: WorkspaceSearchResult,
        registry: DocumentBufferRegistry
    ) async throws -> Document {
        guard let workspace = activeWorkspaces[result.workspaceID] else {
            throw CatalogError.workspaceUnavailable(result.workspaceID)
        }
        let locator = try DocumentLocator(
            workspaceID: result.workspaceID,
            relativePath: result.relativePath
        )
        let url = try workspace.fileURL(for: locator)
        return try await registry.openInBackground(
            url,
            in: workspace,
            preferredID: result.documentID
        )
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
        let workspaceID = WorkspaceID()
        let workspace = try makeWorkspace(id: workspaceID, rootURL: resolution.url)
        let descriptor = WorkspaceDescriptor(id: workspaceID, rootURL: workspace.rootURL)
        let refreshedBookmark = resolution.isStale
            ? try bookmarkMaker(resolution.url)
            : bookmark

        activeWorkspaces[descriptor.id] = workspace
        descriptors.append(descriptor)
        descriptors.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        persist(adding: StoredWorkspace(descriptor: descriptor, bookmark: refreshedBookmark))
        scheduleInterruptedMoveRecovery()
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
        let workspace = try makeWorkspace(id: id, rootURL: resolution.url)
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
        scheduleInterruptedMoveRecovery()
    }

    func dismissAuthorizationFailure(_ id: WorkspaceID) {
        authorizationFailures.removeAll { $0.id == id }
    }
}

private extension WorkspaceCatalog {
    func scheduleInterruptedMoveRecovery() {
        guard moveRecoveryTask == nil else {
            moveRecoveryRescanRequested = true
            return
        }
        moveRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.moveRecoveryRescanRequested = false
                let roots = self.workspaces.map(\.rootURL)
                let journal = self.crashRecoveryJournal
                do {
                    let recovered = try await Task.detached(priority: .utility) {
                        try InterruptedMoveTransactions.recover(
                            inAuthorizedRoots: roots,
                            journal: journal
                        )
                    }.value
                    self.recoveredInterruptedMoveCount += recovered
                    self.recoveryFailureMessage = nil
                } catch is CancellationError {
                    return
                } catch {
                    self.recoveryFailureMessage = error.localizedDescription
                }
            } while self.moveRecoveryRescanRequested
            self.moveRecoveryTask = nil
        }
    }

    func makeWorkspace(id: WorkspaceID, rootURL: URL) throws -> Workspace {
        let workspace = try workspaceFactory(id, rootURL, crashRecoveryJournal)
        guard workspace.id == id else {
            throw CatalogError.mismatchedWorkspaceIdentity(
                expected: id,
                actual: workspace.id
            )
        }
        return workspace
    }

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
                let workspace = try makeWorkspace(id: entry.id, rootURL: resolution.url)
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
