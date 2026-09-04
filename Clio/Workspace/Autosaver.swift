import Foundation

@MainActor
final class Autosaver {
    enum SaveError: LocalizedError {
        case fileOperationInProgress
        case backgroundSaveInProgress

        var errorDescription: String? {
            switch self {
            case .fileOperationInProgress:
                "Wait for the current file operation to finish, then save again."
            case .backgroundSaveInProgress:
                "Clio is still saving this large document. Keep it open until the save finishes."
            }
        }
    }

    nonisolated static let defaultDelay: Duration = .milliseconds(400)

    let delay: Duration

    private(set) var lastError: Error?
    private(set) var backgroundSaveAttemptCount = 0

    var hasPendingSave: Bool {
        pendingDocument != nil || debounceTask != nil || saveTask != nil
    }

    var hasActiveFileIO: Bool { saveTask != nil }

    private var workspace: Workspace
    private weak var registry: DocumentBufferRegistry?
    private var pendingDocument: Document?
    private var pendingAllowsDetachedRestore = false
    private var debounceTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var lastSavedURL: URL?
    private var generation: UInt64 = 0
    private var suspensionDepth = 0

    private var isSuspended: Bool { suspensionDepth > 0 }

    init(
        workspace: Workspace,
        registry: DocumentBufferRegistry? = nil,
        delay: Duration = Autosaver.defaultDelay
    ) {
        self.workspace = workspace
        self.registry = registry
        self.delay = delay
    }

    deinit {
        debounceTask?.cancel()
    }

    /// Records an editor mutation. The first non-empty edit of an unbacked
    /// document is materialized immediately; normal revisions are debounced.
    func documentDidChange(_ document: Document) {
        guard document.isDirty else { return }
        workspace.scheduleCrashRecovery(for: document)

        if isSuspended {
            pendingDocument = document
            lastError = nil
            return
        }

        // Deleted and trashed files remain detached until a deliberate
        // Restore/Save As. Normal typing must never resurrect the old path.
        guard !document.requiresExplicitRestore else {
            cancel()
            return
        }

        guard !document.isAutosavePaused else {
            pendingDocument = nil
            debounceTask?.cancel()
            debounceTask = nil
            return
        }

        pendingDocument = document
        pendingAllowsDetachedRestore = false
        lastError = nil
        generation &+= 1
        debounceTask?.cancel()

        if saveTask != nil { return }

        if !document.isBackedByFile, document.utf8ByteCount > 0 {
            if document.utf8ByteCount > Self.maximumSynchronousByteCount {
                startBackgroundSave()
                return
            }
            do {
                try savePendingDocumentSynchronously()
                return
            } catch {
                lastError = error
            }
        }

        armDebounce(for: generation)
    }

    /// Writes the pending revision now, for Command-S and lifecycle flushes.
    /// Supplying a document also supports a flush before it has been scheduled.
    @discardableResult
    func flush(
        _ document: Document? = nil,
        allowingDetachedRestore: Bool = false
    ) throws -> URL? {
        if let document, document.isDirty {
            pendingDocument = document
            pendingAllowsDetachedRestore = allowingDetachedRestore
        }

        guard !isSuspended else {
            throw SaveError.fileOperationInProgress
        }

        generation &+= 1
        debounceTask?.cancel()
        debounceTask = nil

        guard saveTask == nil,
              (pendingDocument?.utf8ByteCount ?? 0) <= Self.maximumSynchronousByteCount else {
            startBackgroundSave()
            throw SaveError.backgroundSaveInProgress
        }

        do {
            let url = try savePendingDocumentSynchronously(
                allowingDetachedRestore: allowingDetachedRestore
            )
            lastError = nil
            return url
        } catch {
            lastError = error
            throw error
        }
    }

    /// Command-S and async file workflows await the one serial durable-write
    /// pipeline. Rapid edits are coalesced into the latest pending generation;
    /// at most one 50 MiB snapshot is being materialized or written at a time.
    @discardableResult
    func flushAsync(
        _ document: Document? = nil,
        allowingDetachedRestore: Bool = false
    ) async throws -> URL? {
        if let document, document.isDirty {
            pendingDocument = document
            pendingAllowsDetachedRestore = allowingDetachedRestore
        }
        guard !isSuspended else { throw SaveError.fileOperationInProgress }

        generation &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        lastError = nil
        startBackgroundSave()

        while let task = saveTask {
            await task.value
        }
        if let lastError { throw lastError }
        if pendingDocument != nil { throw SaveError.fileOperationInProgress }
        return lastSavedURL ?? document?.fileURL
    }

