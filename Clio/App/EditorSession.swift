import Foundation
import Observation

enum EditorOpeningMode: String, Codable, Hashable, Sendable {
    case mostRecent
    case newDocument
}

enum EditorSynchronizationError: LocalizedError {
    case editorMaterializationInProgress
    case invalidEditorMutation

    var errorDescription: String? {
        switch self {
        case .editorMaterializationInProgress:
            "Clio is still applying recent edits. Keep this window open; saving will continue as soon as the document catches up."
        case .invalidEditorMutation:
            "Clio couldn’t apply a queued editor change. The on-screen buffer was left open and no stale bytes were saved."
        }
    }
}

struct EditorWindowRequest: Codable, Hashable, Sendable {
    let id: UUID
    var openingMode: EditorOpeningMode
    var relativePath: String?
    var isFullScreen: Bool

    static func mostRecent() -> Self {
        Self(
            id: UUID(),
            openingMode: .mostRecent,
            relativePath: nil,
            isFullScreen: false
        )
    }

    static func newDocument() -> Self {
        Self(
            id: UUID(),
            openingMode: .newDocument,
            relativePath: nil,
            isFullScreen: false
        )
    }
}

@MainActor
@Observable
final class EditorSession: Identifiable {
    let id: UUID
    private(set) var openingMode: EditorOpeningMode

    private var detachedDraftText = ""
    private var detachedRevision: UInt64 = 0
    private(set) var relativePath = ""
    private(set) var document: Document?
    private(set) var errorMessage: String?
    private(set) var isResolvingConflict = false
    private(set) var pendingCollision: FileCollision?
    private(set) var wordCount = 0
    var isFullScreenEnabled: Bool

    @ObservationIgnored
    private var workspace: Workspace?

    @ObservationIgnored
    private var autosaver: Autosaver?

    @ObservationIgnored
    private var ownsAutosaver = false

    @ObservationIgnored
    private weak var registry: DocumentBufferRegistry?

    @ObservationIgnored
    private var conflictResolver: ConflictResolver?

    @ObservationIgnored
    private var documentMover: DocumentMover?

    @ObservationIgnored
    private var pendingRenameFilename: String?

    @ObservationIgnored
    private var autosaveErrorMonitor: Task<Void, Never>?

    @ObservationIgnored
    private var wordCountTask: Task<Void, Never>?

    @ObservationIgnored
    private var editorEditTask: Task<Void, Never>?

    @ObservationIgnored
    private var editorEditEpoch: UInt64 = 0

    @ObservationIgnored
    private var pendingEditorEdits: [MarkdownTextEdit] = []

    @ObservationIgnored
    private var pendingEditorRevisionAdvance: UInt64 = 0

    @ObservationIgnored
    private var saveAfterEditorEdits = false

    @ObservationIgnored
    private var editorSynchronizationFailure: EditorSynchronizationError?

    @ObservationIgnored
    private(set) var editorMaterializationCount = 0

    @ObservationIgnored
    private(set) var editorPublicationCount = 0

    @ObservationIgnored
    private var wordCountRequest: (documentID: DocumentID?, revision: UInt64)?

    @ObservationIgnored
    private var preferredRelativePath: String?

    @ObservationIgnored
    private var presentedErrorContext: PresentedErrorContext = .general

    init(
        id: UUID = UUID(),
        openingMode: EditorOpeningMode = .mostRecent,
        restoredRelativePath: String? = nil,
        startInFullScreen: Bool = false
    ) {
        self.id = id
        self.openingMode = openingMode
        isFullScreenEnabled = startInFullScreen
        preferredRelativePath = restoredRelativePath
    }

    var isReady: Bool {
        workspace != nil && document != nil
    }

    var fileURL: URL? {
        document?.fileURL
    }

    var hasPreferredDocument: Bool {
        preferredRelativePath != nil
    }

