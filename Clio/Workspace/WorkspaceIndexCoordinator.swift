import Foundation
import Observation

/// Connects folder grants, discovery snapshots, the disposable search index,
/// canonical buffers, and folder watchers. Stage 5 consumes this service for
/// sidebar/search presentation without owning any filesystem identity state.
@MainActor
@Observable
final class WorkspaceIndexCoordinator {
    struct Failure: Equatable {
        let workspaceID: WorkspaceID?
        let message: String
    }

    typealias WatcherFactory = @MainActor (WorkspaceDescriptor) -> any WorkspaceEventSource
    typealias EventReconciler = @MainActor (WorkspaceEvent, Workspace) async throws -> Void

    private(set) var treeSnapshots: [WorkspaceID: WorkspaceTreeSnapshot] = [:]
    private(set) var failures: [WorkspaceID: Failure] = [:]
    private(set) var globalFailure: Failure?

    @ObservationIgnored private let catalog: WorkspaceCatalog
    @ObservationIgnored private let registry: DocumentBufferRegistry
    @ObservationIgnored private let scanner: WorkspaceScanner
    @ObservationIgnored private let searchIndex: any SearchIndexing
    @ObservationIgnored private let watcherFactory: WatcherFactory
    @ObservationIgnored private let eventReconciler: EventReconciler?
    @ObservationIgnored private var policy = DiscoveryPolicy.default
    @ObservationIgnored private var includesIgnoredInTree = false
    @ObservationIgnored private var mutationGeneration: UInt64 = 0
    @ObservationIgnored private var watcherSources: [WorkspaceID: any WorkspaceEventSource] = [:]
    @ObservationIgnored private var watcherTasks: [WorkspaceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchedRootURLs: [WorkspaceID: URL] = [:]
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var isApplyingWatcherEvents = false
    @ObservationIgnored private var isSynchronizing = false
    @ObservationIgnored private var activeSynchronizationToken: UUID?
    @ObservationIgnored private var hasCompletedSynchronization = false
    @ObservationIgnored private var pendingEvents: [WorkspaceID: [WorkspaceEvent]] = [:]
    @ObservationIgnored private var deferredBufferDeletions: [
        String: (token: UUID, workspaceID: WorkspaceID, task: Task<Void, Never>)
    ] = [:]
    @ObservationIgnored private var deferredBufferAudits: [
        WorkspaceID: (token: UUID, task: Task<Void, Never>)
    ] = [:]
    @ObservationIgnored private var recentMoveSourceExpirations: [String: Date] = [:]

    private static let aliasMoveCorrelationDelay = Duration.milliseconds(500)
    private static let recentMoveRetention: TimeInterval = 5

    init(
        catalog: WorkspaceCatalog,
        registry: DocumentBufferRegistry,
        searchIndex: any SearchIndexing,
        scanner: WorkspaceScanner? = nil,
        eventReconciler: EventReconciler? = nil,
        watcherFactory: @escaping WatcherFactory = {
            WorkspaceWatcher(workspaceID: $0.id, rootURL: $0.rootURL)
        }
    ) {
        self.catalog = catalog
        self.registry = registry
        self.searchIndex = searchIndex
        self.scanner = scanner ?? WorkspaceScanner(identityStore: registry.identityStore)
        self.watcherFactory = watcherFactory
        self.eventReconciler = eventReconciler
    }

    convenience init(
        catalog: WorkspaceCatalog,
        registry: DocumentBufferRegistry,
        databaseURL: URL = SQLiteSearchIndex.defaultDatabaseURL
    ) throws {
        try self.init(
            catalog: catalog,
            registry: registry,
            searchIndex: SQLiteSearchIndex(
                databaseURL: databaseURL,
                identityStore: registry.identityStore
            )
        )
    }

    deinit {
        watcherTasks.values.forEach { $0.cancel() }
        debounceTask?.cancel()
        deferredBufferDeletions.values.forEach { $0.task.cancel() }
        deferredBufferAudits.values.forEach { $0.task.cancel() }
    }

    /// Reconciles watcher ownership and rebuilds both tree and index from the
    /// current global catalog. Call after authorization/settings changes.
    func synchronize(
        policy: DiscoveryPolicy,
        includesIgnored: Bool = false
    ) async throws {
        mutationGeneration &+= 1
        let generation = mutationGeneration
        let synchronizationToken = UUID()
        activeSynchronizationToken = synchronizationToken
        isSynchronizing = true
        defer {
            if activeSynchronizationToken == synchronizationToken {
                activeSynchronizationToken = nil
                isSynchronizing = false
                if hasCompletedSynchronization { schedulePendingEventsIfNeeded() }
            }
        }
        self.policy = policy
        includesIgnoredInTree = includesIgnored
        reconcileWatchers()
        let descriptors = catalog.descriptors
        var snapshots = treeSnapshots.filter { id, _ in
            descriptors.contains { $0.id == id }
        }

        for descriptor in descriptors {
            do {
                let scanned = try await scanner.scan(
                    workspace: descriptor,
                    policy: policy,
                    includesIgnored: includesIgnored
                )
                guard generation == mutationGeneration else { throw CancellationError() }
                // Scanner IDs already come from the persistent authority.
                // Keep this 25k-file path off the registry/MainActor hot loop.
                snapshots[descriptor.id] = scanned
                failures[descriptor.id] = nil
            } catch {
                failures[descriptor.id] = Failure(
                    workspaceID: descriptor.id,
                    message: error.localizedDescription
                )
            }
        }
        guard generation == mutationGeneration else { throw CancellationError() }
        treeSnapshots = snapshots

        do {
            try await searchIndex.rebuild(workspaces: descriptors, policy: policy)
            guard generation == mutationGeneration else { throw CancellationError() }
            globalFailure = nil
            hasCompletedSynchronization = true
        } catch {
            globalFailure = Failure(workspaceID: nil, message: error.localizedDescription)
            throw error
        }
    }

    /// Applies watcher batches to the index, then invalidates only affected
    /// workspace trees. Full-rescan events are handled by the index itself.
    func apply(_ events: [WorkspaceEvent]) async throws {
        try await apply(events, reconcilingBuffers: true)
    }

    /// Records a Stage 2 move after the filesystem commit. This preserves the
    /// canonical ID across workspace roots and invalidates both search rows and
    /// trees without re-running buffer reconciliation for an already-moved file.
    func recordCommittedMove(
        documentID: DocumentID,
        from source: DocumentLocator,
        to destination: DocumentLocator
    ) async throws {
        guard let sourceWorkspace = catalog.workspace(id: source.workspaceID),
              let destinationWorkspace = catalog.workspace(id: destination.workspaceID) else {
            throw WorkspaceCatalog.CatalogError.workspaceUnavailable(destination.workspaceID)
        }
        let sourceURL = try sourceWorkspace.fileURL(for: source)
        let destinationURL = try destinationWorkspace.fileURL(for: destination)
        _ = try registry.identityStore.migrate(
            documentID: documentID,
            from: source,
            to: destination,
            physicalIdentity: .authorizedFile(at: destinationURL),
            destinationPath: destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
        )
        try await apply(
            [
                WorkspaceEvent(
                    workspaceID: source.workspaceID,
                    kind: .deleted,
                    fileURL: sourceURL,
                    origin: .clio
                ),
                WorkspaceEvent(
                    workspaceID: destination.workspaceID,
                    kind: .created,
                    fileURL: destinationURL,
                    origin: .clio
                ),
            ],
            reconcilingBuffers: false
        )
    }

    private func apply(
        _ events: [WorkspaceEvent],
        reconcilingBuffers: Bool
    ) async throws {
        guard !events.isEmpty else { return }
        mutationGeneration &+= 1
        let generation = mutationGeneration
        if reconcilingBuffers, let eventReconciler {
            try await reconcileBuffers(
                for: events,
                generation: generation,
                using: eventReconciler
            )
        }
        let accessFailures = events.filter {
            $0.kind == .accessLost || $0.kind == .error
        }
        let inaccessibleWorkspaceIDs = Set(accessFailures.map(\.workspaceID))
        for event in accessFailures {
            watcherTasks.removeValue(forKey: event.workspaceID)?.cancel()
            watcherSources[event.workspaceID] = nil
            watchedRootURLs[event.workspaceID] = nil
            cancelDeferredDeletions(for: event.workspaceID)
            failures[event.workspaceID] = Failure(
                workspaceID: event.workspaceID,
                message: "Clio lost access to this workspace. Its last index and tree remain available."
            )
        }
        let actionableEvents = events.filter {
            !inaccessibleWorkspaceIDs.contains($0.workspaceID)
                && $0.kind != .accessLost
                && $0.kind != .error
        }
        guard !actionableEvents.isEmpty else { return }
        do {
            try await searchIndex.apply(actionableEvents)
            guard generation == mutationGeneration else { throw CancellationError() }
            globalFailure = nil
        } catch {
            globalFailure = Failure(workspaceID: nil, message: error.localizedDescription)
            throw error
        }

        for workspaceID in Set(actionableEvents.map(\.workspaceID)) {
            guard let descriptor = catalog.descriptors.first(where: { $0.id == workspaceID }) else {
                treeSnapshots[workspaceID] = nil
                failures[workspaceID] = nil
                continue
            }
            do {
                let scanned = try await scanner.scan(
                    workspace: descriptor,
                    policy: policy,
                    includesIgnored: includesIgnoredInTree
                )
                guard generation == mutationGeneration else { throw CancellationError() }
                treeSnapshots[workspaceID] = scanned
                failures[workspaceID] = nil
            } catch {
                failures[workspaceID] = Failure(
                    workspaceID: workspaceID,
                    message: error.localizedDescription
                )
            }
        }
        guard generation == mutationGeneration else { throw CancellationError() }
    }

    func open(_ file: WorkspaceFile) throws -> Document {
        try catalog.openDocument(for: file, registry: registry)
    }

    func open(_ result: WorkspaceSearchResult) throws -> Document {
        try catalog.openDocument(for: result, registry: registry)
    }

    func quickOpen(
        _ query: WorkspaceSearchQuery
    ) async -> AsyncThrowingStream<SearchBatch, Error> {
        canonicalizing(await searchIndex.quickOpen(query))
    }

    func search(
        _ query: WorkspaceSearchQuery
    ) async -> AsyncThrowingStream<SearchBatch, Error> {
        canonicalizing(await searchIndex.search(query))
    }

    func stopWatching() {
        mutationGeneration &+= 1
        activeSynchronizationToken = nil
        isSynchronizing = false
        watcherTasks.values.forEach { $0.cancel() }
        debounceTask?.cancel()
        watcherTasks.removeAll()
        debounceTask = nil
        watcherSources.removeAll()
        watchedRootURLs.removeAll()
        pendingEvents.removeAll()
        deferredBufferDeletions.values.forEach { $0.task.cancel() }
        deferredBufferDeletions.removeAll()
        deferredBufferAudits.values.forEach { $0.task.cancel() }
        deferredBufferAudits.removeAll()
        recentMoveSourceExpirations.removeAll()
    }
}

private extension WorkspaceIndexCoordinator {
    func reconcileWatchers() {
        let descriptors = catalog.descriptors
        let desiredIDs = Set(descriptors.map(\.id))
        for id in watcherTasks.keys where !desiredIDs.contains(id) {
            watcherTasks.removeValue(forKey: id)?.cancel()
            watcherSources[id] = nil
            watchedRootURLs[id] = nil
            pendingEvents[id] = nil
            cancelDeferredDeletions(for: id)
        }

        for descriptor in descriptors {
            let rootURL = descriptor.rootURL.standardizedFileURL
            guard let watched = watchedRootURLs[descriptor.id],
                  watched != rootURL else { continue }
            watcherTasks.removeValue(forKey: descriptor.id)?.cancel()
            watcherSources[descriptor.id] = nil
            watchedRootURLs[descriptor.id] = nil
            pendingEvents[descriptor.id] = nil
            cancelDeferredDeletions(for: descriptor.id)
        }

        for descriptor in descriptors where watcherTasks[descriptor.id] == nil {
            let source = watcherFactory(descriptor)
            watcherSources[descriptor.id] = source
            watchedRootURLs[descriptor.id] = descriptor.rootURL.standardizedFileURL
            watcherTasks[descriptor.id] = Task { [weak self, source] in
                let stream = await source.events()
                for await event in stream {
                    guard !Task.isCancelled else { return }
                    self?.enqueue(event)
                }
            }
        }
    }

