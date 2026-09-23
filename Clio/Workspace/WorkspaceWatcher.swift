import Darwin
import CoreServices
import Foundation

/// One recursive FSEvents stream observes file-level writes without spending
/// one descriptor per file/directory. A root vnode source makes access loss
/// immediate, while snapshot diffs retain stable move semantics.
final class WorkspaceWatcher: WorkspaceEventSource, @unchecked Sendable {
    private final class CallbackBox {
        weak var watcher: WorkspaceWatcher?
        init(_ watcher: WorkspaceWatcher) { self.watcher = watcher }
    }

    private struct FileState: Equatable {
        let identity: PhysicalFileIdentity
        let url: URL
        let modificationDate: Date
        let byteCount: Int64
    }

    private enum SnapshotScanResult {
        case complete([PhysicalFileIdentity: FileState])
        case incomplete
        case rootUnavailable
    }

    private let workspaceID: WorkspaceID
    private let rootURL: URL
    private let eventRootPath: String
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let stream: AsyncStream<WorkspaceEvent>
    private let continuation: AsyncStream<WorkspaceEvent>.Continuation
    private let fullScanObserver: (@Sendable () -> Void)?
    private let rawEventObserver: (@Sendable (URL, FSEventStreamEventFlags) -> Void)?
    private var eventStream: FSEventStreamRef?
    private var eventStreamContext: UnsafeMutableRawPointer?
    private var rootSource: DispatchSourceFileSystemObject?
    private var snapshot: [PhysicalFileIdentity: FileState] = [:]
    private var snapshotKeyByPath: [String: PhysicalFileIdentity] = [:]
    private var pendingScan: DispatchWorkItem?