    var draftText: String {
        get { document?.text ?? detachedDraftText }
        set {
            invalidatePendingEditorEdits()
            if let document {
                document.replaceText(with: newValue)
                refreshWordCount(for: newValue, revision: document.revision)
            } else {
                guard newValue != detachedDraftText else { return }
                detachedDraftText = newValue
                detachedRevision &+= 1
                refreshWordCount(for: newValue, revision: detachedRevision)
            }
        }
    }

    var contentRevision: UInt64 {
        document?.revision ?? detachedRevision
    }

    var bufferGeneration: BufferGeneration {
        BufferGeneration(
            bufferID: document?.id.rawValue ?? id,
            revision: contentRevision
        )
    }

    /// True while NSTextView contains edits that are not yet reflected in the
    /// canonical `Document`, or when a captured mutation could not be applied.
    /// Synchronous lifecycle and destructive actions must refuse while this is
    /// true so the visible buffer remains recoverable.
    var hasUnsettledEditorEdits: Bool {
        hasPendingEditorEdits || editorSynchronizationFailure != nil
    }

    var activeConflict: DocumentConflict? { document?.conflict }
    var requiresExplicitRestore: Bool { document?.requiresExplicitRestore == true }
    var filename: String { document?.filename ?? Document.defaultFilename }

    var wordCountLabel: String {
        let count = wordCount
        return "\(count.formatted()) \(count == 1 ? "word" : "words")"
    }

    /// Refreshes status derived from document bytes after a clean outside
    /// reload. Normal editor changes schedule this directly; the view calls it
    /// when an observed document generation changes through another service.
    func refreshDerivedStateForCurrentRevision() {
        refreshWordCount(for: draftText, revision: contentRevision)
    }

    func activate(
        in workspace: Workspace,
        documentURLs: [URL],
        registry: DocumentBufferRegistry? = nil,
        conflictResolver: ConflictResolver? = nil,
        documentMover: DocumentMover? = nil
    ) {
        invalidatePendingEditorEdits()
        editorMaterializationCount = 0
        editorPublicationCount = 0
        autosaveErrorMonitor?.cancel()
        if ownsAutosaver { autosaver?.cancel() }
        self.registry?.unbind(self)
        self.registry = registry
        self.conflictResolver = conflictResolver
        self.documentMover = documentMover

        let initialDocument: (document: Document, warning: String?)
        if let preferredRelativePath,
           let preferredIndex = documentURLs.firstIndex(where: {
               workspace.relativePath(for: $0) == preferredRelativePath
           }) {
            var preferredFirstURLs = documentURLs
            let preferredURL = preferredFirstURLs.remove(at: preferredIndex)
            preferredFirstURLs.insert(preferredURL, at: 0)
            initialDocument = loadInitialDocument(
                from: preferredFirstURLs,
                in: workspace
            )
        } else {
            switch openingMode {
            case .newDocument:
                initialDocument = (Document(), nil)
            case .mostRecent:
                initialDocument = loadInitialDocument(
                    from: documentURLs,
                    in: workspace
                )
            }
        }

        self.workspace = workspace
        document = initialDocument.document
        registry?.register(initialDocument.document, in: workspace)
        registry?.bind(self, to: initialDocument.document)
        ownsAutosaver = registry == nil
        autosaver = registry?.autosaver(for: initialDocument.document, in: workspace)
            ?? Autosaver(workspace: workspace)
        detachedDraftText = ""
        detachedRevision = 0
        refreshRelativePath()
        refreshWordCount(
            for: initialDocument.document.text,
            revision: initialDocument.document.revision
        )
        errorMessage = initialDocument.warning
        presentedErrorContext = .general
    }

    func deactivate() {
        invalidatePendingEditorEdits()
        autosaveErrorMonitor?.cancel()
        wordCountTask?.cancel()
        wordCountRequest = nil
        if ownsAutosaver { autosaver?.cancel() }
        registry?.unbind(self)
        autosaver = nil
        ownsAutosaver = false
        registry = nil
        conflictResolver = nil
        documentMover = nil
        workspace = nil
        document = nil
        detachedDraftText = ""
        detachedRevision = 0
        wordCount = 0
        relativePath = ""
        errorMessage = nil
        pendingCollision = nil
        pendingRenameFilename = nil
        presentedErrorContext = .general
    }

