import AppKit
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
    var restoration: EditorWindowRestorationState?

    static func mostRecent() -> Self {
        Self(
            id: UUID(),
            openingMode: .mostRecent,
            relativePath: nil,
            isFullScreen: false,
            restoration: nil
        )
    }

    static func newDocument() -> Self {
        Self(
            id: UUID(),
            openingMode: .newDocument,
            relativePath: nil,
            isFullScreen: false,
            restoration: nil
        )
    }
}

@MainActor
@Observable
final class EditorSession: Identifiable {
    @ObservationIgnored weak var mcpTextView: NSTextView?
    enum SessionError: LocalizedError {
        case parentFolderAuthorizationRequired

        var errorDescription: String? {
            "Authorize this document’s parent folder before closing Clio."
        }
    }

    let id: UUID
    private(set) var openingMode: EditorOpeningMode

    private var detachedDraftText = ""
    private var detachedRevision: UInt64 = 0
    private(set) var relativePath = ""
    private(set) var workspaceID: WorkspaceID?
    private(set) var document: Document?
    private(set) var errorMessage: String?
    private(set) var isRestorationUnresolved = false
    private(set) var isResolvingConflict = false
    private(set) var pendingCollision: FileCollision?
    private(set) var wordCount = 0
    var isFullScreenEnabled: Bool
    var viewportState: EditorViewportState

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
    private var activationEpoch: UInt64 = 0

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
    private var preferredWorkspaceID: WorkspaceID?

    @ObservationIgnored
    private var preferredFilenameForRestoration: String

    @ObservationIgnored
    private var restoredDocumentID: DocumentID?

    @ObservationIgnored
    private var externalFileLease: SecurityScopedFileLease?

    @ObservationIgnored
    private var exactFileWatcher: ExactFileWatcher?

    @ObservationIgnored
    private var exactFileWatcherTask: Task<Void, Never>?

    @ObservationIgnored
    private var preferredExternalFileBookmark: Data?

    @ObservationIgnored
    private var preferredExternalFileURL: URL?

    @ObservationIgnored
    private var crashRecoveryJournal: CrashRecoveryJournal?

    @ObservationIgnored
    private var presentedErrorContext: PresentedErrorContext = .general

    init(
        id: UUID = UUID(),
        openingMode: EditorOpeningMode = .mostRecent,
        restoredRelativePath: String? = nil,
        restoredLocator: DocumentLocator? = nil,
        restoredViewport: EditorViewportState = .zero,
        restoredPreferredFilename: String = Document.defaultFilename,
        restoredDocumentID: DocumentID? = nil,
        restoredExternalFileBookmark: Data? = nil,
        restoredExternalFileURL: URL? = nil,
        startInFullScreen: Bool = false
    ) {
        self.id = id
        self.openingMode = openingMode
        isFullScreenEnabled = startInFullScreen
        viewportState = restoredViewport
        preferredFilenameForRestoration = restoredPreferredFilename
        self.restoredDocumentID = restoredDocumentID
        preferredWorkspaceID = restoredLocator?.workspaceID
        preferredRelativePath = restoredLocator?.relativePath ?? restoredRelativePath
        preferredExternalFileBookmark = restoredExternalFileBookmark
        preferredExternalFileURL = restoredExternalFileURL?.standardizedFileURL
    }

    var isReady: Bool {
        document != nil
    }

    var fileURL: URL? {
        document?.fileURL
    }

    var hasPreferredDocument: Bool {
        preferredRelativePath != nil || preferredExternalFileBookmark != nil
    }

    func shouldHydrateInitialDocumentInBackground(
        from documentURLs: [URL],
        in workspace: Workspace
    ) -> Bool {
        guard let candidate = orderedInitialURLs(documentURLs, in: workspace).first,
              let byteCount = try? DocumentRevisionReader.byteCount(at: candidate) else {
            return false
        }
        return byteCount > Int64(Document.maximumSynchronousByteCount)
    }

