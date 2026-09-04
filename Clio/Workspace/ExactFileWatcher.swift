import Darwin
import Foundation

/// Watches one Powerbox-authorized file without enumerating or opening its
/// unauthorized siblings. Atomic replacement reopens the path with O_NOFOLLOW
/// before emitting a change, so a replacement symlink is never traversed.
final class ExactFileWatcher: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case changed
        case deleted
        case accessLost
    }

    private let fileURL: URL
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var source: DispatchSourceFileSystemObject?
    private var inspection: DispatchWorkItem?
    private var isFinished = false

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
        queue = DispatchQueue(label: "olympus.clio.exact-file-watcher", qos: .utility)
        var captured: AsyncStream<Event>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        continuation = captured
        queue.setSpecific(key: queueKey, value: 1)
        queue.sync {
            if !installSource() {
                emitTerminal(pathExistsWithoutFollowingLinks() ? .accessLost : .deleted)
            } else {
                continuation.yield(.changed)
            }
        }
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            shutdownOnQueue()
        } else {
            queue.sync { shutdownOnQueue() }
        }
    }

    func events() -> AsyncStream<Event> { stream }

    func cancel() {
        queue.async { [weak self] in self?.shutdownOnQueue() }
    }

    private func installSource() -> Bool {
        guard isRegularFileWithoutFollowingLinks() else { return false }
        let descriptor = open(fileURL.path, O_EVTONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            return false
        }
        let next = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: queue
        )
        next.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            self.handle(source.data)
        }
        next.setCancelHandler { close(descriptor) }
        source = next
        next.resume()
        return true
    }

    private func handle(_ flags: DispatchSource.FileSystemEvent) {
        guard !isFinished else { return }
        if flags.contains(.revoke) {
            emitTerminal(.accessLost)
            return
        }
        if flags.contains(.delete) || flags.contains(.rename) {
            source?.cancel()
            source = nil
            scheduleReplacementInspection()
            return
        }
        continuation.yield(.changed)
    }

    private func scheduleReplacementInspection() {
        inspection?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isFinished else { return }
            if self.installSource() {
                self.continuation.yield(.changed)
            } else {
                self.emitTerminal(
                    self.pathExistsWithoutFollowingLinks() ? .accessLost : .deleted
                )
            }
        }
        inspection = work
        queue.asyncAfter(deadline: .now() + .milliseconds(80), execute: work)
    }

    private func pathExistsWithoutFollowingLinks() -> Bool {
        var status = stat()
        return lstat(fileURL.path, &status) == 0
    }

    private func isRegularFileWithoutFollowingLinks() -> Bool {
        var status = stat()
        return lstat(fileURL.path, &status) == 0
            && status.st_mode & S_IFMT == S_IFREG
    }

    private func emitTerminal(_ event: Event) {
        guard !isFinished else { return }
        isFinished = true
        continuation.yield(event)
        shutdownOnQueue()
    }

    private func shutdownOnQueue() {
        inspection?.cancel()
        inspection = nil
        source?.cancel()
        source = nil
        guard !isFinished else {
            continuation.finish()
            return
        }
        isFinished = true
        continuation.finish()
    }
}