    func editorTextDidChange(_ newText: String) {
        invalidatePendingEditorEdits()
        guard let document, let autosaver else { return }

        publishEditorText(newText, document: document, autosaver: autosaver)
    }

    /// Receives the UTF-16 mutation already supplied by NSTextView. Small
    /// documents update synchronously; large document materialization runs
    /// away from the main actor and publishes only if its base generation is
    /// still current.
    func editorTextDidChange(_ edit: MarkdownTextEdit) {
        guard editorSynchronizationFailure == nil,
              let document, let autosaver else { return }

        let source = document.text
        if source.utf8.count <= 256 * 1_024,
           editorEditTask == nil,
           pendingEditorEdits.isEmpty {
            guard let updated = MarkdownTextEditApplier.applying(edit, to: source) else {
                return
            }
            publishEditorText(updated, document: document, autosaver: autosaver)
            return
        }

        enqueueEditorEdit(edit)
        startEditorEditDrain(document: document)
    }

    /// Awaits the bounded editor-delta pipeline without forcing a full
    /// NSTextView snapshot onto the main actor. Async rename/move/export and
    /// restoration capture paths must cross this boundary before observing the
    /// canonical document. New edits arriving while it waits are included.
    func settlePendingEditorEdits() async throws {
        while true {
            if let editorSynchronizationFailure {
                throw editorSynchronizationFailure
            }

            if let editorEditTask {
                await editorEditTask.value
                continue
            }

            guard !pendingEditorEdits.isEmpty else { return }
            guard let document, autosaver != nil else {
                editorSynchronizationFailure = .invalidEditorMutation
                throw EditorSynchronizationError.invalidEditorMutation
            }
            startEditorEditDrain(document: document)
        }
    }

    /// Export/restoration integration point: the returned immutable snapshot
    /// includes every edit accepted by NSTextView before this call completes.
    func settledDocumentSnapshot() async throws -> Document.Snapshot? {
        guard let document else { return nil }
        if let registry {
            return try await registry.withSettledEditorEdits(for: document.id) {
                guard self.document === document else { return nil }
                return document.snapshot()
            }
        }

        while true {
            try await settlePendingEditorEdits()
            guard self.document === document else { return nil }
            guard !hasUnsettledEditorEdits else { continue }
            return document.snapshot()
        }
    }

    private func publishEditorText(
        _ newText: String,
        document: Document,
        autosaver: Autosaver,
        revisionAdvance: UInt64 = 1
    ) {

        document.replaceTextFromEditor(
            with: newText,
            revisionAdvance: revisionAdvance
        )
        refreshWordCount(for: newText, revision: document.revision)
        autosaver.documentDidChange(document)
        refreshRelativePath()

        if let error = autosaver.lastError {
            presentError(
                "Clio couldn’t save this document. Check that the workspace is available and writable, then choose Save again.",
                underlying: error,
                context: .save
            )
        } else if !autosaver.hasPendingSave {
            clearPresentedSaveError()
        }

        monitorAutosaveErrors(from: autosaver)
    }

    func saveNow() {
        if let editorSynchronizationFailure {
            errorMessage = editorSynchronizationFailure.localizedDescription
            presentedErrorContext = .save
            return
        }
        guard !hasPendingEditorEdits else {
            saveAfterEditorEdits = true
            return
        }
        do {
            guard let document, let autosaver else { return }
            try autosaver.flush(
                document,
                allowingDetachedRestore: document.requiresExplicitRestore
            )
            refreshRelativePath()
            clearPresentedSaveError()
        } catch {
            presentError(
                "Clio couldn’t save this document. Check that the workspace is available and writable, then try again.",
                underlying: error,
                context: .save
            )
        }
    }