    var draftText: String {
        get { document?.text ?? detachedDraftText }
        set {
            invalidatePendingEditorEdits()
            if let document {
                document.replaceText(with: newValue)
                refreshWordCount(
                    for: newValue,
                    revision: document.revision,
                    utf8ByteCount: document.utf8ByteCount
                )
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
    var requiresExplicitRestore: Bool {
        isRestorationUnresolved || document?.requiresExplicitRestore == true
    }
    var canRestoreAtPreviousLocation: Bool {
        !isRestorationUnresolved && document?.previousLocator != nil
    }
    var filename: String { document?.filename ?? Document.defaultFilename }

    var restoredWorkspaceID: WorkspaceID? {
        preferredWorkspaceID
    }

    var restoredRelativePath: String? {
        preferredRelativePath
    }

    var restoredExternalFileBookmark: Data? { preferredExternalFileBookmark }
    var restoredExternalFileURL: URL? { preferredExternalFileURL }
    var hasRetainedExternalFileAccess: Bool { externalFileLease != nil }

    func useCrashRecoveryJournal(_ journal: CrashRecoveryJournal) {
        crashRecoveryJournal = journal
    }

    var documentID: DocumentID {
        document?.id ?? restoredDocumentID ?? DocumentID(rawValue: id)
    }

    var locator: DocumentLocator? {
        let resolvedWorkspaceID = workspaceID ?? preferredWorkspaceID
        let resolvedRelativePath = relativePath.isEmpty
            ? preferredRelativePath
            : relativePath
        guard let resolvedWorkspaceID, let resolvedRelativePath,
              !resolvedRelativePath.isEmpty else { return nil }
        return try? DocumentLocator(
            workspaceID: resolvedWorkspaceID,
            relativePath: resolvedRelativePath
        )
    }

    var displayName: String {
        document?.filename ?? preferredFilenameForRestoration
    }
    var wordCountLabel: String {
        let count = wordCount
        return "\(count.formatted()) \(count == 1 ? "word" : "words")"
    }

    /// Refreshes status derived from document bytes after a clean outside
    /// reload. Normal editor changes schedule this directly; the view calls it
    /// when an observed document generation changes through another service.
    func refreshDerivedStateForCurrentRevision() {
        refreshWordCount(
            for: draftText,
            revision: contentRevision,
            utf8ByteCount: document?.utf8ByteCount
        )
    }

    func activate(
        in workspace: Workspace,
        workspaceID: WorkspaceID? = nil,
        documentURLs: [URL],
        registry: DocumentBufferRegistry? = nil,
        conflictResolver: ConflictResolver? = nil,
        documentMover: DocumentMover? = nil
    ) {
        activationEpoch &+= 1
        let initialDocument: (document: Document, warning: String?)
        let orderedURLs = orderedInitialURLs(documentURLs, in: workspace)
        if preferredRelativePath != nil,
           orderedURLs.first.map(workspace.relativePath) != preferredRelativePath {
            guard let registry, let conflictResolver, let documentMover else { return }
            activateUnresolvedRestoration(
                in: workspace,
                registry: registry,
                conflictResolver: conflictResolver,
                documentMover: documentMover
            )
            return
        } else if openingMode == .newDocument, preferredRelativePath == nil {
            initialDocument = (makeBlankDocument(), nil)
        } else {
            initialDocument = loadInitialDocument(
                from: orderedURLs,
                in: workspace,
                registry: registry
            )
        }
        installInitialDocument(
            initialDocument,
            in: workspace,
            workspaceID: workspaceID ?? workspace.id,
            registry: registry,
            conflictResolver: conflictResolver,
            documentMover: documentMover
        )
    }

    /// Hydrates the initial picker/search/restoration target without blocking
    /// MainActor. If another activation wins while the read is in flight, its
    /// result is discarded before it can alter the current buffer.
    func activateInBackground(
        in workspace: Workspace,
        workspaceID: WorkspaceID? = nil,
        documentURLs: [URL],
        registry: DocumentBufferRegistry? = nil,
        conflictResolver: ConflictResolver? = nil,
        documentMover: DocumentMover? = nil
    ) async {
        activationEpoch &+= 1
        let requestEpoch = activationEpoch
        let initialDocument: (document: Document, warning: String?)
        let orderedURLs = orderedInitialURLs(documentURLs, in: workspace)
        if preferredRelativePath != nil,
           orderedURLs.first.map(workspace.relativePath) != preferredRelativePath {
            guard !Task.isCancelled, activationEpoch == requestEpoch,
                  let registry, let conflictResolver, let documentMover else { return }
            activateUnresolvedRestoration(
                in: workspace,
                registry: registry,
                conflictResolver: conflictResolver,
                documentMover: documentMover
            )
            return
        } else if openingMode == .newDocument, preferredRelativePath == nil {
            initialDocument = (makeBlankDocument(), nil)
        } else {
            initialDocument = await loadInitialDocumentInBackground(
                from: orderedURLs,
                in: workspace,
                registry: registry
            )
        }
        guard !Task.isCancelled, activationEpoch == requestEpoch else { return }
        installInitialDocument(
            initialDocument,
            in: workspace,
            workspaceID: workspaceID ?? workspace.id,
            registry: registry,
            conflictResolver: conflictResolver,
            documentMover: documentMover
        )
    }

    func activate(
        documentURL: URL,
        in workspace: Workspace,
        workspaceID: WorkspaceID,
        registry: DocumentBufferRegistry? = nil,
        conflictResolver: ConflictResolver? = nil,
        documentMover: DocumentMover? = nil,
        preferredDocumentID: DocumentID? = nil
    ) throws {
        prepareForActivation(
            registry: registry,
            conflictResolver: conflictResolver,
            documentMover: documentMover
        )
        let requestedID = preferredDocumentID ?? restoredDocumentID
        let loaded = try registry?.open(
            documentURL,
            in: workspace,
            preferredID: requestedID
        ) ?? workspace.loadDocument(at: documentURL, id: requestedID ?? DocumentID())
        bind(
            loaded,
            to: workspace,
            workspaceID: workspaceID,
            exposesWorkspaceLocator: true
        )
        preferredWorkspaceID = workspaceID
        preferredRelativePath = workspace.relativePath(for: documentURL)
        errorMessage = nil
        presentedErrorContext = .general
    }

    func activate(
        document: Document,
        in workspace: Workspace,
        workspaceID: WorkspaceID,
        registry: DocumentBufferRegistry,
        conflictResolver: ConflictResolver,
        documentMover: DocumentMover
    ) {
        prepareForActivation(
            registry: registry,
            conflictResolver: conflictResolver,
            documentMover: documentMover
        )
        bind(
            document,
            to: workspace,
            workspaceID: workspaceID,
            exposesWorkspaceLocator: true
        )
        preferredWorkspaceID = workspaceID
        preferredRelativePath = document.fileURL.map(workspace.relativePath)
        errorMessage = nil
        presentedErrorContext = .general
    }

    /// Opens a Powerbox-authorized file before its parent folder is granted.
    /// The selected file remains directly writable while Clio asks for the
    /// broader parent grant used by discovery and restoration.
    func activateExternal(
        documentURL: URL,
        registry: DocumentBufferRegistry? = nil,
        conflictResolver: ConflictResolver? = nil,
        documentMover: DocumentMover? = nil
    ) throws {
        prepareForActivation(
            registry: registry,
            conflictResolver: conflictResolver,
            documentMover: documentMover
        )
        releaseExternalFileAccess(clearIntent: true)
        let directWorkspace = try? Workspace(
            rootURL: documentURL.deletingLastPathComponent(),
            accessSecurityScopedResource: false
        )
        guard let directWorkspace else {
            throw Workspace.WorkspaceError.rootDoesNotExist(
                documentURL.deletingLastPathComponent()
            )
        }
        let loaded = try registry?.open(documentURL, in: directWorkspace)
            ?? Document(contentsOf: documentURL)
        bind(
            loaded,
            to: directWorkspace,
            workspaceID: nil,
            exposesWorkspaceLocator: false
        )
        relativePath = documentURL.lastPathComponent
        preferredRelativePath = nil
        preferredWorkspaceID = nil
        errorMessage = nil
        presentedErrorContext = .general
    }

    /// Powerbox open path for documents that must be hydrated away from the
    /// main actor before their parent folder has been bookmarked.
    func activateExternalInBackground(
        documentURL: URL,
        accessLease: SecurityScopedFileLease? = nil,
        reconcile: (@MainActor (WorkspaceEvent, Workspace) async -> Void)? = nil,
        registry: DocumentBufferRegistry? = nil,
        conflictResolver: ConflictResolver? = nil,
        documentMover: DocumentMover? = nil
    ) async throws {
        activationEpoch &+= 1
        let requestEpoch = activationEpoch
        guard let directWorkspace = try? Workspace(
            rootURL: documentURL.deletingLastPathComponent(),
            accessSecurityScopedResource: false,
            crashRecoveryJournal: crashRecoveryJournal,
            recoverWorkspaceTransactions: false
        ) else {
            throw Workspace.WorkspaceError.rootDoesNotExist(
                documentURL.deletingLastPathComponent()
            )
        }
        let loaded: Document
        if let registry {
            loaded = try await registry.openInBackground(
                documentURL,
                in: directWorkspace,
                preferredID: restoredDocumentID
            )
        } else {
            loaded = try await directWorkspace.loadDocumentInBackground(
                at: documentURL
            )
        }
        guard !Task.isCancelled, activationEpoch == requestEpoch else {
            throw CancellationError()
        }
        prepareForActivation(
            registry: registry,
            conflictResolver: conflictResolver,
            documentMover: documentMover
        )
        bind(
            loaded,
            to: directWorkspace,
            workspaceID: nil,
            exposesWorkspaceLocator: false
        )
        externalFileLease = accessLease
        preferredExternalFileBookmark = accessLease?.bookmark
        preferredExternalFileURL = accessLease?.url ?? documentURL.standardizedFileURL
        relativePath = documentURL.lastPathComponent
        preferredRelativePath = nil
        preferredWorkspaceID = nil
        errorMessage = nil
        presentedErrorContext = .general
        if let reconcile {
            let watcher = ExactFileWatcher(fileURL: documentURL)
            exactFileWatcher = watcher
            exactFileWatcherTask = Task { @MainActor [weak self, watcher] in
                for await event in watcher.events() {
                    guard !Task.isCancelled, let self,
                          self.exactFileWatcher === watcher else { return }
                    // A revoked or symlink-replaced path is detached without
                    // reading it, preserving the buffer and stopping autosave.
                    await reconcile(WorkspaceEvent(workspaceID: directWorkspace.id,
                        kind: event == .changed ? .modified : .deleted,
                        fileURL: documentURL), directWorkspace)
                }
            }
        }
    }

    /// Keeps a failed exact-file restoration visible and editable. The stored
    /// bookmark remains attached so a later reauthorization can recover the
    /// original intent instead of substituting another workspace document.
    func activateUnresolvedExternalRestoration(
        registry: DocumentBufferRegistry,
        conflictResolver: ConflictResolver,
        documentMover: DocumentMover,
        underlyingError: Error
    ) {
        prepareForActivation(
            registry: registry,
            conflictResolver: conflictResolver,
            documentMover: documentMover
        )
        let placeholder = Document(
            preferredFilename: preferredExternalFileURL?.lastPathComponent
                ?? preferredFilenameForRestoration,
            id: restoredDocumentID ?? DocumentID(rawValue: id)
        )
        let canonical = registry.registerUnbacked(placeholder)
        registry.bind(self, to: canonical)
        document = canonical
        restoredDocumentID = canonical.id
        ownsAutosaver = false
        autosaver = nil
        detachedDraftText = ""
        relativePath = preferredExternalFileURL?.lastPathComponent ?? ""
        isRestorationUnresolved = true
        refreshWordCount(for: canonical.text, revision: canonical.revision)
        errorMessage = "Clio couldn’t restore access to \(displayName). The tab remains detached and no other document was substituted.\n\n\(underlyingError.localizedDescription)"
        presentedErrorContext = .general
    }

    /// Keeps an exact failed restoration intent visible and editable in memory.
    /// It must never silently open the newest unrelated document.
    func activateUnresolvedRestoration(
        in workspace: Workspace?,
        registry: DocumentBufferRegistry,
        conflictResolver: ConflictResolver,
        documentMover: DocumentMover,
        underlyingError: Error? = nil
    ) {
        prepareForActivation(
            registry: registry,
            conflictResolver: conflictResolver,
            documentMover: documentMover
        )
        releaseExternalFileAccess(clearIntent: true)
        let placeholder = Document(
            preferredFilename: preferredFilenameForRestoration,
            id: restoredDocumentID ?? DocumentID(rawValue: id)
        )
        let canonical = registry.registerUnbacked(placeholder)
        registry.bind(self, to: canonical)
        self.workspace = workspace
        workspaceID = preferredWorkspaceID
        document = canonical
        restoredDocumentID = canonical.id
        ownsAutosaver = false
        autosaver = nil
        detachedDraftText = ""
        relativePath = preferredRelativePath ?? ""
        isRestorationUnresolved = true
        refreshWordCount(
            for: canonical.text,
            revision: canonical.revision,
            utf8ByteCount: canonical.utf8ByteCount
        )
        viewportState = viewportState.clamped(
            toUTF16Length: (canonical.text as NSString).length
        )
        let detail = underlyingError.map { "\n\n\($0.localizedDescription)" } ?? ""
        errorMessage = "Clio couldn’t find \(preferredRelativePath ?? preferredFilenameForRestoration). The restored tab remains detached; no other document was substituted.\(detail)"
        presentedErrorContext = .general
    }

    func deactivate() {
        activationEpoch &+= 1
        invalidatePendingEditorEdits()
        releaseExternalFileAccess(clearIntent: false)
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
        workspaceID = nil
        document = nil
        detachedDraftText = ""
        detachedRevision = 0
        wordCount = 0
        relativePath = ""
        errorMessage = nil
        pendingCollision = nil
        pendingRenameFilename = nil
        isRestorationUnresolved = false
        presentedErrorContext = .general
    }

    func editorTextDidChange(
        _ newText: String,
        edit _: EditorTextEdit? = nil
    ) {
        invalidatePendingEditorEdits()
        guard let document else { return }

        publishEditorText(newText, document: document, autosaver: autosaver)
    }

    /// Receives the UTF-16 mutation already supplied by NSTextView. Small
    /// documents update synchronously; large document materialization runs
    /// away from the main actor and publishes only if its base generation is
    /// still current.
    func editorTextDidChange(_ edit: MarkdownTextEdit) {
        guard editorSynchronizationFailure == nil,
              let document else { return }

        let source = document.text
        if document.utf8ByteCount <= Document.maximumSynchronousByteCount,
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
            guard let document else {
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
        autosaver: Autosaver?,
        revisionAdvance: UInt64 = 1,
        utf8ByteCount: Int? = nil
    ) {

        document.replaceTextFromEditor(
            with: newText,
            revisionAdvance: revisionAdvance,
            utf8ByteCount: utf8ByteCount
        )
        refreshWordCount(
            for: newText,
            revision: document.revision,
            utf8ByteCount: document.utf8ByteCount
        )
        guard let autosaver else {
            // A failed restoration remains an editable, detached canonical
            // buffer. Journal every accepted edit without inventing a file
            // path or requiring access to the missing original.
            if let workspace {
                workspace.scheduleCrashRecovery(for: document)
            } else if document.isDirty {
                crashRecoveryJournal?.schedule(CrashRecoverySnapshot(
                    documentID: document.id,
                    generation: BufferGeneration(
                        bufferID: document.id.rawValue,
                        revision: document.revision
                    ),
                    filename: document.filename,
                    targetURL: document.fileURL,
                    reason: .dirtyBuffer,
                    source: document.text
                ))
            }
            return
        }
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
        if let document, let autosaver,
           document.utf8ByteCount <= Document.maximumSynchronousByteCount,
           !autosaver.hasActiveFileIO {
            do {
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
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let document = self.document,
                  let autosaver = self.autosaver else { return }
            do {
                try await self.settlePendingEditorEdits()
                guard self.document === document else { return }
                try await autosaver.flushAsync(
                    document,
                    allowingDetachedRestore: document.requiresExplicitRestore
                )
                self.refreshRelativePath()
                self.clearPresentedSaveError()
            } catch {
                self.presentError(
                    "Clio couldn’t save this document. Check that the workspace is available and writable, then try again.",
                    underlying: error,
                    context: .save
                )
            }
        }
    }

    func flush() throws {
        if let editorSynchronizationFailure {
            throw editorSynchronizationFailure
        }
        guard !hasPendingEditorEdits else {
            throw EditorSynchronizationError.editorMaterializationInProgress
        }
        guard let document else { return }
        guard let autosaver else {
            if document.isDirty {
                throw SessionError.parentFolderAuthorizationRequired
            }
            return
        }
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
        preferredWorkspaceID = nil
        releaseExternalFileAccess(clearIntent: true)
        isRestorationUnresolved = false
    }


    func updateViewport(_ state: EditorViewportState) {
        viewportState = state.clamped(toUTF16Length: (draftText as NSString).length)
    }

    func restorationState() -> EditorTabRestorationState {
        let restoredViewport = document == nil
            ? viewportState
            : viewportState.clamped(toUTF16Length: (draftText as NSString).length)
        return EditorTabRestorationState(
            id: id,
            documentID: documentID,
            locator: locator,
            preferredFilename: displayName,
            viewport: restoredViewport,
            externalFileBookmark: preferredExternalFileBookmark,
            externalFileURL: preferredExternalFileURL
        )
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
        refreshWordCount(
            for: document.text,
            revision: document.revision,
            utf8ByteCount: document.utf8ByteCount
        )
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
              let workspace, let documentMover, let sourceURL = document.fileURL else {
            return .cancelled
        }
        let outcome = try await documentMover.move(
            document,
            from: workspace,
            to: workspace,
            parentRelativePath: (workspace.relativePath(for: sourceURL) as NSString).deletingLastPathComponent,
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

    func resolveCollisionNow(
        _ choice: CollisionChoice
    ) async throws -> FileMutationOutcome {
        guard let filename = pendingRenameFilename,
              let approvedCollision = pendingCollision else { return .cancelled }
        if choice == .cancel {
            pendingCollision = nil
            pendingRenameFilename = nil
            return .cancelled
        }
        return try await rename(
            to: filename,
            collisionChoice: choice,
            approvedCollision: approvedCollision
        )
    }

    func moveToTrash() throws {
        guard let document, let workspace, let documentMover else { return }
        if (registry?.hasUnsettledEditorEdits(for: document.id)
            ?? hasUnsettledEditorEdits)
            || registry?.hasActiveFileIO(for: document.id) == true
            || autosaver?.hasActiveFileIO == true {
            throw EditorSynchronizationError.editorMaterializationInProgress
        }
        try documentMover.moveToTrash(
            document,
            workspace: workspace,
            registry: registry
        )
        refreshRelativePath()
    }

    /// Async user-command counterpart for large documents. Window-close and
    /// termination delegates continue using the conservative synchronous
    /// lifecycle flush, which refuses while durable work is outstanding.
    func moveToTrashNow() async throws {
        guard let document, let workspace, let documentMover else { return }
        if let registry {
            try await registry.settlePendingEditorEdits(for: document.id)
        } else {
            try await settlePendingEditorEdits()
        }
        guard self.document === document else { return }
        try await documentMover.moveToTrashInBackground(
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
        workspaceID = workspace.id
        releaseExternalFileAccess(clearIntent: true)
        self.autosaver = autosaver
        ownsAutosaver = false
        isRestorationUnresolved = false
        refreshRelativePath()
        preferredWorkspaceID = workspace.id
        preferredRelativePath = relativePath.isEmpty ? nil : relativePath
    }

    func adoptAuthorizedWorkspace(_ workspace: Workspace) {
        guard let document, let registry else { return }
        registry.register(document, in: workspace)
        registry.retarget(document, to: workspace)
        self.workspace = workspace
        workspaceID = workspace.id
        releaseExternalFileAccess(clearIntent: true)
        preferredWorkspaceID = workspace.id
        preferredRelativePath = document.fileURL.map(workspace.relativePath)
    }

    func rebindServices(
        conflictResolver: ConflictResolver,
        documentMover: DocumentMover
    ) {
        self.conflictResolver = conflictResolver
        self.documentMover = documentMover
    }

    func releaseExternalFileAccess(clearIntent: Bool) {
        exactFileWatcherTask?.cancel()
        exactFileWatcherTask = nil
        exactFileWatcher?.cancel()
        exactFileWatcher = nil
        externalFileLease?.release()
        externalFileLease = nil
        if clearIntent {
            preferredExternalFileBookmark = nil
            preferredExternalFileURL = nil
        }
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
                    MarkdownTextEditApplier.applying(edits, to: baseSource).map {
                        ($0, $0.utf8.count)
                    }
                }
                guard let (updated, utf8ByteCount) = await worker.value,
                      !Task.isCancelled,
                      self.editorEditEpoch == epoch,
                      self.document === document,
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
                    autosaver: self.autosaver,
                    revisionAdvance: revisionAdvance,
                    utf8ByteCount: utf8ByteCount
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
        in workspace: Workspace,
        registry: DocumentBufferRegistry?
    ) -> (document: Document, warning: String?) {
        var failures: [(url: URL, error: Error)] = []

        for documentURL in documentURLs {
            do {
                let preferredID = preferredRelativePath == workspace.relativePath(for: documentURL)
                    ? restoredDocumentID
                    : nil
                let document = try registry?.open(
                    documentURL,
                    in: workspace,
                    preferredID: preferredID
                ) ?? workspace.loadDocument(
                    at: documentURL,
                    id: preferredID ?? DocumentID()
                )
                return (document, unreadableDocumentWarning(failures))
            } catch {
                failures.append((documentURL, error))
            }
        }

        return (makeBlankDocument(), unreadableDocumentWarning(failures))
    }

    func loadInitialDocumentInBackground(
        from documentURLs: [URL],
        in workspace: Workspace,
        registry: DocumentBufferRegistry?
    ) async -> (document: Document, warning: String?) {
        var failures: [(url: URL, error: Error)] = []

        for documentURL in documentURLs {
            do {
                let preferredID = preferredRelativePath
                    == workspace.relativePath(for: documentURL)
                    ? restoredDocumentID
                    : nil
                let document: Document
                if let registry {
                    document = try await registry.openInBackground(
                        documentURL,
                        in: workspace,
                        preferredID: preferredID
                    )
                } else {
                    document = try await workspace.loadDocumentInBackground(
                        at: documentURL,
                        id: preferredID ?? DocumentID()
                    )
                }
                return (document, unreadableDocumentWarning(failures))
            } catch is CancellationError {
                return (Document(), nil)
            } catch {
                failures.append((documentURL, error))
            }
        }

        return (makeBlankDocument(), unreadableDocumentWarning(failures))
    }

    func orderedInitialURLs(
        _ documentURLs: [URL],
        in workspace: Workspace
    ) -> [URL] {
        guard let preferredRelativePath,
              let preferredIndex = documentURLs.firstIndex(where: {
                  workspace.relativePath(for: $0) == preferredRelativePath
              }) else {
            return openingMode == .newDocument ? [] : documentURLs
        }
        var preferredFirstURLs = documentURLs
        let preferredURL = preferredFirstURLs.remove(at: preferredIndex)
        preferredFirstURLs.insert(preferredURL, at: 0)
        return preferredFirstURLs
    }

    func installInitialDocument(
        _ initialDocument: (document: Document, warning: String?),
        in workspace: Workspace,
        workspaceID: WorkspaceID,
        registry: DocumentBufferRegistry?,
        conflictResolver: ConflictResolver?,
        documentMover: DocumentMover?
    ) {
        if preferredRelativePath != nil,
           initialDocument.document.fileURL == nil,
           let registry, let conflictResolver, let documentMover {
            activateUnresolvedRestoration(
                in: workspace,
                registry: registry,
                conflictResolver: conflictResolver,
                documentMover: documentMover
            )
            if let warning = initialDocument.warning {
                errorMessage = warning
            }
            return
        }

        invalidatePendingEditorEdits()
        editorMaterializationCount = 0
        editorPublicationCount = 0
        prepareForActivation(
            registry: registry,
            conflictResolver: conflictResolver,
            documentMover: documentMover
        )
        bind(
            initialDocument.document,
            to: workspace,
            workspaceID: workspaceID,
            exposesWorkspaceLocator: true
        )
        detachedRevision = 0
        errorMessage = initialDocument.warning
        presentedErrorContext = .general
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
                    self.hasRetainedExternalFileAccess
                        ? "Clio couldn’t safely save this file with its current access. Authorize its parent folder using Add Folder, then choose Save. Your edits remain in memory and recovery."
                        : "Clio couldn’t autosave this document. Check that the workspace is available and writable, then choose Save.",
                    underlying: error,
                    context: .save
                )
            } else if !autosaver.hasPendingSave {
                self.clearPresentedSaveError()
            }
        }
    }

    func refreshWordCount(
        for source: String,
        revision: UInt64,
        utf8ByteCount: Int? = nil
    ) {
        let request = (documentID: document?.id, revision: revision)
        guard wordCountRequest?.documentID != request.documentID
                || wordCountRequest?.revision != request.revision else { return }
        wordCountRequest = request
        wordCountTask?.cancel()

        if (utf8ByteCount ?? source.utf8.count)
            <= Document.maximumSynchronousByteCount {
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

private extension EditorSession {
    func prepareForActivation(
        registry: DocumentBufferRegistry?,
        conflictResolver: ConflictResolver?,
        documentMover: DocumentMover?
    ) {
        activationEpoch &+= 1
        invalidatePendingEditorEdits()
        editorMaterializationCount = 0
        editorPublicationCount = 0
        wordCountTask?.cancel()
        autosaveErrorMonitor?.cancel()
        releaseExternalFileAccess(clearIntent: false)
        if ownsAutosaver { autosaver?.cancel() }
        self.registry?.unbind(self)
        self.registry = registry
        self.conflictResolver = conflictResolver
        self.documentMover = documentMover
        ownsAutosaver = false
        autosaver = nil
        isRestorationUnresolved = false
    }

    func bind(
        _ proposedDocument: Document,
        to workspace: Workspace,
        workspaceID: WorkspaceID?,
        exposesWorkspaceLocator: Bool
    ) {
        let canonical: Document
        if proposedDocument.fileURL == nil {
            canonical = registry?.registerUnbacked(proposedDocument) ?? proposedDocument
        } else {
            registry?.register(proposedDocument, in: workspace)
            canonical = registry?.document(withID: proposedDocument.id) ?? proposedDocument
        }
        self.workspace = workspace
        self.workspaceID = exposesWorkspaceLocator ? workspaceID : nil
        if exposesWorkspaceLocator {
            releaseExternalFileAccess(clearIntent: true)
        }
        document = canonical
        restoredDocumentID = canonical.id
        registry?.bind(self, to: canonical)
        ownsAutosaver = registry == nil
        autosaver = registry?.autosaver(for: canonical, in: workspace)
            ?? Autosaver(workspace: workspace)
        detachedDraftText = ""
        detachedRevision = 0
        isRestorationUnresolved = false
        preferredFilenameForRestoration = canonical.filename
        refreshWordCount(
            for: canonical.text,
            revision: canonical.revision,
            utf8ByteCount: canonical.utf8ByteCount
        )
        viewportState = viewportState.clamped(
            toUTF16Length: (canonical.text as NSString).length
        )
        refreshRelativePath()
    }

    func makeBlankDocument() -> Document {
        Document(
            preferredFilename: preferredFilenameForRestoration,
            id: restoredDocumentID ?? DocumentID(rawValue: id)
        )
    }
}
