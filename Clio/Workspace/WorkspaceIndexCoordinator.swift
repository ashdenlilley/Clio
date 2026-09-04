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
    @ObservationIgnored private var mutationGeneration: UInt64 = 0
    @ObservationIgnored private var watcherSources: [WorkspaceID: any WorkspaceEventSource] = [:]
    @ObservationIgnored private var watcherTasks: [WorkspaceID: Task<Void, Never>] = [:]
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var isApplyingWatcherEvents = false
    @ObservationIgnored private var pendingEvents: [WorkspaceID: [WorkspaceEvent]] = [:]

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
    }

    /// Reconciles watcher ownership and rebuilds both tree and index from the
    /// current global catalog. Call after authorization/settings changes.
    func synchronize(policy: DiscoveryPolicy) async throws {
        mutationGeneration &+= 1
        let generation = mutationGeneration
        self.policy = policy
        reconcileWatchers()
        let descriptors = catalog.descriptors
        var snapshots = treeSnapshots.filter { id, _ in
            descriptors.contains { $0.id == id }
        }

        for descriptor in descriptors {
            do {
                let scanned = try await scanner.scan(
                    workspace: descriptor,
                    policy: policy
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
            for event in events {
                guard let workspace = catalog.workspace(id: event.workspaceID) else { continue }
                try await eventReconciler(event, workspace)
                guard generation == mutationGeneration else { throw CancellationError() }
            }
        }
        let accessFailures = events.filter {
            $0.kind == .accessLost || $0.kind == .error
        }
        let inaccessibleWorkspaceIDs = Set(accessFailures.map(\.workspaceID))
        for event in accessFailures {
            watcherTasks.removeValue(forKey: event.workspaceID)?.cancel()
            watcherSources[event.workspaceID] = nil
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
                    policy: policy
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
        watcherTasks.values.forEach { $0.cancel() }
        debounceTask?.cancel()
        watcherTasks.removeAll()
        debounceTask = nil
        watcherSources.removeAll()
        pendingEvents.removeAll()
    }
}

private extension WorkspaceIndexCoordinator {
    func reconcileWatchers() {
        let descriptors = catalog.descriptors
        let desiredIDs = Set(descriptors.map(\.id))
        for id in watcherTasks.keys where !desiredIDs.contains(id) {
            watcherTasks.removeValue(forKey: id)?.cancel()
            watcherSources[id] = nil
            pendingEvents[id] = nil
        }

        for descriptor in descriptors where watcherTasks[descriptor.id] == nil {
            let source = watcherFactory(descriptor)
            watcherSources[descriptor.id] = source
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
        guard !isApplyingWatcherEvents else { return }
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
        guard !isApplyingWatcherEvents else { return }
        debounceTask = nil
        isApplyingWatcherEvents = true
        let events = pendingEvents.values
            .flatMap { $0 }
            .sorted { $0.observedAt < $1.observedAt }
        pendingEvents.removeAll()
        do {
            try await apply(events)
        } catch {
            // `apply` publishes the error for Stage 5 to present non-modally.
        }
        isApplyingWatcherEvents = false
        if !pendingEvents.isEmpty {
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(75))
                guard !Task.isCancelled else { return }
                await self?.applyPendingEvents()
            }
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
