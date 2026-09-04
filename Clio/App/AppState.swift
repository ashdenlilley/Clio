import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppState: ClioCommandDispatching {
    enum AccentPreset: String, CaseIterable, Identifiable, Sendable {
        case green
        case amber
        case cyan

        var id: Self { self }

        var title: String {
            rawValue.capitalized
        }
    }

    private(set) var workspace: Workspace?
    private(set) var workspaceErrorMessage: String?
    private(set) var workspaceTrees: [WorkspaceID: WorkspaceTreeSnapshot] = [:]
    private(set) var isRefreshingWorkspaces = false

    let workspaceCatalog: WorkspaceCatalog
    let discoverySettings: WorkspaceDiscoverySettings

    var fontSize: Double = 14 {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    var measure: Int = 72 {
        didSet { defaults.set(measure, forKey: Keys.measure) }
    }

    var lineHeight: Double = 1.65 {
        didSet { defaults.set(lineHeight, forKey: Keys.lineHeight) }
    }

    var typewriterAnchor: Double = 0.45 {
        didSet { defaults.set(typewriterAnchor, forKey: Keys.typewriterAnchor) }
    }

    var focusDimmingOpacity: Double = 0.28 {
        didSet { defaults.set(focusDimmingOpacity, forKey: Keys.focusDimmingOpacity) }
    }

    var isSpellCheckingEnabled = true {
        didSet { defaults.set(isSpellCheckingEnabled, forKey: Keys.spellChecking) }
    }

    var accent: AccentPreset = .green {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }

    var isTypewriterModeEnabled = true {
        didSet { defaults.set(isTypewriterModeEnabled, forKey: Keys.typewriterMode) }
    }

    var isFocusModeEnabled = true {
        didSet { defaults.set(isFocusModeEnabled, forKey: Keys.focusMode) }
    }

    var isChromeFadeEnabled = true {
        didSet { defaults.set(isChromeFadeEnabled, forKey: Keys.chromeFade) }
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private let fileManager: FileManager

    @ObservationIgnored
    private var editorSessions: [EditorSession] = []

    @ObservationIgnored
    private var editorWindows: [EditorWindowSession] = []

    @ObservationIgnored
    private let workspaceScanner: WorkspaceScanner

    @ObservationIgnored
    private let searchIndex: (any SearchIndexing)?

    @ObservationIgnored
    private var discoveryTask: Task<Void, Never>?

    @ObservationIgnored
    private var legacyWorkspaceDescriptor: WorkspaceDescriptor?

    @ObservationIgnored
    private var pendingExternalDocumentURLs: [URL] = []

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        initialWorkspace: Workspace? = nil,
        workspaceCatalog: WorkspaceCatalog? = nil,
        discoverySettings: WorkspaceDiscoverySettings? = nil,
        searchIndex: (any SearchIndexing)? = nil
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.workspaceCatalog = workspaceCatalog
            ?? WorkspaceCatalog(defaults: defaults)
        self.discoverySettings = discoverySettings
            ?? WorkspaceDiscoverySettings(defaults: defaults)
        workspaceScanner = WorkspaceScanner(fileManager: fileManager)
        self.searchIndex = searchIndex ?? (try? SQLiteSearchIndex())

        fontSize = Self.clamp(
            Self.double(forKey: Keys.fontSize, default: 14, in: defaults),
            to: 12...20
        )
        measure = Self.clamp(
            Self.integer(forKey: Keys.measure, default: 72, in: defaults),
            to: 60...90
        )
        lineHeight = Self.clamp(
            Self.double(forKey: Keys.lineHeight, default: 1.65, in: defaults),
            to: 1.2...2.0
        )
        typewriterAnchor = Self.clamp(
            Self.double(forKey: Keys.typewriterAnchor, default: 0.45, in: defaults),
            to: 0.3...0.6
        )
        focusDimmingOpacity = Self.clamp(
            Self.double(forKey: Keys.focusDimmingOpacity, default: 0.28, in: defaults),
            to: 0.1...0.6
        )

        isSpellCheckingEnabled = Self.bool(
            forKey: Keys.spellChecking,
            default: true,
            in: defaults
        )
        isTypewriterModeEnabled = Self.bool(
            forKey: Keys.typewriterMode,
            default: true,
            in: defaults
        )
        isFocusModeEnabled = Self.bool(
            forKey: Keys.focusMode,
            default: true,
            in: defaults
        )
        isChromeFadeEnabled = Self.bool(
            forKey: Keys.chromeFade,
            default: true,
            in: defaults
        )
        if let storedAccent = defaults.string(forKey: Keys.accent),
           let accent = AccentPreset(rawValue: storedAccent) {
            self.accent = accent
        }

        if let initialWorkspace {
            workspace = initialWorkspace
            legacyWorkspaceDescriptor = WorkspaceDescriptor(
                rootURL: initialWorkspace.rootURL
            )
        } else if let firstCatalogWorkspace = self.workspaceCatalog.workspaces.first {
            workspace = firstCatalogWorkspace
        } else {
            restoreWorkspaceIfAvailable()
        }

        if workspace != nil || !self.workspaceCatalog.descriptors.isEmpty {
            refreshWorkspaceDiscovery()
        }
    }

    var isWorkspaceReady: Bool {
        primaryWorkspace != nil
    }

    var workspaceRootPath: String? {
        primaryWorkspace?.workspace.rootURL.path
    }

    var workspaceDescriptors: [WorkspaceDescriptor] {
        var descriptors = workspaceCatalog.descriptors
        if let legacyWorkspaceDescriptor,
           !descriptors.contains(where: { $0.rootURL == legacyWorkspaceDescriptor.rootURL }) {
            descriptors.append(legacyWorkspaceDescriptor)
        }
        return descriptors.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func adjustFontSize(by amount: Double) {
        fontSize = Self.clamp(fontSize + amount, to: 12...20)
    }

    func resetFontSize() {
        fontSize = 14
    }

    func register(_ session: EditorSession) {
        guard !editorSessions.contains(where: { $0 === session }) else { return }
        editorSessions.append(session)

        activate(session)
    }

    func unregister(_ session: EditorSession) {
        guard let index = editorSessions.firstIndex(where: { $0 === session }) else {
            return
        }

        guard session.flushForLifecycleEvent() else {
            // Keep the session alive if SwiftUI tears down a scene without
            // asking the window delegate. Its in-memory buffer must survive.
            return
        }

        editorSessions.remove(at: index)
        session.deactivate()
    }

    func register(_ window: EditorWindowSession) {
        guard !editorWindows.contains(where: { $0 === window }) else { return }
        editorWindows.append(window)
        for tab in window.tabs {
            register(tab)
        }
        if !pendingExternalDocumentURLs.isEmpty {
            let pending = pendingExternalDocumentURLs
            pendingExternalDocumentURLs.removeAll()
            for url in pending {
                openExternalDocumentURL(url, from: window)
            }
        }
    }

    func unregister(_ window: EditorWindowSession) {
        guard let index = editorWindows.firstIndex(where: { $0 === window }) else {
            return
        }
        guard window.tabs.allSatisfy({ $0.flushForLifecycleEvent() }) else { return }
        editorWindows.remove(at: index)
        for tab in window.tabs {
            if let tabIndex = editorSessions.firstIndex(where: { $0 === tab }) {
                editorSessions.remove(at: tabIndex)
            }
            tab.deactivate()
        }
    }

    func activateNewDocument(_ session: EditorSession) {
        guard !editorSessions.contains(where: { $0 === session }) else { return }
        editorSessions.append(session)
        guard let primaryWorkspace else { return }
        session.activate(
            in: primaryWorkspace.workspace,
            workspaceID: primaryWorkspace.descriptor.id,
            documentURLs: []
        )
    }

    func release(_ session: EditorSession) {
        editorSessions.removeAll { $0 === session }
    }

    @discardableResult
    func flushAllEditorSessions() -> Bool {
        var allSaved = true

        for session in editorSessions where !session.flushForLifecycleEvent() {
            allSaved = false
        }

        return allSaved
    }

    func chooseDefaultWorkspace() {
        let panel = configuredFolderPanel(
            title: "Use Documents/Clio",
            message: "Select your Documents folder. Clio will create or reuse a Clio folder inside it.",
            prompt: "Use Documents"
        )

        let preferredURL = Workspace.preferredDefaultURL
        if fileManager.fileExists(atPath: preferredURL.path) {
            panel.directoryURL = preferredURL
        } else if let physicalHomeURL = FileManager.default.homeDirectory(forUser: NSUserName()) {
            panel.directoryURL = physicalHomeURL.appendingPathComponent(
                "Documents",
                isDirectory: true
            )
        }

        guard panel.runModal() == .OK, let parentURL = panel.url else { return }

        do {
            // The panel grants the parent so Clio can create the child. The
            // helper ends that broad access before the exact child bookmark is
            // resolved and retained by Workspace.
            let bookmark = try makeDefaultWorkspaceBookmark(in: parentURL)
            let resolution = try Workspace.resolveSecurityScopedBookmark(bookmark)
            let descriptor = try workspaceCatalog.addAuthorizedFolder(
                resolution.url,
                bookmark: bookmark
            )
            workspace = workspaceCatalog.workspace(id: descriptor.id)
            legacyWorkspaceDescriptor = nil
            defaults.removeObject(forKey: Keys.workspaceBookmark)
            workspaceErrorMessage = nil
            activateUnreadySessions()
            refreshWorkspaceDiscovery()
        } catch {
            presentError(
                "Clio couldn’t use Documents/Clio. Select your Documents folder and try again.",
                underlying: error
            )
        }
    }

    func chooseAnotherWorkspace() {
        let panel = configuredFolderPanel(
            title: "Add a Clio Workspace",
            message: "Choose a folder to add to Clio’s global writing workspace.",
            prompt: "Add Folder"
        )

        if let currentRoot = workspace?.rootURL {
            panel.directoryURL = currentRoot
        } else if let physicalHomeURL = FileManager.default.homeDirectory(forUser: NSUserName()) {
            panel.directoryURL = physicalHomeURL
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        do {
            try flushEditorSessionsBeforeWorkspaceChange()
            let descriptor = try workspaceCatalog.addAuthorizedFolder(selectedURL)
            defer { selectedURL.stopAccessingSecurityScopedResource() }
            if workspace == nil {
                workspace = workspaceCatalog.workspace(id: descriptor.id)
            }
            workspaceErrorMessage = nil
            activateUnreadySessions()
            refreshWorkspaceDiscovery()
        } catch {
            presentError(
                "Clio couldn’t add that workspace. Choose a readable, writable folder and try again.",
                underlying: error
            )
        }
    }

    func removeWorkspace(_ id: WorkspaceID) {
        let removedRoot = workspaceCatalog.workspace(id: id)?.rootURL
        workspaceCatalog.remove(id)
        workspaceTrees[id] = nil
        if workspace?.rootURL == removedRoot {
            workspace = workspaceCatalog.workspaces.first
        }
        refreshWorkspaceDiscovery()
    }

    func reauthorizeWorkspace(_ failure: WorkspaceCatalog.AuthorizationFailure) {
        let panel = configuredFolderPanel(
            title: "Restore \(failure.folderName)",
            message: "Choose the same folder to restore Clio’s workspace access.",
            prompt: "Restore Access"
        )
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        do {
            try workspaceCatalog.reauthorize(failure.id, with: folderURL)
            if workspace == nil {
                workspace = workspaceCatalog.workspace(id: failure.id)
            }
            workspaceErrorMessage = nil
            activateUnreadySessions()
            refreshWorkspaceDiscovery()
        } catch {
            presentError("Clio couldn’t restore that folder’s access.", underlying: error)
        }
    }

    func discoveryPolicyDidChange() {
        refreshWorkspaceDiscovery()
    }

    func refreshWorkspaceDiscovery() {
        discoveryTask?.cancel()
        let descriptors = workspaceDescriptors
        let policy = discoverySettings.policy
        guard !descriptors.isEmpty else {
            workspaceTrees = [:]
            isRefreshingWorkspaces = false
            return
        }

        isRefreshingWorkspaces = true
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var snapshots: [WorkspaceID: WorkspaceTreeSnapshot] = [:]
            do {
                for descriptor in descriptors {
                    try Task.checkCancellation()
                    snapshots[descriptor.id] = try await self.workspaceScanner.scan(
                        workspace: descriptor,
                        policy: policy,
                        includesIgnored: self.discoverySettings.temporarilyShowsIgnored
                    )
                }
                try Task.checkCancellation()
                self.workspaceTrees = snapshots
                if let searchIndex = self.searchIndex {
                    try await searchIndex.rebuild(
                        workspaces: descriptors,
                        policy: policy
                    )
                }
                self.isRefreshingWorkspaces = false
            } catch is CancellationError {
                return
            } catch {
                self.isRefreshingWorkspaces = false
                self.presentError(
                    "Clio couldn’t refresh every workspace. Existing documents remain available.",
                    underlying: error
                )
            }
        }
    }

    func search(
        _ text: String,
        workspaceFilter: WorkspaceID?
    ) async -> AsyncThrowingStream<SearchBatch, Error> {
        guard let searchIndex else {
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
        return await searchIndex.search(
            WorkspaceSearchQuery(
                text: text,
                workspaceFilter: workspaceFilter,
                includesIgnored: discoverySettings.temporarilyShowsIgnored,
                limit: 100
            )
        )
    }

    func quickOpen(
        _ text: String,
        workspaceFilter: WorkspaceID?
    ) async -> AsyncThrowingStream<SearchBatch, Error> {
        guard let searchIndex else {
            return AsyncThrowingStream { continuation in
                continuation.finish()
            }
        }
        return await searchIndex.quickOpen(
            WorkspaceSearchQuery(
                text: text,
                workspaceFilter: workspaceFilter,
                includesIgnored: discoverySettings.temporarilyShowsIgnored,
                limit: 100
            )
        )
    }

    func openDocumentPicker(from window: EditorWindowSession) {
        let panel = NSOpenPanel()
        panel.title = "Open in Clio"
        panel.message = "Choose a Markdown or plain-text document."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md")].compactMap { $0 }

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        openExternalDocumentURL(fileURL, from: window)
    }

    func enqueueExternalDocumentURLs(_ urls: [URL]) {
        let supported = urls.filter {
            ["md", "markdown", "txt"].contains($0.pathExtension.lowercased())
        }
        guard !supported.isEmpty else { return }
        if let window = editorWindows.first {
            for url in supported {
                openExternalDocumentURL(url, from: window)
            }
        } else {
            pendingExternalDocumentURLs.append(contentsOf: supported)
        }
    }

    func openExternalDocumentURL(
        _ fileURL: URL,
        from window: EditorWindowSession
    ) {
        let didStartAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        if routeToExistingDocument(at: fileURL) {
            return
        }

        if let descriptor = descriptor(containing: fileURL),
           let authorizedWorkspace = workspace(for: descriptor.id) {
            do {
                try openDocument(
                    at: fileURL,
                    workspace: authorizedWorkspace,
                    descriptor: descriptor,
                    in: window
                )
            } catch {
                presentError("Clio couldn’t open that document.", underlying: error)
            }
            return
        }

        let tab = EditorSession(openingMode: .newDocument)
        do {
            try tab.activateExternal(documentURL: fileURL)
            editorSessions.append(tab)
            window.append(tab)
            authorizeParentFolder(of: fileURL, for: tab)
        } catch {
            presentError("Clio couldn’t open that document.", underlying: error)
        }
    }

    func openSearchResult(
        _ result: WorkspaceSearchResult,
        from window: EditorWindowSession
    ) {
        guard let descriptor = workspaceDescriptors.first(where: { $0.id == result.workspaceID }),
              let workspace = workspace(for: descriptor.id) else { return }
        let fileURL = descriptor.rootURL.appendingPathComponent(result.relativePath)
        let matchViewport = result.documentMatchRange.map {
            EditorViewportState(
                selection: $0,
                topVisibleUTF16Offset: $0.location,
                fractionalYOffset: 0
            )
        }
        guard !routeToExistingDocument(
            at: fileURL,
            applying: matchViewport
        ) else { return }
        do {
            let tab = try openDocument(
                at: fileURL,
                workspace: workspace,
                descriptor: descriptor,
                documentID: result.documentID,
                in: window
            )
            if let matchViewport { tab.updateViewport(matchViewport) }
        } catch {
            presentError("Clio couldn’t open that search result.", underlying: error)
        }
    }

    func openWorkspaceFile(
        workspaceID: WorkspaceID,
        relativePath: String,
        from window: EditorWindowSession
    ) {
        guard let descriptor = workspaceDescriptors.first(where: { $0.id == workspaceID }),
              let workspace = workspace(for: workspaceID) else { return }
        let fileURL = descriptor.rootURL.appendingPathComponent(relativePath)
        guard !routeToExistingDocument(at: fileURL) else { return }
        do {
            try openDocument(
                at: fileURL,
                workspace: workspace,
                descriptor: descriptor,
                in: window
            )
        } catch {
            presentError("Clio couldn’t open that document.", underlying: error)
        }
    }

    func dragPayload(
        workspaceID: WorkspaceID,
        relativePath: String
    ) -> String? {
        guard let locator = try? DocumentLocator(
            workspaceID: workspaceID,
            relativePath: relativePath
        ), let data = try? JSONEncoder().encode(locator) else { return nil }
        return data.base64EncodedString()
    }

    @discardableResult
    func moveDocument(
        dragPayload: String,
        toWorkspaceID destinationWorkspaceID: WorkspaceID,
        parentRelativePath: String
    ) -> Bool {
        guard let data = Data(base64Encoded: dragPayload),
              let source = try? JSONDecoder().decode(DocumentLocator.self, from: data),
              let sourceWorkspace = workspace(for: source.workspaceID),
              let destinationWorkspace = workspace(for: destinationWorkspaceID) else {
            return false
        }

        let sourceURL = sourceWorkspace.rootURL
            .appendingPathComponent(source.relativePath)
        let parentURL = parentRelativePath.isEmpty
            ? destinationWorkspace.rootURL
            : destinationWorkspace.rootURL.appendingPathComponent(
                parentRelativePath,
                isDirectory: true
            )
        var destinationURL = parentURL.appendingPathComponent(sourceURL.lastPathComponent)
        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            return false
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            let alert = NSAlert()
            alert.messageText = "A document named \(destinationURL.lastPathComponent) already exists."
            alert.informativeText = "Cancel, move the existing copy to Trash and replace it, or keep both with a numbered name."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Keep Both")
            switch alert.runModal() {
            case .alertSecondButtonReturn:
                do {
                    try fileManager.trashItem(
                        at: destinationURL,
                        resultingItemURL: nil
                    )
                } catch {
                    presentError("Clio couldn’t replace the destination document.", underlying: error)
                    return false
                }
            case .alertThirdButtonReturn:
                destinationURL = availableNumberedURL(for: destinationURL)
            default:
                return false
            }
        }

        let openTab = editorSessions.first {
            $0.fileURL.map(PhysicalFileIdentity.authorizedFile)
                == PhysicalFileIdentity.authorizedFile(at: sourceURL)
        }
        do {
            try fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
            try openTab?.flush()
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            if let openTab {
                try openTab.activate(
                    documentURL: destinationURL,
                    in: destinationWorkspace,
                    workspaceID: destinationWorkspaceID
                )
            }
            refreshWorkspaceDiscovery()
            return true
        } catch {
            presentError("Clio couldn’t move that document.", underlying: error)
            return false
        }
    }

    func focusWindow(_ id: UUID) {
        guard let window = NSApplication.shared.windows.first(where: {
            clioEditorSessionID(for: $0) == id
        }) else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func perform(
        _ invocation: ClioCommandInvocation,
        context: ClioCommandContext
    ) async {
        let window = context.windowID.flatMap { requestedID in
            editorWindows.first { $0.id == requestedID }
        } ?? editorWindows.first
        let tab = context.tabID.flatMap { requestedID in
            window?.tabs.first { $0.id == requestedID }
        } ?? window?.activeTab

        switch invocation.command {
        case .new:
            window?.newDocument()
        case .open:
            if let window { openDocumentPicker(from: window) }
        case .search:
            window?.presentPalette(source: context.source, mode: .search)
        case .rename:
            if let tab { rename(tab) }
        case .delete:
            if let tab, let window { delete(tab, from: window) }
        case .reveal:
            if let fileURL = tab?.fileURL {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        case .folder:
            chooseAnotherWorkspace()
        case .export:
            NotificationCenter.default.post(
                name: .clioRequestedExport,
                object: tab,
                userInfo: [ClioExportNotificationKey.arguments: invocation.arguments]
            )
        case .focus:
            isFocusModeEnabled.toggle()
        case .typewriter:
            isTypewriterModeEnabled.toggle()
        case .sidebar:
            window?.toggleSidebar()
        case .settings:
            NSApplication.shared.sendAction(
                Selector(("showSettingsWindow:")),
                to: nil,
                from: nil
            )
        }
    }

    func dismissWorkspaceError() {
        workspaceErrorMessage = nil
    }
}

extension Notification.Name {
    static let clioRequestedExport = Notification.Name("ClioRequestedExport")
}

enum ClioExportNotificationKey {
    static let arguments = "ClioExportArguments"
}

private extension AppState {
    struct WorkspaceSelection {
        let descriptor: WorkspaceDescriptor
        let workspace: Workspace
    }

    var primaryWorkspace: WorkspaceSelection? {
        if let workspace,
           let descriptor = descriptor(containingRoot: workspace.rootURL) {
            return WorkspaceSelection(descriptor: descriptor, workspace: workspace)
        }
        guard let descriptor = workspaceDescriptors.first,
              let workspace = workspace(for: descriptor.id) else { return nil }
        return WorkspaceSelection(descriptor: descriptor, workspace: workspace)
    }

    func workspace(for id: WorkspaceID) -> Workspace? {
        if let catalogWorkspace = workspaceCatalog.workspace(id: id) {
            return catalogWorkspace
        }
        if legacyWorkspaceDescriptor?.id == id {
            return workspace
        }
        return nil
    }

    func descriptor(containingRoot rootURL: URL) -> WorkspaceDescriptor? {
        workspaceDescriptors.first {
            $0.rootURL.standardizedFileURL == rootURL.standardizedFileURL
        }
    }

    func descriptor(containing fileURL: URL) -> WorkspaceDescriptor? {
        workspaceDescriptors
            .filter { descriptor in
                let rootPath = descriptor.rootURL.standardizedFileURL.path
                let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
                return path == rootPath || path.hasPrefix(rootPath + "/")
            }
            .max { $0.rootURL.path.count < $1.rootURL.path.count }
    }

    func activate(_ session: EditorSession) {
        guard let primaryWorkspace else { return }

        if session.openingMode == .newDocument,
           !session.hasPreferredDocument {
            session.activate(
                in: primaryWorkspace.workspace,
                workspaceID: primaryWorkspace.descriptor.id,
                documentURLs: []
            )
            return
        }

        if let requestedWorkspaceID = session.restoredWorkspaceID,
           let requestedPath = session.restoredRelativePath,
           let requestedWorkspace = workspace(for: requestedWorkspaceID) {
            let requestedURL = requestedWorkspace.rootURL
                .appendingPathComponent(requestedPath)
            if fileManager.fileExists(atPath: requestedURL.path) {
                do {
                    try session.activate(
                        documentURL: requestedURL,
                        in: requestedWorkspace,
                        workspaceID: requestedWorkspaceID
                    )
                    return
                } catch {
                    presentError(
                        "Clio couldn’t restore \(requestedPath). A blank tab remains available.",
                        underlying: error
                    )
                }
            }
        }

        do {
            let openIdentities = Set(
                editorSessions
                    .filter { $0 !== session }
                    .compactMap(\.fileURL)
                    .map(PhysicalFileIdentity.authorizedFile)
            )
            let candidates = try workspaceDescriptors.flatMap { descriptor -> [(URL, WorkspaceDescriptor, Workspace)] in
                guard let candidateWorkspace = workspace(for: descriptor.id) else { return [] }
                return try candidateWorkspace.documentURLs().map {
                    ($0, descriptor, candidateWorkspace)
                }
            }.filter {
                !openIdentities.contains(PhysicalFileIdentity.authorizedFile(at: $0.0))
            }.sorted {
                let left = (try? $0.0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                let right = (try? $1.0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                if left != right { return left > right }
                return $0.0.path.localizedStandardCompare($1.0.path) == .orderedAscending
            }

            if let candidate = candidates.first {
                try session.activate(
                    documentURL: candidate.0,
                    in: candidate.2,
                    workspaceID: candidate.1.id
                )
            } else {
                session.activate(
                    in: primaryWorkspace.workspace,
                    workspaceID: primaryWorkspace.descriptor.id,
                    documentURLs: []
                )
                session.resolveAsNewDocument()
            }
        } catch {
            session.activate(
                in: primaryWorkspace.workspace,
                workspaceID: primaryWorkspace.descriptor.id,
                documentURLs: []
            )
            presentError(
                "Clio still has workspace access, but couldn’t read every document.",
                underlying: error
            )
        }
    }

    func activateUnreadySessions() {
        for session in editorSessions where !session.isReady {
            activate(session)
        }
    }

    @discardableResult
    func openDocument(
        at fileURL: URL,
        workspace: Workspace,
        descriptor: WorkspaceDescriptor,
        documentID: DocumentID? = nil,
        in window: EditorWindowSession
    ) throws -> EditorSession {
        let tab = EditorSession(
            openingMode: .mostRecent,
            restoredDocumentID: documentID
        )
        try tab.activate(
            documentURL: fileURL,
            in: workspace,
            workspaceID: descriptor.id
        )
        editorSessions.append(tab)
        window.append(tab)
        return tab
    }

    func routeToExistingDocument(
        at fileURL: URL,
        applying viewport: EditorViewportState? = nil
    ) -> Bool {
        let identity = PhysicalFileIdentity.authorizedFile(at: fileURL)
        for window in editorWindows {
            if let tab = window.tabs.first(where: { candidate in
                guard let candidateURL = candidate.fileURL else { return false }
                return PhysicalFileIdentity.authorizedFile(at: candidateURL) == identity
            }) {
                if let viewport { tab.updateViewport(viewport) }
                window.focus(tabID: tab.id)
                return true
            }
        }
        return false
    }

    func authorizeParentFolder(of fileURL: URL, for tab: EditorSession) {
        let parentURL = fileURL.deletingLastPathComponent()
        let panel = configuredFolderPanel(
            title: "Add \(parentURL.lastPathComponent) to Clio?",
            message: "Clio opened \(fileURL.lastPathComponent). Authorize its parent folder to include nearby documents in search and navigation.",
            prompt: "Add Parent Folder"
        )
        panel.directoryURL = parentURL
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        defer { selectedURL.stopAccessingSecurityScopedResource() }

        do {
            let descriptor = try workspaceCatalog.addAuthorizedFolder(
                selectedURL,
                containing: fileURL
            )
            guard let authorizedWorkspace = workspaceCatalog.workspace(id: descriptor.id) else {
                throw Workspace.WorkspaceError.fileOutsideWorkspace(fileURL)
            }
            try tab.activate(
                documentURL: fileURL,
                in: authorizedWorkspace,
                workspaceID: descriptor.id
            )
            if workspace == nil {
                workspace = authorizedWorkspace
            }
            refreshWorkspaceDiscovery()
        } catch {
            presentError(
                "The document stays open, but Clio couldn’t authorize its parent folder.",
                underlying: error
            )
        }
    }

    func rename(_ tab: EditorSession) {
        guard let sourceURL = tab.fileURL,
              let workspaceID = tab.workspaceID,
              let workspace = workspace(for: workspaceID) else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Document"
        alert.informativeText = "Enter a filename. The document remains in its current folder."
        let field = NSTextField(string: sourceURL.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var proposedName = (field.stringValue as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if URL(fileURLWithPath: proposedName).pathExtension.isEmpty,
           !sourceURL.pathExtension.isEmpty {
            proposedName += ".\(sourceURL.pathExtension)"
        }
        guard !proposedName.isEmpty, proposedName != sourceURL.lastPathComponent else { return }
        var destinationURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(proposedName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            let collision = NSAlert()
            collision.messageText = "A document named \(proposedName) already exists."
            collision.informativeText = "Cancel, move the existing copy to Trash and replace it, or keep both with a numbered name."
            collision.addButton(withTitle: "Cancel")
            collision.addButton(withTitle: "Replace")
            collision.addButton(withTitle: "Keep Both")
            switch collision.runModal() {
            case .alertSecondButtonReturn:
                do {
                    try fileManager.trashItem(
                        at: destinationURL,
                        resultingItemURL: nil
                    )
                }
                catch {
                    presentError("Clio couldn’t replace the existing document.", underlying: error)
                    return
                }
            case .alertThirdButtonReturn:
                destinationURL = availableNumberedURL(for: destinationURL)
            default:
                return
            }
        }

        do {
            try tab.flush()
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            try tab.activate(
                documentURL: destinationURL,
                in: workspace,
                workspaceID: workspaceID
            )
            refreshWorkspaceDiscovery()
        } catch {
            presentError("Clio couldn’t rename that document.", underlying: error)
        }
    }

    func delete(_ tab: EditorSession, from window: EditorWindowSession) {
        guard let fileURL = tab.fileURL else {
            window.close(tabID: tab.id)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(fileURL.lastPathComponent) to Trash?"
        alert.informativeText = "You can recover it from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        NSWorkspace.shared.recycle([fileURL]) { [weak self, weak window, weak tab] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.presentError("Clio couldn’t move that document to the Trash.", underlying: error)
                    return
                }
                if let window, let tab {
                    window.close(tabID: tab.id)
                    self.editorSessions.removeAll { $0 === tab }
                }
                self.refreshWorkspaceDiscovery()
            }
        }
    }

    func availableNumberedURL(for original: URL) -> URL {
        let directory = original.deletingLastPathComponent()
        let ext = original.pathExtension
        let base = original.deletingPathExtension().lastPathComponent
        for number in 2...10_000 {
            let name = ext.isEmpty
                ? "\(base) (\(number))"
                : "\(base) (\(number)).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(base) (\(UUID().uuidString)).\(ext)")
    }

    enum WorkspaceActivationError: LocalizedError {
        case authorization(Error)
        case contents(Error)

        var requiresNewAuthorization: Bool {
            if case .authorization = self {
                return true
            }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .authorization(let error), .contents(let error):
                return error.localizedDescription
            }
        }
    }

    enum Keys {
        static let fontSize = "editor.fontSize"
        static let measure = "editor.measure"
        static let lineHeight = "editor.lineHeight"
        static let typewriterAnchor = "editor.typewriterAnchor"
        static let focusDimmingOpacity = "editor.focusDimmingOpacity"
        static let spellChecking = "editor.spellChecking"
        static let accent = "appearance.accent"
        static let typewriterMode = "mode.typewriter"
        static let focusMode = "mode.focus"
        static let chromeFade = "mode.chromeFade"
        static let workspaceBookmark = "workspace.securityScopedBookmark"
    }

    func restoreWorkspaceIfAvailable() {
        guard let bookmark = defaults.data(forKey: Keys.workspaceBookmark) else {
            return
        }

        do {
            try activateWorkspace(from: bookmark, flushingCurrentDocuments: false)
            if let restoredWorkspace = workspace {
                let descriptor = try workspaceCatalog.addAuthorizedFolder(
                    restoredWorkspace.rootURL,
                    bookmark: bookmark
                )
                workspace = workspaceCatalog.workspace(id: descriptor.id)
                legacyWorkspaceDescriptor = nil
                defaults.removeObject(forKey: Keys.workspaceBookmark)
            }
        } catch {
            let needsNewAuthorization = (error as? WorkspaceActivationError)?
                .requiresNewAuthorization ?? false

            if needsNewAuthorization {
                defaults.removeObject(forKey: Keys.workspaceBookmark)
            }

            presentError(
                needsNewAuthorization
                    ? "Clio couldn’t reopen its workspace. Choose the folder again to restore access."
                    : "Clio still has the workspace grant, but couldn’t read the folder. Try again or choose another folder.",
                underlying: error
            )
        }
    }

    func activateWorkspace(
        from bookmark: Data,
        flushingCurrentDocuments: Bool = true
    ) throws {
        if flushingCurrentDocuments {
            try flushEditorSessionsBeforeWorkspaceChange()
        }

        let resolution: Workspace.BookmarkResolution
        let newWorkspace: Workspace

        do {
            resolution = try Workspace.resolveSecurityScopedBookmark(bookmark)
            newWorkspace = try Workspace(rootURL: resolution.url)
        } catch {
            throw WorkspaceActivationError.authorization(error)
        }

        let documentURLs: [URL]
        do {
            documentURLs = try newWorkspace.documentURLs()
        } catch {
            throw WorkspaceActivationError.contents(error)
        }

        let bookmarkToStore: Data
        do {
            bookmarkToStore = resolution.isStale
                ? try Workspace.makeSecurityScopedBookmark(for: resolution.url)
                : bookmark
        } catch {
            throw WorkspaceActivationError.authorization(error)
        }

        workspace = newWorkspace
        let descriptor = WorkspaceDescriptor(rootURL: newWorkspace.rootURL)
        legacyWorkspaceDescriptor = descriptor
        var availableDocumentURLs = documentURLs
        for session in editorSessions {
            session.activate(
                in: newWorkspace,
                workspaceID: descriptor.id,
                documentURLs: availableDocumentURLs
            )

            if let openedURL = session.fileURL?.standardizedFileURL {
                availableDocumentURLs.removeAll {
                    $0.standardizedFileURL == openedURL
                }
            }
        }

        workspaceErrorMessage = nil
        defaults.set(bookmarkToStore, forKey: Keys.workspaceBookmark)
        refreshWorkspaceDiscovery()
    }

    func flushEditorSessionsBeforeWorkspaceChange() throws {
        for session in editorSessions {
            try session.flush()
        }
    }

    func makeDefaultWorkspaceBookmark(in selectedParentURL: URL) throws -> Data {
        defer {
            // App Sandbox starts access for NSOpenPanel URLs on Clio's
            // behalf. This balances that temporary Powerbox scope exactly
            // once; bookmark-resolved URLs are started explicitly elsewhere.
            selectedParentURL.stopAccessingSecurityScopedResource()
        }

        let parentURL = selectedParentURL.standardizedFileURL
        let childURL = parentURL.lastPathComponent.caseInsensitiveCompare("Clio") == .orderedSame
            ? parentURL
            : parentURL.appendingPathComponent("Clio", isDirectory: true)
        try fileManager.createDirectory(
            at: childURL,
            withIntermediateDirectories: true
        )
        return try Workspace.makeSecurityScopedBookmark(
            for: childURL.standardizedFileURL
        )
    }

    func configuredFolderPanel(
        title: String,
        message: String,
        prompt: String
    ) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        return panel
    }

    func presentError(_ guidance: String, underlying error: Error) {
        workspaceErrorMessage = "\(guidance)\n\n\(error.localizedDescription)"
    }

    static func bool(
        forKey key: String,
        default defaultValue: Bool,
        in defaults: UserDefaults
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    static func double(
        forKey key: String,
        default defaultValue: Double,
        in defaults: UserDefaults
    ) -> Double {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.double(forKey: key)
    }

    static func integer(
        forKey key: String,
        default defaultValue: Int,
        in defaults: UserDefaults
    ) -> Int {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.integer(forKey: key)
    }

    static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