    init(
        workspaceID: WorkspaceID,
        rootURL: URL,
        fullScanObserver: (@Sendable () -> Void)? = nil,
        rawEventObserver: (@Sendable (URL, FSEventStreamEventFlags) -> Void)? = nil
    ) {
        self.workspaceID = workspaceID
        self.rootURL = rootURL.standardizedFileURL
        eventRootPath = Self.realPath(of: self.rootURL.path)
        self.fullScanObserver = fullScanObserver
        self.rawEventObserver = rawEventObserver
        queue = DispatchQueue(label: "olympus.clio.workspace-watcher", qos: .utility)
        var captured: AsyncStream<WorkspaceEvent>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(2_048)) {
            captured = $0
        }
        continuation = captured
        queue.setSpecific(key: queueKey, value: 1)
        // Start the O(1) event sources before publishing the watcher. The
        // potentially large initial scan remains asynchronous, but no edit or
        // deletion can fall into a gap between construction and monitoring.
        queue.sync {
            guard prepareMonitoring() else { return }
            queue.async { [weak self] in self?.loadInitialSnapshot() }
        }
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            shutdownOnQueue()
        } else {
            queue.sync { shutdownOnQueue() }
        }
    }

    private func shutdownOnQueue() {
        pendingScan?.cancel()
        pendingScan = nil
        rootSource?.cancel()
        rootSource = nil
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
            self.eventStream = nil
        }
        if let eventStreamContext {
            Unmanaged<CallbackBox>.fromOpaque(eventStreamContext).release()
            self.eventStreamContext = nil
        }
        continuation.finish()
    }

    func events() async -> AsyncStream<WorkspaceEvent> { stream }

    private func prepareMonitoring() -> Bool {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            emit(kind: .accessLost, fileURL: rootURL)
            continuation.finish()
            return false
        }
        guard startRootSource(), startEventStream() else {
            shutdownOnQueue()
            return false
        }
        return true
    }

    private func loadInitialSnapshot() {
        switch scanFiles() {
        case .complete(let initial):
            replaceSnapshot(with: initial)
        case .incomplete:
            emit(kind: .rescanRequired, fileURL: rootURL)
        case .rootUnavailable:
            emit(kind: .accessLost, fileURL: rootURL)
            shutdownOnQueue()
        }
    }

    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        pendingScan = work
        queue.asyncAfter(deadline: .now() + .milliseconds(40), execute: work)
    }

    private func rescan() {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            emit(kind: .accessLost, fileURL: rootURL)
            snapshot.removeAll()
            snapshotKeyByPath.removeAll()
            shutdownOnQueue()
            return
        }

        switch scanFiles() {
        case .complete(let next):
            if !emitChanges(from: snapshot, to: next) {
                emit(kind: .rescanRequired, fileURL: rootURL)
            }
            replaceSnapshot(with: next)
        case .incomplete:
            // A partial traversal cannot prove a deletion. Retain the last
            // complete snapshot and request a higher-level audit instead.
            emit(kind: .rescanRequired, fileURL: rootURL)
        case .rootUnavailable:
            emit(kind: .accessLost, fileURL: rootURL)
            shutdownOnQueue()
        }
    }

    private func emitChanges(
        from previous: [PhysicalFileIdentity: FileState],
        to next: [PhysicalFileIdentity: FileState]
    ) -> Bool {
        var didEmit = false
        var removed = previous.filter { next[$0.key] == nil }
        var inserted = next.filter { previous[$0.key] == nil }

        // Atomic replacement changes resource identity while retaining a path.
        // Pair those as modifications so open buffers are never marked deleted.
        let replacements = removed.compactMap { oldIdentity, old -> (PhysicalFileIdentity, PhysicalFileIdentity, FileState)? in
            guard let replacement = inserted.first(where: {
                $0.value.url.standardizedFileURL == old.url.standardizedFileURL
            }) else { return nil }
            return (oldIdentity, replacement.key, replacement.value)
        }
        for (oldIdentity, newIdentity, replacement) in replacements {
            emit(kind: .modified, fileURL: replacement.url)
            didEmit = true
            removed.removeValue(forKey: oldIdentity)
            inserted.removeValue(forKey: newIdentity)
        }

        for (identity, old) in previous {
            guard let current = next[identity] else { continue }
            if old.url.standardizedFileURL != current.url.standardizedFileURL {
                emit(
                    kind: .moved,
                    fileURL: current.url,
                    previousFileURL: old.url
                )
                didEmit = true
            } else if old.modificationDate != current.modificationDate
                        || old.byteCount != current.byteCount {
                emit(kind: .modified, fileURL: current.url)
                didEmit = true
            }
        }

        for state in removed.values.sorted(by: { $0.url.path < $1.url.path }) {
            emit(kind: .deleted, fileURL: state.url)
            didEmit = true
        }
        for state in inserted.values.sorted(by: { $0.url.path < $1.url.path }) {
            emit(kind: .created, fileURL: state.url)
            didEmit = true
        }
        return didEmit
    }

    private func scanFiles() -> SnapshotScanResult {
        fullScanObserver?()
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]
        guard rootIsReadableDirectory() else {
            return .rootUnavailable
        }
        var traversalWasIncomplete = false
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, error in
                if WorkspaceScanner.isRacedDisappearance(error) { return true }
                traversalWasIncomplete = true
                return false
            }
        ) else { return .rootUnavailable }

        var files: [PhysicalFileIdentity: FileState] = [:]
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch where WorkspaceScanner.isRacedDisappearance(error) {
                continue
            } catch {
                traversalWasIncomplete = true
                break
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true,
                  ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) else {
                continue
            }
            let identity = PhysicalFileIdentity.authorizedFile(at: url)
            files[identity] = FileState(
                identity: identity,
                url: url.standardizedFileURL,
                modificationDate: values.contentModificationDate ?? .distantPast,
                byteCount: Int64(values.fileSize ?? 0)
            )
        }
        guard rootIsReadableDirectory() else { return .rootUnavailable }
        return traversalWasIncomplete ? .incomplete : .complete(files)
    }

    private func rootIsReadableDirectory() -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(
            atPath: rootURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: rootURL.path)
    }

    private func replaceSnapshot(with next: [PhysicalFileIdentity: FileState]) {
        snapshot = next
        snapshotKeyByPath = Dictionary(
            uniqueKeysWithValues: next.map { ($0.value.url.standardizedFileURL.path, $0.key) }
        )
    }

    private func startRootSource() -> Bool {
        let descriptor = open(rootURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            emit(kind: .accessLost, fileURL: rootURL)
            return false
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.scheduleScan() }
        source.setCancelHandler { close(descriptor) }
        rootSource = source
        source.resume()
        return true
    }

    private func startEventStream() -> Bool {
        let retainedBox = Unmanaged.passRetained(CallbackBox(self)).toOpaque()
        eventStreamContext = retainedBox
        var context = FSEventStreamContext(
            version: 0,
            info: retainedBox,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            nil,
            Self.handleEvents,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        ) else {
            Unmanaged<CallbackBox>.fromOpaque(retainedBox).release()
            eventStreamContext = nil
            emit(kind: .error, fileURL: rootURL)
            return false
        }
        eventStream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
            emit(kind: .error, fileURL: rootURL)
            return false
        }
        return true
    }

    private static let handleEvents: FSEventStreamCallback = {
        _, context, count, eventPaths, eventFlags, _ in
        guard let context,
              let watcher = Unmanaged<CallbackBox>
            .fromOpaque(context)
            .takeUnretainedValue()
            .watcher else { return }
        let paths = Unmanaged<CFArray>
            .fromOpaque(eventPaths)
            .takeUnretainedValue() as NSArray
        for index in 0..<count {
            let flags = eventFlags[index]
            guard index < paths.count,
                  let path = paths[index] as? String else { continue }
            watcher.handleEvent(at: URL(fileURLWithPath: path), flags: flags)
        }
    }

    private static func realPath(of path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    private func normalizedEventURL(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        guard path == eventRootPath || path.hasPrefix(eventRootPath + "/") else {
            return url.standardizedFileURL
        }
        let suffix = String(path.dropFirst(eventRootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return suffix.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(suffix).standardizedFileURL
    }

    private static func isSupportedDocument(_ url: URL) -> Bool {
        ["md", "markdown", "txt"].contains(url.pathExtension.lowercased())
    }

    private func updateSnapshotEntry(at url: URL) {
        let standardized = url.standardizedFileURL
        // Read the identity with the other values. A second lookup can race a
        // rename and fall back to a path identity, which later turns the move
        // into a deletion plus a creation.
        guard let values = try? standardized.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .fileResourceIdentifierKey,
            .volumeIdentifierKey,
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true else { return }
        removeSnapshotEntry(at: standardized)
        let identity = PhysicalFileIdentity.authorizedFile(
            at: standardized,
            resourceValues: values
        )
        snapshot[identity] = FileState(
            identity: identity,
            url: standardized,
            modificationDate: values.contentModificationDate ?? .distantPast,
            byteCount: Int64(values.fileSize ?? 0)
        )
        snapshotKeyByPath[standardized.path] = identity
    }

    private func removeSnapshotEntry(at url: URL) {
        let path = url.standardizedFileURL.path
        guard let key = snapshotKeyByPath.removeValue(forKey: path) else { return }
        snapshot[key] = nil
    }

    private func handleEvent(at url: URL, flags: FSEventStreamEventFlags) {
        let url = normalizedEventURL(url)
        rawEventObserver?(url, flags)
        let requiresAudit = flags.containsAny(
            FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs),
            FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped),
            FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        )
        if requiresAudit {
            emit(kind: .rescanRequired, fileURL: rootURL)
            scheduleScan()
            return
        }
        if flags.containsAny(
            FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged),
            FSEventStreamEventFlags(kFSEventStreamEventFlagMount),
            FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount)
        ) {
            if FileManager.default.fileExists(atPath: rootURL.path) {
                emit(kind: .rootChanged, fileURL: rootURL)
                scheduleScan()
            } else {
                emit(kind: .accessLost, fileURL: rootURL)
                queue.async { [weak self] in self?.shutdownOnQueue() }
            }
            return
        }

        if url.lastPathComponent == ".gitignore" {
            emit(kind: .rescanRequired, fileURL: url)
            return
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
            if url.standardizedFileURL == rootURL,
               flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) == 0,
               flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) == 0 {
                return
            }
            if flags.containsAny(
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated),
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved),
                FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
            ) {
                scheduleScan()
            }
            return
        }
        guard Self.isSupportedDocument(url) else { return }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 {
            if FileManager.default.fileExists(atPath: url.path),
               snapshotKeyByPath[url.standardizedFileURL.path] != nil {
                // Atomic parity saves replace the inode at the same locator.
                // Rebind that single snapshot entry instead of scanning the
                // entire workspace for every keystroke-driven save.
                updateSnapshotEntry(at: url)
                emit(kind: .modified, fileURL: url)
            } else {
                scheduleScan()
            }
            return
        }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved) != 0 {
            if FileManager.default.fileExists(atPath: url.path),
               snapshotKeyByPath[url.standardizedFileURL.path] != nil {
                updateSnapshotEntry(at: url)
                emit(kind: .modified, fileURL: url)
            } else if snapshotKeyByPath[url.standardizedFileURL.path] != nil {
                removeSnapshotEntry(at: url)
                emit(kind: .deleted, fileURL: url)
            } else {
                // An incomplete initial/audit scan cannot establish that this
                // path was a tracked file. Reconcile through a full audit so
                // an unknown coalesced event never detaches a live buffer.
                emit(kind: .rescanRequired, fileURL: rootURL)
                scheduleScan()
            }
        } else if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 {
            let alreadyTracked = snapshotKeyByPath[url.standardizedFileURL.path] != nil
            updateSnapshotEntry(at: url)
            emit(kind: alreadyTracked ? .modified : .created, fileURL: url)
        } else {
            updateSnapshotEntry(at: url)
            emit(kind: .modified, fileURL: url)
        }
    }

    private func emit(
        kind: WorkspaceEventKind,
        fileURL: URL?,
        previousFileURL: URL? = nil
    ) {
        let event = WorkspaceEvent(
            workspaceID: workspaceID,
            kind: kind,
            fileURL: fileURL,
            previousFileURL: previousFileURL,
            origin: .unknown
        )
        guard case .dropped = continuation.yield(event),
              kind != .rescanRequired else { return }

        // Losing even one detailed event could skip external-edit
        // reconciliation. Keep a full-audit marker in the newest buffer slot;
        // repeated overflow keeps replacing older detail with another marker.
        _ = continuation.yield(
            WorkspaceEvent(
                workspaceID: workspaceID,
                kind: .rescanRequired,
                fileURL: rootURL,
                origin: .unknown
            )
        )
    }
}

private extension FSEventStreamEventFlags {
    func containsAny(_ flags: FSEventStreamEventFlags...) -> Bool {
        flags.contains { self & $0 != 0 }
    }
}