    func enqueue(_ event: WorkspaceEvent) {
        pendingEvents[event.workspaceID, default: []].append(event)
        schedulePendingEventsIfNeeded()
    }

    func schedulePendingEventsIfNeeded() {
        guard !pendingEvents.isEmpty,
              !isSynchronizing,
              !isApplyingWatcherEvents else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(75))
                guard !Task.isCancelled else { return }
                await self?.applyPendingEvents()
            } catch {}
        }
    }

    func applyPendingEvents() async {
        guard !isSynchronizing, !isApplyingWatcherEvents else { return }
        debounceTask = nil
        isApplyingWatcherEvents = true
        let events = coalescedWatcherEvents(
            pendingEvents.values.flatMap { $0 }
        )
        pendingEvents.removeAll()
        do {
            try await apply(events)
        } catch {
            // `apply` publishes the error for Stage 5 to present non-modally.
        }
        isApplyingWatcherEvents = false
        schedulePendingEventsIfNeeded()
    }

    func coalescedWatcherEvents(_ events: [WorkspaceEvent]) -> [WorkspaceEvent] {
        var coalesced: [WorkspaceEvent] = []
        for workspaceEvents in Dictionary(grouping: events, by: \.workspaceID).values {
            let ordered = workspaceEvents.sorted { $0.observedAt < $1.observedAt }
            if let terminal = ordered.last(where: {
                $0.kind == .accessLost || $0.kind == .error
            }) {
                coalesced.append(terminal)
            } else if let fullRescan = ordered.last(where: {
                $0.kind == .rootChanged || $0.kind == .rescanRequired
            }) {
                coalesced.append(fullRescan)
            } else {
                coalesced.append(contentsOf: ordered)
            }
        }
        return coalesced.sorted { $0.observedAt < $1.observedAt }
    }

    /// Parent and nested roots can describe one physical move as a parent
    /// `.moved` plus a nested `.deleted`. The two watcher batches need not
    /// arrive together, so overlapping-root deletions wait briefly for their
    /// move twin. Move-first delivery is remembered for the same reason.
    func reconcileBuffers(
        for events: [WorkspaceEvent],
        generation: UInt64,
        using eventReconciler: @escaping EventReconciler
    ) async throws {
        let now = Date()
        recentMoveSourceExpirations = recentMoveSourceExpirations.filter {
            $0.value > now
        }

        for event in events where event.kind == .moved {
            guard let path = event.previousFileURL?.standardizedFileURL.path else { continue }
            recentMoveSourceExpirations[path] = now.addingTimeInterval(
                Self.recentMoveRetention
            )
            deferredBufferDeletions.removeValue(forKey: path)?.task.cancel()
        }

        for event in events {
            guard let workspace = catalog.workspace(id: event.workspaceID) else { continue }
            if (event.kind == .rescanRequired || event.kind == .rootChanged),
               isOverlappingWorkspace(workspace) {
                deferBufferAudit(event, using: eventReconciler)
                continue
            }
            if event.kind == .deleted,
               let fileURL = event.fileURL,
               isCoveredByOverlappingWorkspaces(fileURL) {
                let path = fileURL.standardizedFileURL.path
                if recentMoveSourceExpirations[path] != nil {
                    continue
                }
                deferBufferDeletion(
                    event,
                    workspace: workspace,
                    path: path,
                    using: eventReconciler
                )
                continue
            }

            let movedDocument = event.kind == .moved
                ? event.previousFileURL.flatMap { registry.document(at: $0, in: workspace) }
                : nil
            try await eventReconciler(event, workspace)
            guard generation == mutationGeneration else { throw CancellationError() }
            if event.kind == .moved,
               let oldURL = event.previousFileURL,
               let newURL = event.fileURL,
               let movedDocument,
               movedDocument.fileURL?.standardizedFileURL == newURL.standardizedFileURL {
                retireAliases(for: movedDocument.id, at: oldURL)
            }
        }
    }

    func deferBufferDeletion(
        _ event: WorkspaceEvent,
        workspace: Workspace,
        path: String,
        using eventReconciler: @escaping EventReconciler
    ) {
        deferredBufferDeletions.removeValue(forKey: path)?.task.cancel()
        let token = UUID()
        let document = event.fileURL.flatMap { registry.document(at: $0, in: workspace) }
        let task = Task { @MainActor [weak self, weak document] in
            do {
                try await Task.sleep(for: Self.aliasMoveCorrelationDelay)
                guard !Task.isCancelled,
                      let self,
                      self.deferredBufferDeletions[path]?.token == token else { return }
                self.deferredBufferDeletions[path] = nil
                guard let currentWorkspace = self.catalog.workspace(id: event.workspaceID) else {
                    return
                }
                try await eventReconciler(event, currentWorkspace)
                if let document, document.fileURL == nil, let fileURL = event.fileURL {
                    self.retireAliases(for: document.id, at: fileURL)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.globalFailure = Failure(
                    workspaceID: event.workspaceID,
                    message: error.localizedDescription
                )
            }
        }
        deferredBufferDeletions[path] = (token, event.workspaceID, task)
    }

    func deferBufferAudit(
        _ event: WorkspaceEvent,
        using eventReconciler: @escaping EventReconciler
    ) {
        deferredBufferAudits.removeValue(forKey: event.workspaceID)?.task.cancel()
        let token = UUID()
        let candidates: [(document: Document, sourceURL: URL)] = catalog
            .workspace(id: event.workspaceID)
            .map { workspace in
                registry.openDocuments.compactMap { document in
                    guard let sourceURL = document.fileURL,
                          workspace.contains(sourceURL) else { return nil }
                    return (document, sourceURL)
                }
            } ?? []
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.aliasMoveCorrelationDelay)
                guard !Task.isCancelled,
                      let self,
                      self.deferredBufferAudits[event.workspaceID]?.token == token else { return }
                self.deferredBufferAudits[event.workspaceID] = nil
                guard let workspace = self.catalog.workspace(id: event.workspaceID) else { return }
                try await eventReconciler(event, workspace)
                for candidate in candidates where candidate.document.fileURL == nil {
                    self.retireAliases(
                        for: candidate.document.id,
                        at: candidate.sourceURL
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                self?.globalFailure = Failure(
                    workspaceID: event.workspaceID,
                    message: error.localizedDescription
                )
            }
        }
        deferredBufferAudits[event.workspaceID] = (token, task)
    }

    func isCoveredByOverlappingWorkspaces(_ fileURL: URL) -> Bool {
        catalog.workspaces.lazy.filter { $0.contains(fileURL) }.prefix(2).count == 2
    }

    func isOverlappingWorkspace(_ workspace: Workspace) -> Bool {
        catalog.workspaces.contains { candidate in
            candidate.id != workspace.id
                && (workspace.contains(candidate.rootURL) || candidate.contains(workspace.rootURL))
        }
    }

    func retireAliases(for documentID: DocumentID, at fileURL: URL) {
        for workspace in catalog.workspaces where workspace.contains(fileURL) {
            guard let locator = try? workspace.locator(for: fileURL) else { continue }
            registry.removeLocator(locator, for: documentID)
        }
    }

    func cancelDeferredDeletions(for workspaceID: WorkspaceID) {
        deferredBufferAudits.removeValue(forKey: workspaceID)?.task.cancel()
        let paths = deferredBufferDeletions.compactMap {
            $0.value.workspaceID == workspaceID ? $0.key : nil
        }
        for path in paths {
            deferredBufferDeletions.removeValue(forKey: path)?.task.cancel()
        }
    }

    func canonicalizing(
        _ source: AsyncThrowingStream<SearchBatch, Error>
    ) -> AsyncThrowingStream<SearchBatch, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    for try await batch in source {
                        try Task.checkCancellation()
                        continuation.yield(
                            SearchBatch(
                                results: batch.results.compactMap(canonicalize),
                                isFinal: batch.isFinal
                            )
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func canonicalize(_ result: WorkspaceSearchResult) -> WorkspaceSearchResult? {
        guard let workspace = catalog.workspace(id: result.workspaceID),
              let locator = try? DocumentLocator(
                workspaceID: result.workspaceID,
                relativePath: result.relativePath
              ),
              let url = try? workspace.fileURL(for: locator) else {
            return nil
        }
        let id = registry.documentID(
            for: .authorizedFile(at: url),
            locator: locator,
            preferredID: result.documentID,
            canonicalPath: url.standardizedFileURL.resolvingSymlinksInPath().path
        )
        return WorkspaceSearchResult(
            id: result.id,
            documentID: id,
            workspaceID: result.workspaceID,
            relativePath: result.relativePath,
            lineNumber: result.lineNumber,
            excerpt: result.excerpt,
            documentMatchRange: result.documentMatchRange,
            excerptMatchRange: result.excerptMatchRange,
            score: result.score,
            exclusionReason: result.exclusionReason
        )
    }
}