    func flush() throws {
        if let editorSynchronizationFailure {
            throw editorSynchronizationFailure
        }
        guard !hasPendingEditorEdits else {
            throw EditorSynchronizationError.editorMaterializationInProgress
        }
        guard let document, let autosaver else { return }
        try autosaver.flush(document)
        refreshRelativePath()
        clearPresentedSaveError()
    }

    @discardableResult
    func flushForLifecycleEvent() -> Bool {
        if let editorSynchronizationFailure {
            errorMessage = editorSynchronizationFailure.localizedDescription
            presentedErrorContext = .save
            return false
        }
        guard !hasPendingEditorEdits else {
            errorMessage = EditorSynchronizationError
                .editorMaterializationInProgress.localizedDescription
            presentedErrorContext = .save
            return false
        }
        guard document?.isDirty == true else { return true }

        do {
            try flush()
            return true
        } catch {
            presentError(
                "Clio couldn’t save before the window became inactive. Keep it open, restore access to the workspace, and choose Save.",
                underlying: error,
                context: .save
            )
            return false
        }
    }

    func dismissError() {
        errorMessage = nil
        presentedErrorContext = .general
    }

    /// A most-recent request with no available file becomes a real blank
    /// document intent so later workspace activation cannot unexpectedly
    /// replace that canvas with an existing file.
    func resolveAsNewDocument() {
        guard fileURL == nil else { return }
        openingMode = .newDocument
        preferredRelativePath = nil
    }

    func resolveConflict(_ choice: ConflictChoice) {
        Task { @MainActor [weak self] in
            do {
                try await self?.resolveConflictNow(choice)
            } catch {
                self?.presentError(
                    "Clio couldn’t resolve the conflict. Both versions remain untouched.",
                    underlying: error
                )
            }
        }
    }

    func resolveConflictNow(_ choice: ConflictChoice) async throws {
        guard let document else { return }
        if let registry {
            try await registry.settlePendingEditorEdits(for: document.id)
        } else {
            try await settlePendingEditorEdits()
        }
        guard self.document === document else { return }
        guard let workspace, let conflictResolver else { return }
        isResolvingConflict = true
        defer { isResolvingConflict = false }
        _ = try await conflictResolver.resolve(
            choice,
            document: document,
            workspace: workspace,
            registry: registry
        )
        refreshWordCount(for: document.text, revision: document.revision)
        refreshRelativePath()
        clearPresentedSaveError()
    }

    func rename(
        to filename: String,
        collisionChoice: CollisionChoice? = nil,
        approvedCollision: FileCollision? = nil
    ) async throws -> FileMutationOutcome {
        guard let document else { return .cancelled }
        if let registry {
            try await registry.settlePendingEditorEdits(for: document.id)
        } else {
            try await settlePendingEditorEdits()
        }
        guard self.document === document,
              let workspace, let documentMover else {
            return .cancelled
        }
        let outcome = try await documentMover.move(
            document,
            from: workspace,
            to: workspace,
            preferredFilename: filename,
            collisionChoice: collisionChoice,
            approvedCollision: approvedCollision,
            registry: registry
        )
        if case .collision(let collision) = outcome {
            pendingCollision = collision
            pendingRenameFilename = filename
        } else {
            pendingCollision = nil
            pendingRenameFilename = nil
        }
        refreshRelativePath()
        return outcome
    }

    func resolveCollision(_ choice: CollisionChoice) {
        guard let filename = pendingRenameFilename,
              let approvedCollision = pendingCollision else { return }
        if choice == .cancel {
            pendingCollision = nil
            pendingRenameFilename = nil
            return
        }
        Task { @MainActor [weak self] in
            do {
                _ = try await self?.rename(
                    to: filename,
                    collisionChoice: choice,
                    approvedCollision: approvedCollision
                )
            } catch {
                self?.presentError(
                    "Clio couldn’t complete the file operation. No version was silently replaced.",
                    underlying: error
                )
            }
        }
    }

