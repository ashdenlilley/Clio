import Darwin
import Foundation

/// Recursive vnode watcher. It watches each real directory and converts a
/// metadata rescan into stable create/modify/move/delete events without ever
/// following symlinks.
final class WorkspaceWatcher: WorkspaceEventSource, @unchecked Sendable {
    private struct FileState: Equatable {
        let identity: PhysicalFileIdentity
        let url: URL
        let modificationDate: Date
        let byteCount: Int64
    }

    private let workspaceID: WorkspaceID
    private let rootURL: URL
    private let queue: DispatchQueue
    private let stream: AsyncStream<WorkspaceEvent>
    private let continuation: AsyncStream<WorkspaceEvent>.Continuation
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var snapshot: [PhysicalFileIdentity: FileState] = [:]
    private var pendingScan: DispatchWorkItem?

    init(workspaceID: WorkspaceID, rootURL: URL) {
        self.workspaceID = workspaceID
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        queue = DispatchQueue(label: "olympus.clio.workspace-watcher", qos: .utility)
        var captured: AsyncStream<WorkspaceEvent>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(2_048)) {
            captured = $0
        }
        continuation = captured
        queue.async { [weak self] in self?.start() }
    }

    deinit {
        pendingScan?.cancel()
        sources.values.forEach { $0.cancel() }
        continuation.finish()
    }

    func events() async -> AsyncStream<WorkspaceEvent> { stream }

    private func start() {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            emit(kind: .accessLost, fileURL: rootURL)
            continuation.finish()
            return
        }
        snapshot = scanFiles()
        refreshDirectorySources()
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
            sources.values.forEach { $0.cancel() }
            sources.removeAll()
            snapshot.removeAll()
            return
        }

        let next = scanFiles()
        if !emitChanges(from: snapshot, to: next) {
            emit(kind: .rescanRequired, fileURL: rootURL)
        }
        snapshot = next
        refreshDirectorySources()
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

    private func scanFiles() -> [PhysicalFileIdentity: FileState] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [:] }

        var files: [PhysicalFileIdentity: FileState] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
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
        return files
    }

    private func refreshDirectorySources() {
        let currentDirectories = Set(directoryURLs().map(\.path))
        for path in sources.keys where !currentDirectories.contains(path) {
            sources.removeValue(forKey: path)?.cancel()
        }
        for path in currentDirectories where sources[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self] in self?.scheduleScan() }
            source.setCancelHandler { close(descriptor) }
            sources[path] = source
            source.resume()
        }
    }

    private func directoryURLs() -> [URL] {
        var directories = [rootURL]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return directories }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
            } else if values.isDirectory == true {
                directories.append(url.standardizedFileURL)
            }
        }
        return directories
    }

    private func emit(
        kind: WorkspaceEventKind,
        fileURL: URL?,
        previousFileURL: URL? = nil
    ) {
        continuation.yield(
            WorkspaceEvent(
                workspaceID: workspaceID,
                kind: kind,
                fileURL: fileURL,
                previousFileURL: previousFileURL,
                origin: .unknown
            )
        )
    }
}