    /// File moves and watcher reconciliation suspend new autosaves, then await
    /// the already-started atomic write before inspecting or retargeting paths.
    func settlePendingFileIO() async {
        while let task = saveTask {
            await task.value
        }
    }

    func cancel() {
        generation &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingDocument = nil
        pendingAllowsDetachedRestore = false
    }

    func retarget(to workspace: Workspace) {
        self.workspace = workspace
    }

    func suspendForFileOperation() {
        suspensionDepth += 1
        guard suspensionDepth == 1 else { return }
        generation &+= 1
        debounceTask?.cancel()
        debounceTask = nil
    }

    func resumeAfterFileOperation() {
        guard suspensionDepth > 0 else { return }
        suspensionDepth -= 1
        guard suspensionDepth == 0 else { return }
        guard let pendingDocument else { return }
        guard pendingDocument.isDirty else {
            self.pendingDocument = nil
            lastError = nil
            return
        }
        documentDidChange(pendingDocument)
    }
}

private extension Autosaver {
    static var maximumSynchronousByteCount: Int {
        Document.maximumSynchronousByteCount
    }

    func armDebounce(for scheduledGeneration: UInt64) {
        let delay = delay
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard let self, self.generation == scheduledGeneration else {
                return
            }

            self.debounceTask = nil
            self.startBackgroundSave()
        }
    }

    @discardableResult
    func savePendingDocumentSynchronously(
        allowingDetachedRestore: Bool = false
    ) throws -> URL? {
        guard let document = pendingDocument else { return nil }

        let url: URL?
        do {
            url = try workspace.save(
                document,
                allowingDetachedRestore: allowingDetachedRestore
            )
        } catch let error as Workspace.WorkspaceError {
            if case .externalConflict = error {
                pendingDocument = nil
                debounceTask = nil
            } else if case .documentDeleted = error {
                pendingDocument = nil
                debounceTask = nil
                if let locator = document.previousLocator {
                    registry?.detach(document.id, from: locator)
                }
            }
            throw error
        }

        if url != nil {
            registry?.updateAliases(for: document, in: workspace)
        }

        if pendingDocument === document {
            pendingDocument = nil
            pendingAllowsDetachedRestore = false
            debounceTask = nil
        }

        return url
    }

    func startBackgroundSave() {
        guard saveTask == nil,
              !isSuspended,
              pendingDocument != nil else { return }
        debounceTask?.cancel()
        debounceTask = nil
        saveTask = Task { @MainActor [weak self] in
            await self?.drainBackgroundSaves()
        }
    }

    func drainBackgroundSaves() async {
        defer {
            saveTask = nil
            if !isSuspended, pendingDocument != nil, lastError == nil {
                armDebounce(for: generation)
            }
        }

        while !isSuspended, let document = pendingDocument {
            let allowingDetachedRestore = pendingAllowsDetachedRestore
            pendingDocument = nil
            pendingAllowsDetachedRestore = false
            backgroundSaveAttemptCount += 1

            do {
                let url = try await workspace.saveInBackground(
                    document,
                    allowingDetachedRestore: allowingDetachedRestore
                )
                lastSavedURL = url
                lastError = nil
                if url != nil {
                    registry?.updateAliases(for: document, in: workspace)
                }
            } catch let error as Workspace.WorkspaceError {
                lastError = error
                switch error {
                case .externalConflict:
                    pendingDocument = nil
                case .documentDeleted:
                    pendingDocument = nil
                    if let locator = document.previousLocator {
                        registry?.detach(document.id, from: locator)
                    }
                default:
                    if document.isDirty { pendingDocument = document }
                }
                return
            } catch {
                lastError = error
                if document.isDirty { pendingDocument = document }
                return
            }

            await Task.yield()
        }
    }
}