    func moveToTrash() throws {
        guard let document, let workspace, let documentMover else { return }
        if registry?.hasUnsettledEditorEdits(for: document.id)
            ?? hasUnsettledEditorEdits {
            throw EditorSynchronizationError.editorMaterializationInProgress
        }
        try documentMover.moveToTrash(
            document,
            workspace: workspace,
            registry: registry
        )
        refreshRelativePath()
    }

    func revealInFinder() {
        guard let document else { return }
        documentMover?.reveal(document)
    }

    func retargetDocument(to workspace: Workspace, autosaver: Autosaver) {
        // The registry retargets the existing autosave pipeline during a
        // cross-workspace move. Retain any accepted deltas; the drain publishes
        // through the current autosaver when background materialization ends.
        self.workspace = workspace
        self.autosaver = autosaver
        ownsAutosaver = false
        refreshRelativePath()
    }

    func rebindServices(
        conflictResolver: ConflictResolver,
        documentMover: DocumentMover
    ) {
        self.conflictResolver = conflictResolver
        self.documentMover = documentMover
    }
}

private extension EditorSession {
    enum PresentedErrorContext {
        case general
        case save
    }

    var hasPendingEditorEdits: Bool {
        editorEditTask != nil || !pendingEditorEdits.isEmpty
    }

    func enqueueEditorEdit(_ edit: MarkdownTextEdit) {
        pendingEditorRevisionAdvance &+= 1
        if let index = pendingEditorEdits.indices.last {
            let previous = pendingEditorEdits[index]
            let previousReplacementLength = (previous.replacement as NSString).length
            if previous.replacedRange.length == 0,
               edit.replacedRange.length == 0,
               edit.replacedRange.location
                    == previous.replacedRange.location + previousReplacementLength {
                pendingEditorEdits[index] = MarkdownTextEdit(
                    replacedRange: previous.replacedRange,
                    replacement: previous.replacement + edit.replacement
                )
                return
            }
        }
        pendingEditorEdits.append(edit)
    }

    func startEditorEditDrain(document: Document) {
        guard editorEditTask == nil else { return }

        let epoch = editorEditEpoch
        let documentID = document.id
        editorEditTask = Task { @MainActor [weak self, weak document] in
            do {
                // Gather key-repeat/burst input before paying for a large
                // immutable model snapshot.
                try await Task.sleep(for: .milliseconds(8))
            } catch {
                return
            }

            guard let self, let document else { return }
            while self.editorEditEpoch == epoch,
                  self.document === document,
                  self.autosaver != nil,
                  document.id == documentID,
                  !self.pendingEditorEdits.isEmpty {
                let edits = self.pendingEditorEdits
                let revisionAdvance = self.pendingEditorRevisionAdvance
                self.pendingEditorEdits.removeAll(keepingCapacity: true)
                self.pendingEditorRevisionAdvance = 0

                let baseRevision = document.revision
                let baseSource = document.text
                self.editorMaterializationCount += 1
                let worker = Task.detached(priority: .userInitiated) {
                    MarkdownTextEditApplier.applying(edits, to: baseSource)
                }
                guard let updated = await worker.value,
                      !Task.isCancelled,
                      self.editorEditEpoch == epoch,
                      self.document === document,
                      let autosaver = self.autosaver,
                      document.revision == baseRevision else {
                    if self.editorEditEpoch == epoch {
                        self.pendingEditorEdits.removeAll(keepingCapacity: true)
                        self.pendingEditorRevisionAdvance = 0
                        self.editorEditTask = nil
                        self.editorSynchronizationFailure = .invalidEditorMutation
                        self.errorMessage = self.editorSynchronizationFailure?
                            .localizedDescription
                        self.presentedErrorContext = .save
                    }
                    return
                }

                self.editorPublicationCount += 1
                self.publishEditorText(
                    updated,
                    document: document,
                    autosaver: autosaver,
                    revisionAdvance: revisionAdvance
                )
                await Task.yield()
            }

            guard self.editorEditEpoch == epoch else { return }
            self.editorEditTask = nil
            if self.saveAfterEditorEdits {
                self.saveAfterEditorEdits = false
                self.saveNow()
            }
        }
    }

