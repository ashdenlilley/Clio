import Foundation
import Observation

enum EditorOpeningMode: String, Codable, Hashable, Sendable {
    case mostRecent
    case newDocument
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
    enum SessionError: LocalizedError {
        case parentFolderAuthorizationRequired

        var errorDescription: String? {
            "Authorize this document’s parent folder before closing Clio."
        }
    }

    let id: UUID
    private(set) var openingMode: EditorOpeningMode

    var draftText = ""
    private(set) var relativePath = ""
    private(set) var workspaceID: WorkspaceID?
    private(set) var document: Document?
    private(set) var errorMessage: String?
    var isFullScreenEnabled: Bool
    var viewportState: EditorViewportState

    @ObservationIgnored
    private var workspace: Workspace?

    @ObservationIgnored
    private var autosaver: Autosaver?

    @ObservationIgnored
    private var autosaveErrorMonitor: Task<Void, Never>?

    @ObservationIgnored
    private var preferredRelativePath: String?

    @ObservationIgnored
    private var preferredWorkspaceID: WorkspaceID?

    @ObservationIgnored
    private var preferredFilenameForRestoration: String

    @ObservationIgnored
    private var restoredDocumentID: DocumentID?

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
    }

    var isReady: Bool {
        document != nil
    }

    var fileURL: URL? {
        document?.fileURL
    }

    var hasPreferredDocument: Bool {
        preferredRelativePath != nil
    }

    var restoredWorkspaceID: WorkspaceID? {
        preferredWorkspaceID
    }

    var restoredRelativePath: String? {
        preferredRelativePath
    }

    var documentID: DocumentID {
        restoredDocumentID ?? DocumentID(rawValue: document?.id ?? id)
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

    var wordCount: Int {
        draftText.split(whereSeparator: { $0.isWhitespace }).count
    }

    var wordCountLabel: String {
        let count = wordCount
        return "\(count.formatted()) \(count == 1 ? "word" : "words")"
    }

    func activate(
        in workspace: Workspace,
        workspaceID: WorkspaceID? = nil,
        documentURLs: [URL]
    ) {
        autosaveErrorMonitor?.cancel()
        autosaver?.cancel()

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
        self.workspaceID = workspaceID
        document = initialDocument.document
        preferredFilenameForRestoration = initialDocument.document.filename
        autosaver = Autosaver(workspace: workspace)
        draftText = initialDocument.document.text
        viewportState = viewportState.clamped(
            toUTF16Length: (draftText as NSString).length
        )
        refreshRelativePath()
        errorMessage = initialDocument.warning
        presentedErrorContext = .general
    }

    func activate(
        documentURL: URL,
        in workspace: Workspace,
        workspaceID: WorkspaceID
    ) throws {
        autosaveErrorMonitor?.cancel()
        autosaver?.cancel()

        if restoredDocumentID == nil, let currentDocument = document {
            restoredDocumentID = DocumentID(rawValue: currentDocument.id)
        }

        let loaded = try workspace.loadDocument(at: documentURL)
        self.workspace = workspace
        self.workspaceID = workspaceID
        document = loaded
        preferredFilenameForRestoration = loaded.filename
        autosaver = Autosaver(workspace: workspace)
        draftText = loaded.text
        viewportState = viewportState.clamped(
            toUTF16Length: (draftText as NSString).length
        )
        preferredWorkspaceID = workspaceID
        preferredRelativePath = workspace.relativePath(for: documentURL)
        refreshRelativePath()
        errorMessage = nil
        presentedErrorContext = .general
    }

    /// Opens a Powerbox-authorized file before its parent folder is granted.
    /// The selected file remains directly writable while Clio asks for the
    /// broader parent grant used by discovery and restoration.
    func activateExternal(documentURL: URL) throws {
        autosaveErrorMonitor?.cancel()
        autosaver?.cancel()
        let loaded = try Document(contentsOf: documentURL)
        let directWorkspace = try? Workspace(
            rootURL: documentURL.deletingLastPathComponent(),
            accessSecurityScopedResource: false
        )
        workspace = directWorkspace
        workspaceID = nil
        document = loaded
        preferredFilenameForRestoration = loaded.filename
        autosaver = directWorkspace.map { Autosaver(workspace: $0) }
        draftText = loaded.text
        viewportState = viewportState.clamped(
            toUTF16Length: (draftText as NSString).length
        )
        relativePath = documentURL.lastPathComponent
        preferredRelativePath = nil
        preferredWorkspaceID = nil
        errorMessage = nil
        presentedErrorContext = .general
    }

    func deactivate() {
        autosaveErrorMonitor?.cancel()
        autosaver?.cancel()
        autosaver = nil
        workspace = nil
        workspaceID = nil
        document = nil
        draftText = ""
        relativePath = ""
        errorMessage = nil
        presentedErrorContext = .general
    }

    func editorTextDidChange(_ newText: String) {
        guard let document else { return }

        draftText = newText
        document.replaceText(with: newText)
        guard let autosaver else {
            errorMessage = SessionError.parentFolderAuthorizationRequired
                .localizedDescription
            presentedErrorContext = .save
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
        do {
            try flush()
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
            viewport: restoredViewport
        )
    }
}

private extension EditorSession {
    enum PresentedErrorContext {
        case general
        case save
    }

    func loadInitialDocument(
        from documentURLs: [URL],
        in workspace: Workspace
    ) -> (document: Document, warning: String?) {
        var failures: [(url: URL, error: Error)] = []

        for documentURL in documentURLs {
            do {
                let document = try workspace.loadDocument(at: documentURL)
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
