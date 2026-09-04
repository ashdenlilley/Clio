import Foundation

@MainActor
final class Autosaver {
    nonisolated static let defaultDelay: Duration = .milliseconds(400)

    let delay: Duration

    private(set) var lastError: Error?

    var hasPendingSave: Bool {
        pendingDocument != nil
    }

    private let workspace: Workspace
    private weak var registry: DocumentBufferRegistry?
    private var pendingDocument: Document?
    private var debounceTask: Task<Void, Never>?
    private var generation: UInt64 = 0

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

        guard !document.isAutosavePaused else {
            pendingDocument = nil
            debounceTask?.cancel()
            debounceTask = nil
            return
        }

        pendingDocument = document
        lastError = nil
        generation &+= 1
        debounceTask?.cancel()

        if !document.isBackedByFile, !document.text.isEmpty {
            do {
                try savePendingDocument()
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
    func flush(_ document: Document? = nil) throws -> URL? {
        if let document, document.isDirty {
            pendingDocument = document
        }

        generation &+= 1
        debounceTask?.cancel()
        debounceTask = nil

        do {
            let url = try savePendingDocument()
            lastError = nil
            return url
        } catch {
            lastError = error
            throw error
        }
    }

    func cancel() {
        generation &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        pendingDocument = nil
    }
}

private extension Autosaver {
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

            do {
                try self.savePendingDocument()
                self.lastError = nil
            } catch {
                self.lastError = error
            }
        }
    }

    @discardableResult
    func savePendingDocument() throws -> URL? {
        guard let document = pendingDocument else { return nil }

        let url: URL?
        do {
            url = try workspace.save(document)
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
            debounceTask = nil
        }

        return url
    }
}