    func invalidatePendingEditorEdits() {
        editorEditEpoch &+= 1
        editorEditTask?.cancel()
        editorEditTask = nil
        pendingEditorEdits.removeAll(keepingCapacity: true)
        pendingEditorRevisionAdvance = 0
        saveAfterEditorEdits = false
        editorSynchronizationFailure = nil
    }

    func loadInitialDocument(
        from documentURLs: [URL],
        in workspace: Workspace
    ) -> (document: Document, warning: String?) {
        var failures: [(url: URL, error: Error)] = []

        for documentURL in documentURLs {
            do {
                let document = try registry?.open(documentURL, in: workspace)
                    ?? workspace.loadDocument(at: documentURL)
                return (document, unreadableDocumentWarning(failures))
            } catch {
                failures.append((documentURL, error))
            }
        }

        return (Document(), unreadableDocumentWarning(failures))
    }

    func unreadableDocumentWarning(
        _ failures: [(url: URL, error: Error)]
    ) -> String? {
        guard let firstFailure = failures.first else { return nil }

        let fileLabel = failures.count == 1 ? "file" : "files"
        let action = failures.count == 1 ? "it was" : "they were"
        return "Clio skipped \(failures.count) \(fileLabel) it couldn’t read; \(action) left unchanged.\n\n\(firstFailure.url.lastPathComponent): \(firstFailure.error.localizedDescription)"
    }

    func refreshRelativePath() {
        guard let workspace, let fileURL = document?.fileURL else {
            relativePath = ""
            return
        }
        relativePath = workspace.relativePath(for: fileURL)
        preferredRelativePath = relativePath
    }

    func monitorAutosaveErrors(from autosaver: Autosaver) {
        autosaveErrorMonitor?.cancel()
        guard autosaver.hasPendingSave else { return }

        autosaveErrorMonitor = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }

            guard let self, self.autosaver === autosaver else { return }

            if let error = autosaver.lastError {
                self.presentError(
                    "Clio couldn’t autosave this document. Check that the workspace is available and writable, then choose Save.",
                    underlying: error,
                    context: .save
                )
            } else if !autosaver.hasPendingSave {
                self.clearPresentedSaveError()
            }
        }
    }

    func refreshWordCount(for source: String, revision: UInt64) {
        let request = (documentID: document?.id, revision: revision)
        guard wordCountRequest?.documentID != request.documentID
                || wordCountRequest?.revision != request.revision else { return }
        wordCountRequest = request
        wordCountTask?.cancel()

        if source.utf8.count <= 256 * 1_024 {
            wordCount = Self.countWords(in: source)
            return
        }

        wordCountTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            let worker = Task.detached(priority: .utility) {
                Self.countWords(in: source, checkingCancellation: true)
            }
            let count = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self,
                  self.wordCountRequest?.documentID == request.documentID,
                  self.wordCountRequest?.revision == request.revision else { return }
            self.wordCount = count
        }
    }

    nonisolated static func countWords(
        in source: String,
        checkingCancellation: Bool = false
    ) -> Int {
        var count = 0
        var isInsideWord = false
        var scanned = 0
        for scalar in source.unicodeScalars {
            if scalar.properties.isWhitespace {
                isInsideWord = false
            } else if !isInsideWord {
                count += 1
                isInsideWord = true
            }
            scanned += scalar.utf8.count
            if checkingCancellation, scanned >= 65_536 {
                if Task.isCancelled { return count }
                scanned = 0
            }
        }
        return count
    }

    func presentError(
        _ guidance: String,
        underlying error: Error,
        context: PresentedErrorContext = .general
    ) {
        presentedErrorContext = context
        errorMessage = "\(guidance)\n\n\(error.localizedDescription)"
    }

    func clearPresentedSaveError() {
        guard presentedErrorContext == .save else { return }
        errorMessage = nil
        presentedErrorContext = .general
    }
}
