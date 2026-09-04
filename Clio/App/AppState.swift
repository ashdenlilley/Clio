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
    private(set) var needsRecoveryAuthorization = false
    private(set) var pendingCrashRecoveryCount = 0
    private(set) var recoveredCrashBufferCount = 0
    private(set) var crashRecoveryMessage: String?
    private(set) var isCrashRecoveryDurabilityCompromised = false
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
    private let crashRecoveryJournal: CrashRecoveryJournal

    @ObservationIgnored
    private var recoveryStore: any RecoveryPersisting

    @ObservationIgnored
    private var editorSessions: [EditorSession] = []

    @ObservationIgnored
    let documentRegistry: DocumentBufferRegistry

    @ObservationIgnored
    private(set) var conflictResolver: ConflictResolver

    @ObservationIgnored
    private(set) var documentMover: DocumentMover

    @ObservationIgnored
    private var workspaceWatcher: WorkspaceWatcher?

    @ObservationIgnored
    private var workspaceWatchTask: Task<Void, Never>?

    @ObservationIgnored
    private var crashRecoveryTask: Task<Void, Never>?

    @ObservationIgnored
    private var crashRecoveryRescanRequested = false

    @ObservationIgnored
    private var nonDurableCrashDocuments = Set<DocumentID>()

    @ObservationIgnored
    private var editorWindows: [EditorWindowSession] = []

    @ObservationIgnored
    private let workspaceIndexCoordinator: WorkspaceIndexCoordinator

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
        recoveryStore: RecoveryStore? = nil,
        crashRecoveryJournal: CrashRecoveryJournal = .shared,
        workspaceCatalog: WorkspaceCatalog? = nil,
        discoverySettings: WorkspaceDiscoverySettings? = nil,
        searchIndex: (any SearchIndexing)? = nil,
        documentRegistry suppliedDocumentRegistry: DocumentBufferRegistry? = nil,
        conflictResolver suppliedConflictResolver: ConflictResolver? = nil,
        documentMover suppliedDocumentMover: DocumentMover? = nil
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.crashRecoveryJournal = crashRecoveryJournal
        let activeRecoveryStore = recoveryStore
            ?? Self.restoredRecoveryStore(from: defaults)
            ?? RecoveryStore()
        self.recoveryStore = activeRecoveryStore
        documentRegistry = suppliedDocumentRegistry ?? DocumentBufferRegistry()
        conflictResolver = suppliedConflictResolver
            ?? ConflictResolver(recoveryStore: activeRecoveryStore)
        documentMover = suppliedDocumentMover
            ?? DocumentMover(
                recoveryStore: activeRecoveryStore,
                fileManager: fileManager
            )
        self.workspaceCatalog = workspaceCatalog
            ?? WorkspaceCatalog(
                defaults: defaults,
                crashRecoveryJournal: crashRecoveryJournal
            )
        self.discoverySettings = discoverySettings
            ?? WorkspaceDiscoverySettings(defaults: defaults)
        let appStateReference = AppStateReference()
        let activeSearchIndex = searchIndex
            ?? (try? SQLiteSearchIndex(
                identityStore: documentRegistry.identityStore
            ))
            ?? EmptySearchIndex()
        workspaceIndexCoordinator = WorkspaceIndexCoordinator(
            catalog: self.workspaceCatalog,
            registry: documentRegistry,
            searchIndex: activeSearchIndex,
            scanner: WorkspaceScanner(
                fileManager: fileManager,
                identityStore: documentRegistry.identityStore
            ),
            eventReconciler: { [appStateReference] event, workspace in
                guard let appState = appStateReference.value else { return }
                await appState.handleWorkspaceEvent(event, in: workspace)
            }
        )

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
        appStateReference.value = self

        if let initialWorkspace {
            workspace = initialWorkspace
            beginWatching(initialWorkspace)
            legacyWorkspaceDescriptor = WorkspaceDescriptor(
                id: initialWorkspace.id,
                rootURL: initialWorkspace.rootURL
            )
        } else if let firstCatalogWorkspace = self.workspaceCatalog.workspaces.first {
            workspace = firstCatalogWorkspace
        } else {
            restoreWorkspaceIfAvailable()
        }

        if recoveryStore == nil,
           workspace != nil,
           !activeRecoveryStore.isSecurityScopedAccessActive {
            needsRecoveryAuthorization = true
        }

        crashRecoveryJournal.setStatusHandler { [weak self] documentID, errorMessage in
            Task { @MainActor [weak self] in
                self?.updateCrashRecoveryStatus(
                    documentID: documentID,
                    errorMessage: errorMessage
                )
            }
        }

        Task { try? await activeRecoveryStore.pruneExpired() }
        scheduleCrashRecoveryMigration()
        if workspace != nil || !self.workspaceCatalog.descriptors.isEmpty {
            refreshWorkspaceDiscovery()
        }
    }

    var isWorkspaceReady: Bool {
        primaryWorkspace != nil
    }

    /// Shared entry point for the global workspace coordinator. Stage 2's
    /// single-root watcher and Stage 5 navigation both use the same canonical
    /// buffer reconciliation rules.
    func reconcileWorkspaceEvent(
        _ event: WorkspaceEvent,
        in workspace: Workspace
    ) async {
        await handleWorkspaceEvent(event, in: workspace)
    }

    var workspaceRootPath: String? {
        primaryWorkspace?.workspace.rootURL.path
    }

    var workspaceTrees: [WorkspaceID: WorkspaceTreeSnapshot] {
        workspaceIndexCoordinator.treeSnapshots
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
            documentURLs: [],
            registry: documentRegistry,
            conflictResolver: conflictResolver,
            documentMover: documentMover
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

        do {
            try documentRegistry.identityStore.flushPendingPersistence()
        } catch {
            allSaved = false
            presentError(
                "Clio couldn’t finish saving document identity metadata.",
                underlying: error
            )
        }

        return allSaved
    }

    func chooseDefaultWorkspace() {
        let panel = configuredFolderPanel(
            title: "Use Documents/Clio",
            message: "Select your Documents folder. Clio will create or reuse a Clio folder inside it.",
            prompt: "Use Documents"
        )

        if let physicalHomeURL = FileManager.default.homeDirectory(forUser: NSUserName()) {
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
            let bookmarks = try makeDefaultWorkspaceBookmarks(in: parentURL)
            try activateRecovery(from: bookmarks.recovery)
            let resolution = try Workspace.resolveSecurityScopedBookmark(bookmarks.workspace)
            let descriptor = try workspaceCatalog.addAuthorizedFolder(
                resolution.url,
                bookmark: bookmarks.workspace
            )
            workspace = workspaceCatalog.workspace(id: descriptor.id)
            legacyWorkspaceDescriptor = nil
            defaults.removeObject(forKey: Keys.workspaceBookmark)
            defaults.removeObject(forKey: Keys.legacyWorkspaceID)
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
            let descriptor = try workspaceCatalog.addAuthorizedFolder(selectedURL)
            defer { selectedURL.stopAccessingSecurityScopedResource() }
            if workspace == nil {
                workspace = workspaceCatalog.workspace(id: descriptor.id)
            }
            workspaceErrorMessage = nil
            activateUnreadySessions()
            refreshWorkspaceDiscovery()
            if defaults.data(forKey: Keys.recoveryBookmark) == nil {
                chooseRecoveryFolder()
            }
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
        let policy = discoverySettings.policy
        isRefreshingWorkspaces = true
        discoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.workspaceIndexCoordinator.synchronize(policy: policy)
                try Task.checkCancellation()
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
        return await workspaceIndexCoordinator.search(
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
        return await workspaceIndexCoordinator.quickOpen(
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

        if let descriptor = descriptor(containing: fileURL),
           let authorizedWorkspace = workspace(for: descriptor.id) {
            do {
                try openDocument(
                    at: fileURL,
                    workspace: authorizedWorkspace,
                    descriptor: descriptor,
                    documentID: discoveredDocumentID(
                        workspaceID: descriptor.id,
                        relativePath: authorizedWorkspace.relativePath(for: fileURL)
                    ),
                    in: window
                )
            } catch {
                presentError("Clio couldn’t open that document.", underlying: error)
            }
            return
        }

        if routeToExistingDocument(at: fileURL) != nil { return }
        let tab = EditorSession(openingMode: .newDocument)
        do {
            try tab.activateExternal(
                documentURL: fileURL,
                registry: documentRegistry,
                conflictResolver: conflictResolver,
                documentMover: documentMover
            )
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
        do {
            let tab = try openDocument(
                at: fileURL,
                workspace: workspace,
                descriptor: descriptor,
                documentID: result.documentID,
                applying: matchViewport,
                in: window
            )
            if let matchViewport { tab.updateViewport(matchViewport) }
        } catch {
            presentError("Clio couldn’t open that search result.", underlying: error)
        }
    }

    func openWorkspaceFile(
        documentID: DocumentID,
        workspaceID: WorkspaceID,
        relativePath: String,
        from window: EditorWindowSession
    ) {
        guard let descriptor = workspaceDescriptors.first(where: { $0.id == workspaceID }),
              let workspace = workspace(for: workspaceID) else { return }
        let fileURL = descriptor.rootURL.appendingPathComponent(relativePath)
        do {
            try openDocument(
                at: fileURL,
                workspace: workspace,
                descriptor: descriptor,
                documentID: documentID,
                in: window
            )
        } catch {
            presentError("Clio couldn’t open that document.", underlying: error)
        }
    }

    func dragPayload(
        documentID: DocumentID,
        workspaceID: WorkspaceID,
        relativePath: String
    ) -> String? {
        guard let locator = try? DocumentLocator(
            workspaceID: workspaceID,
            relativePath: relativePath
        ), let data = try? JSONEncoder().encode(
            DocumentDragPayload(documentID: documentID, locator: locator)
        ) else { return nil }
        return data.base64EncodedString()
    }

    @discardableResult
    func moveDocument(
        dragPayload: String,
        toWorkspaceID destinationWorkspaceID: WorkspaceID,
        parentRelativePath: String
    ) -> Bool {
        guard let data = Data(base64Encoded: dragPayload),
              let payload = try? JSONDecoder().decode(DocumentDragPayload.self, from: data),
              let sourceWorkspace = workspace(for: payload.locator.workspaceID),
              let destinationWorkspace = workspace(for: destinationWorkspaceID) else {
            return false
        }

        do {
            let sourceURL = try sourceWorkspace.fileURL(for: payload.locator)
            let destinationRelativePath = [
                parentRelativePath,
                sourceURL.lastPathComponent,
            ].filter { !$0.isEmpty }.joined(separator: "/")
            let destinationLocator = try DocumentLocator(
                workspaceID: destinationWorkspaceID,
                relativePath: destinationRelativePath
            )
            guard payload.locator != destinationLocator else { return false }
        } catch {
            return false
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sourceURL = try sourceWorkspace.fileURL(for: payload.locator)
                let document = try self.documentRegistry.open(
                    sourceURL,
                    in: sourceWorkspace,
                    preferredID: payload.documentID
                )
                var outcome = try await self.documentMover.move(
                    document,
                    from: sourceWorkspace,
                    to: destinationWorkspace,
                    parentRelativePath: parentRelativePath,
                    registry: self.documentRegistry
                )
                if case let .collision(collision) = outcome {
                    let choice = self.collisionChoice(for: collision)
                    guard choice != .cancel else { return }
                    outcome = try await self.documentMover.move(
                        document,
                        from: sourceWorkspace,
                        to: destinationWorkspace,
                        parentRelativePath: parentRelativePath,
                        collisionChoice: choice,
                        registry: self.documentRegistry
                    )
                }
                if case let .completed(destination) = outcome {
                    do {
                        try await self.workspaceIndexCoordinator.recordCommittedMove(
                            documentID: document.id,
                            from: payload.locator,
                            to: destination
                        )
                    } catch {
                        self.presentError(
                            "The document moved safely, but Clio couldn’t update navigation immediately.",
                            underlying: error
                        )
                        self.refreshWorkspaceDiscovery()
                    }
                }
            } catch {
                self.presentError("Clio couldn’t move that document.", underlying: error)
            }
        }
        return true
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

    func dismissTransientMessage() {
        workspaceErrorMessage = nil
        if pendingCrashRecoveryCount == 0,
           !isCrashRecoveryDurabilityCompromised {
            crashRecoveryMessage = nil
        }
    }

    /// Commits the already-confirmed Trash action. Kept separate from the
    /// alert so the data-safety boundary is deterministic and testable.
    @discardableResult
    func commitMoveToTrash(
        _ tab: EditorSession,
        from window: EditorWindowSession
    ) -> Bool {
        let priorLocator = tab.locator
        let priorURL = tab.fileURL
        do {
            // DocumentMover flushes first and only detaches the canonical
            // buffer after the Trash operation succeeds.
            try tab.moveToTrash()
            window.closeAfterSuccessfulFileMutation(tabID: tab.id)
            if let priorLocator, let priorURL {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.workspaceIndexCoordinator.apply([
                            WorkspaceEvent(
                                workspaceID: priorLocator.workspaceID,
                                kind: .deleted,
                                fileURL: priorURL,
                                origin: .clio
                            ),
                        ])
                    } catch {
                        self.presentError(
                            "The document is in Trash, but Clio couldn’t update navigation immediately.",
                            underlying: error
                        )
                        self.refreshWorkspaceDiscovery()
                    }
                }
            }
            return true
        } catch {
            presentError(
                "Clio couldn’t move that document to the Trash. The tab remains open with its canonical buffer.",
                underlying: error
            )
            return false
        }
    }

    func chooseRecoveryFolder() {
        let panel = configuredFolderPanel(
            title: "Choose Clio Recovery Folder",
            message: "Select or create “Clio Recovery” in Documents. Clio never replaces a conflicted version until its recovery copy is written here.",
            prompt: "Use Recovery Folder"
        )
        panel.directoryURL = RecoveryStore.preferredURL
        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            needsRecoveryAuthorization = true
            workspaceErrorMessage = "Authorize a recovery folder before resolving external edits or replacing files."
            return
        }
        defer { selectedURL.stopAccessingSecurityScopedResource() }
        do {
            let bookmark = try Workspace.makeSecurityScopedBookmark(for: selectedURL)
            try activateRecovery(from: bookmark)
            workspaceErrorMessage = nil
        } catch {
            needsRecoveryAuthorization = true
            presentError(
                "Clio couldn’t retain access to that recovery folder. Choose it again.",
                underlying: error
            )
        }
    }
}

@MainActor
private final class AppStateReference {
    weak var value: AppState?
}

private actor EmptySearchIndex: SearchIndexing {
    func rebuild(
        workspaces _: [WorkspaceDescriptor],
        policy _: DiscoveryPolicy
    ) async throws {}

    func apply(_: [WorkspaceEvent]) async throws {}

    func quickOpen(
        _: WorkspaceSearchQuery
    ) async -> AsyncThrowingStream<SearchBatch, Error> {
        emptyStream()
    }

    func search(
        _: WorkspaceSearchQuery
    ) async -> AsyncThrowingStream<SearchBatch, Error> {
        emptyStream()
    }

    private func emptyStream() -> AsyncThrowingStream<SearchBatch, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(SearchBatch(results: [], isFinal: true))
            continuation.finish()
        }
    }
}

extension Notification.Name {
    static let clioRequestedExport = Notification.Name("ClioRequestedExport")
}

enum ClioExportNotificationKey {
    static let arguments = "ClioExportArguments"
}

private extension AppState {
    struct DocumentDragPayload: Codable {
        let documentID: DocumentID
        let locator: DocumentLocator
    }

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

    func collisionChoice(for collision: FileCollision) -> CollisionChoice {
        let alert = NSAlert()
        alert.messageText = "A document already exists at \(collision.proposedLocator.relativePath)."
        alert.informativeText = "Cancel, replace it after preserving recovery data, or keep both with a numbered name."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .replace
        case .alertThirdButtonReturn: return .keepBoth
        default: return .cancel
        }
    }

    func activate(_ session: EditorSession) {
        if session.hasPreferredDocument {
            let requestedWorkspace = session.restoredWorkspaceID.flatMap(workspace(for:))
            guard let requestedWorkspaceID = session.restoredWorkspaceID,
                  let requestedPath = session.restoredRelativePath,
                  let requestedWorkspace else {
                session.activateUnresolvedRestoration(
                    in: requestedWorkspace,
                    registry: documentRegistry,
                    conflictResolver: conflictResolver,
                    documentMover: documentMover
                )
                return
            }
            do {
                let locator = try DocumentLocator(
                    workspaceID: requestedWorkspaceID,
                    relativePath: requestedPath
                )
                let requestedURL = try requestedWorkspace.fileURL(for: locator)
                guard fileManager.fileExists(atPath: requestedURL.path) else {
                    session.activateUnresolvedRestoration(
                        in: requestedWorkspace,
                        registry: documentRegistry,
                        conflictResolver: conflictResolver,
                        documentMover: documentMover
                    )
                    return
                }
                try session.activate(
                    documentURL: requestedURL,
                    in: requestedWorkspace,
                    workspaceID: requestedWorkspaceID,
                    registry: documentRegistry,
                    conflictResolver: conflictResolver,
                    documentMover: documentMover,
                    preferredDocumentID: session.documentID
                )
            } catch {
                session.activateUnresolvedRestoration(
                    in: requestedWorkspace,
                    registry: documentRegistry,
                    conflictResolver: conflictResolver,
                    documentMover: documentMover,
                    underlyingError: error
                )
            }
            return
        }

        guard let primaryWorkspace else { return }

        if session.openingMode == .newDocument {
            session.activate(
                in: primaryWorkspace.workspace,
                workspaceID: primaryWorkspace.descriptor.id,
                documentURLs: [],
                registry: documentRegistry,
                conflictResolver: conflictResolver,
                documentMover: documentMover
            )
            return
        }

        do {
            let openDocumentIDs = Set(
                editorSessions
                    .filter { $0 !== session }
                    .compactMap(\.document?.id)
            )
            let candidates = try workspaceDescriptors.flatMap { descriptor -> [(URL, WorkspaceDescriptor, Workspace)] in
                guard let candidateWorkspace = workspace(for: descriptor.id) else { return [] }
                return try candidateWorkspace.documentURLs().map {
                    ($0, descriptor, candidateWorkspace)
                }
            }.sorted {
                let left = (try? $0.0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                let right = (try? $1.0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                if left != right { return left > right }
                return $0.0.path.localizedStandardCompare($1.0.path) == .orderedAscending
            }

            var didActivate = false
            for candidate in candidates {
                let document = try documentRegistry.open(
                    candidate.0,
                    in: candidate.2,
                    preferredID: discoveredDocumentID(
                        workspaceID: candidate.1.id,
                        relativePath: candidate.2.relativePath(for: candidate.0)
                    )
                )
                guard !openDocumentIDs.contains(document.id) else { continue }
                session.activate(
                    document: document,
                    in: candidate.2,
                    workspaceID: candidate.1.id,
                    registry: documentRegistry,
                    conflictResolver: conflictResolver,
                    documentMover: documentMover
                )
                didActivate = true
                break
            }
            if !didActivate {
                session.activate(
                    in: primaryWorkspace.workspace,
                    workspaceID: primaryWorkspace.descriptor.id,
                    documentURLs: [],
                    registry: documentRegistry,
                    conflictResolver: conflictResolver,
                    documentMover: documentMover
                )
                session.resolveAsNewDocument()
            }
        } catch {
            session.activate(
                in: primaryWorkspace.workspace,
                workspaceID: primaryWorkspace.descriptor.id,
                documentURLs: [],
                registry: documentRegistry,
                conflictResolver: conflictResolver,
                documentMover: documentMover
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
        applying viewport: EditorViewportState? = nil,
        in window: EditorWindowSession
    ) throws -> EditorSession {
        let document = try documentRegistry.open(
            fileURL,
            in: workspace,
            preferredID: documentID
        )
        if let existing = routeToExistingDocument(
            documentID: document.id,
            applying: viewport
        ) {
            return existing
        }
        let tab = EditorSession(
            openingMode: .mostRecent,
            restoredDocumentID: document.id
        )
        tab.activate(
            document: document,
            in: workspace,
            workspaceID: descriptor.id,
            registry: documentRegistry,
            conflictResolver: conflictResolver,
            documentMover: documentMover
        )
        if let viewport { tab.updateViewport(viewport) }
        editorSessions.append(tab)
        window.append(tab)
        return tab
    }

    @discardableResult
    func routeToExistingDocument(
        documentID: DocumentID,
        applying viewport: EditorViewportState? = nil
    ) -> EditorSession? {
        for window in editorWindows {
            if let tab = window.tabs.first(where: { $0.documentID == documentID }) {
                if let viewport { tab.updateViewport(viewport) }
                window.focus(tabID: tab.id)
                return tab
            }
        }
        return nil
    }

    @discardableResult
    func routeToExistingDocument(
        at fileURL: URL,
        applying viewport: EditorViewportState? = nil
    ) -> EditorSession? {
        let identity = PhysicalFileIdentity.authorizedFile(at: fileURL)
        for window in editorWindows {
            if let tab = window.tabs.first(where: { candidate in
                guard let candidateURL = candidate.fileURL else { return false }
                return PhysicalFileIdentity.authorizedFile(at: candidateURL) == identity
            }) {
                if let viewport { tab.updateViewport(viewport) }
                window.focus(tabID: tab.id)
                return tab
            }
        }
        return nil
    }

    func discoveredDocumentID(
        workspaceID: WorkspaceID,
        relativePath: String
    ) -> DocumentID? {
        workspaceTrees[workspaceID]?.files.first {
            $0.relativePath == relativePath
        }?.documentID
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
            tab.adoptAuthorizedWorkspace(authorizedWorkspace)
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
        guard let sourceURL = tab.fileURL else { return }

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
        let sourceLocator = tab.locator
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            do {
                let outcome = try await tab.rename(to: proposedName)
                if case let .completed(destination) = outcome {
                    if let sourceLocator {
                        do {
                            try await self.workspaceIndexCoordinator.recordCommittedMove(
                                documentID: tab.documentID,
                                from: sourceLocator,
                                to: destination
                            )
                        } catch {
                            self.presentError(
                                "The document was renamed, but Clio couldn’t update navigation immediately.",
                                underlying: error
                            )
                            self.refreshWorkspaceDiscovery()
                        }
                    } else {
                        self.refreshWorkspaceDiscovery()
                    }
                }
            } catch {
                self.presentError("Clio couldn’t rename that document.", underlying: error)
            }
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

        commitMoveToTrash(tab, from: window)
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
        static let legacyWorkspaceID = "workspace.securityScopedBookmark.id"
        static let recoveryBookmark = "recovery.securityScopedBookmark"
    }

    func scheduleCrashRecoveryMigration() {
        guard crashRecoveryTask == nil else {
            crashRecoveryRescanRequested = true
            return
        }
        crashRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.crashRecoveryRescanRequested = false
                await self.recoverPendingCrashBuffers()
            } while self.crashRecoveryRescanRequested
            self.crashRecoveryTask = nil
        }
    }

    func updateCrashRecoveryStatus(
        documentID: DocumentID,
        errorMessage: String?
    ) {
        if let errorMessage {
            nonDurableCrashDocuments.insert(documentID)
            isCrashRecoveryDurabilityCompromised = true
            crashRecoveryMessage = "Clio could not durably protect the latest edit (\(errorMessage)). Keep the document open and choose a writable location."
            return
        }
        guard nonDurableCrashDocuments.remove(documentID) != nil else { return }
        isCrashRecoveryDurabilityCompromised = !nonDurableCrashDocuments.isEmpty
        if !isCrashRecoveryDurabilityCompromised {
            crashRecoveryMessage = "Durable crash recovery is active again."
        }
    }

    func recoverPendingCrashBuffers() async {
        let journal = crashRecoveryJournal
        let records: [CrashRecoveryRecord]
        do {
            records = try await Task.detached(priority: .utility) {
                try journal.validRecords()
            }.value
        } catch {
            crashRecoveryMessage = "Clio could not inspect its crash-recovery journal. No journal files were removed."
            return
        }

        var pending = 0
        var recovered = 0
        for record in records {
            let targetIsAuthorized = record.targetURL.map {
                workspace?.contains($0) == true
            } ?? false
            let alreadyCanonical = await Task.detached(priority: .utility) {
                guard targetIsAuthorized,
                      let targetURL = record.targetURL,
                      let values = try? targetURL.resourceValues(forKeys: [
                          .isRegularFileKey,
                          .isSymbolicLinkKey,
                      ]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let revision = try? DocumentRevisionReader.revision(at: targetURL) else {
                    return false
                }
                return revision.byteCount == Int64(record.data.count)
                    && revision.contentDigest == record.contentDigest
            }.value
            if alreadyCanonical {
                journal.remove(recordID: record.id)
                continue
            }

            do {
                _ = try await recoveryStore.preserve(
                    documentID: record.documentID,
                    filename: record.filename,
                    data: record.data,
                    sourceModificationDate: record.createdAt
                )
                journal.remove(recordID: record.id)
                recovered += 1
            } catch {
                pending += 1
            }
        }

        pendingCrashRecoveryCount = pending
        recoveredCrashBufferCount += recovered
        if pending > 0 {
            crashRecoveryMessage = "Clio found \(pending) unsaved crash-recovery \(pending == 1 ? "buffer" : "buffers"). Authorize a writable recovery folder; the app-owned journal remains intact."
        } else if recovered > 0 {
            crashRecoveryMessage = "Clio recovered \(recovered) unsaved \(recovered == 1 ? "buffer" : "buffers") into Clio Recovery."
        } else {
            crashRecoveryMessage = nil
        }
    }

    func restoreWorkspaceIfAvailable() {
        guard let bookmark = defaults.data(forKey: Keys.workspaceBookmark) else {
            return
        }

        do {
            let legacyID = persistentLegacyWorkspaceID()
            try activateWorkspace(
                from: bookmark,
                workspaceID: legacyID,
                flushingCurrentDocuments: false
            )
            if let restoredWorkspace = workspace {
                let descriptor = try workspaceCatalog.addAuthorizedFolder(
                    restoredWorkspace.rootURL,
                    bookmark: bookmark,
                    preferredID: legacyID
                )
                workspace = workspaceCatalog.workspace(id: descriptor.id)
                legacyWorkspaceDescriptor = nil
                stopLegacyWorkspaceWatcher()
                refreshWorkspaceDiscovery()
                defaults.removeObject(forKey: Keys.workspaceBookmark)
                defaults.removeObject(forKey: Keys.legacyWorkspaceID)
            }
        } catch {
            let needsNewAuthorization = (error as? WorkspaceActivationError)?
                .requiresNewAuthorization ?? false

            if needsNewAuthorization {
                defaults.removeObject(forKey: Keys.workspaceBookmark)
                defaults.removeObject(forKey: Keys.legacyWorkspaceID)
            }

            presentError(
                needsNewAuthorization
                    ? "Clio couldn’t reopen its workspace. Choose the folder again to restore access."
                    : "Clio still has the workspace grant, but couldn’t read the folder. Try again or choose another folder.",
                underlying: error
            )
        }
    }

    static func restoredRecoveryStore(from defaults: UserDefaults) -> RecoveryStore? {
        guard let bookmark = defaults.data(forKey: Keys.recoveryBookmark),
              let restored = try? RecoveryAuthorization.restore(bookmark: bookmark) else {
            return nil
        }
        defaults.set(restored.bookmarkToPersist, forKey: Keys.recoveryBookmark)
        return restored.store
    }

    func activateRecovery(from bookmark: Data) throws {
        let restored = try RecoveryAuthorization.restore(bookmark: bookmark)
        recoveryStore = restored.store
        conflictResolver = ConflictResolver(recoveryStore: restored.store)
        documentMover = DocumentMover(
            recoveryStore: restored.store,
            fileManager: fileManager
        )
        for session in editorSessions {
            session.rebindServices(
                conflictResolver: conflictResolver,
                documentMover: documentMover
            )
        }
        defaults.set(restored.bookmarkToPersist, forKey: Keys.recoveryBookmark)
        needsRecoveryAuthorization = false
        scheduleCrashRecoveryMigration()
    }

    func activateWorkspace(
        from bookmark: Data,
        workspaceID: WorkspaceID? = nil,
        flushingCurrentDocuments: Bool = true
    ) throws {
        if flushingCurrentDocuments {
            try flushEditorSessionsBeforeWorkspaceChange()
        }

        let resolution: Workspace.BookmarkResolution
        let newWorkspace: Workspace

        do {
            resolution = try Workspace.resolveSecurityScopedBookmark(bookmark)
            newWorkspace = try Workspace(
                id: workspaceID ?? persistentLegacyWorkspaceID(),
                rootURL: resolution.url,
                crashRecoveryJournal: crashRecoveryJournal
            )
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
        beginWatching(newWorkspace)
        let descriptor = WorkspaceDescriptor(id: newWorkspace.id, rootURL: newWorkspace.rootURL)
        legacyWorkspaceDescriptor = descriptor
        for session in editorSessions {
            activate(session)
        }

        workspaceErrorMessage = nil
        defaults.set(bookmarkToStore, forKey: Keys.workspaceBookmark)
        scheduleCrashRecoveryMigration()
        defaults.set(descriptor.id.rawValue.uuidString, forKey: Keys.legacyWorkspaceID)
        refreshWorkspaceDiscovery()
    }

    func persistentLegacyWorkspaceID() -> WorkspaceID {
        if let rawValue = defaults.string(forKey: Keys.legacyWorkspaceID),
           let uuid = UUID(uuidString: rawValue) {
            return WorkspaceID(rawValue: uuid)
        }
        let id = WorkspaceID()
        defaults.set(id.rawValue.uuidString, forKey: Keys.legacyWorkspaceID)
        return id
    }

    func flushEditorSessionsBeforeWorkspaceChange() throws {
        for session in editorSessions {
            try session.flush()
        }
    }

    func beginWatching(_ workspace: Workspace) {
        stopLegacyWorkspaceWatcher()
        let watcher = WorkspaceWatcher(
            workspaceID: workspace.id,
            rootURL: workspace.rootURL
        )
        workspaceWatcher = watcher
        workspaceWatchTask = Task { @MainActor [weak self, weak workspace] in
            let events = await watcher.events()
            for await event in events {
                guard !Task.isCancelled,
                      let self,
                      let workspace,
                      self.workspace === workspace else { break }
                await self.handleWorkspaceEvent(event, in: workspace)
            }
        }
    }

    func stopLegacyWorkspaceWatcher() {
        workspaceWatchTask?.cancel()
        workspaceWatchTask = nil
        workspaceWatcher = nil
    }

    func handleWorkspaceEvent(
        _ event: WorkspaceEvent,
        in workspace: Workspace
    ) async {
        do {
            switch event.kind {
            case .modified:
                guard let url = event.fileURL,
                      let document = documentRegistry.document(at: url, in: workspace) else {
                    return
                }
                try await documentRegistry.withSettledDocumentIO(for: document.id) {
                    guard document.fileURL?.standardizedFileURL
                            == url.standardizedFileURL else { return }
                    try await workspace.reconcileExternalChangeInBackground(for: document)
                    if document.conflict != nil {
                        documentRegistry.cancelAutosave(for: document.id)
                    } else if document.fileURL != nil {
                        documentRegistry.updateAliases(for: document, in: workspace)
                    }
                }

            case .moved:
                guard let oldURL = event.previousFileURL,
                      let newURL = event.fileURL,
                      let document = event.documentID.flatMap({
                          documentRegistry.document(withID: $0)
                      }) ?? documentRegistry.document(at: oldURL, in: workspace) else {
                    return
                }
                try await documentRegistry.withSettledDocumentIO(for: document.id) {
                    guard document.fileURL?.standardizedFileURL
                            == oldURL.standardizedFileURL else { return }
                    try await workspace.reconcileExternalMoveInBackground(
                        for: document,
                        from: oldURL,
                        to: newURL
                    )
                    if let oldLocator = try? workspace.locator(for: oldURL) {
                        documentRegistry.removeLocator(oldLocator, for: document.id)
                    }
                    documentRegistry.updateAliases(for: document, in: workspace)
                    documentRegistry.retarget(document, to: workspace)
                    if document.conflict != nil {
                        documentRegistry.cancelAutosave(for: document.id)
                    }
                }

            case .deleted:
                guard let url = event.fileURL,
                      let document = documentRegistry.document(at: url, in: workspace) else {
                    return
                }
                let needsConflictDetachment = try await documentRegistry
                    .withSettledDocumentIO(for: document.id) {
                        let locator = try workspace.locator(for: url)
                        guard document.fileURL?.standardizedFileURL
                                == url.standardizedFileURL else {
                            // A second overlapping watcher may report the source path
                            // after another watcher already retargeted this buffer.
                            documentRegistry.removeLocator(locator, for: document.id)
                            return false
                        }
                        documentRegistry.cancelAutosave(for: document.id)
                        guard document.conflict == nil else { return true }
                        try await workspace.checkpointCrashRecoveryInBackground(
                            for: document,
                            reason: .externalDeletion
                        )
                        document.markUnbacked(previous: locator)
                        documentRegistry.detach(document.id, from: locator)
                        return false
                    }
                if needsConflictDetachment {
                    try await conflictResolver.detachAfterExternalDeletion(
                        document,
                        workspace: workspace,
                        registry: documentRegistry
                    )
                }

            case .accessLost, .error:
                workspaceErrorMessage = "Clio lost access to the workspace. Your open buffers remain in memory."

            case .rescanRequired, .rootChanged:
                for document in documentRegistry.openDocuments {
                    let needsConflictDetachment = try await documentRegistry
                        .withSettledDocumentIO(for: document.id) {
                            guard let url = document.fileURL,
                                  workspace.contains(url) else { return false }
                            if !(await workspace.fileExistsInBackground(at: url)) {
                                let locator = try workspace.locator(for: url)
                                documentRegistry.cancelAutosave(for: document.id)
                                guard document.conflict == nil else { return true }
                                try await workspace.checkpointCrashRecoveryInBackground(
                                    for: document,
                                    reason: .externalDeletion
                                )
                                document.markUnbacked(previous: locator)
                                documentRegistry.detach(document.id, from: locator)
                                return false
                            }
                            try await workspace.reconcileExternalChangeInBackground(for: document)
                            if document.conflict != nil {
                                documentRegistry.cancelAutosave(for: document.id)
                            } else if document.fileURL != nil {
                                documentRegistry.updateAliases(for: document, in: workspace)
                            }
                            return false
                        }
                    if needsConflictDetachment {
                        try await conflictResolver.detachAfterExternalDeletion(
                            document,
                            workspace: workspace,
                            registry: documentRegistry
                        )
                    }
                }

            case .created:
                guard let url = event.fileURL,
                      let document = documentRegistry.document(at: url, in: workspace) else {
                    return
                }
                // A path may be recreated while a correlated delete is still
                // pending. Treat it as an external revision before autosave
                // can resume against stale bytes.
                try await documentRegistry.withSettledDocumentIO(for: document.id) {
                    guard document.fileURL?.standardizedFileURL
                            == url.standardizedFileURL else { return }
                    try await workspace.reconcileExternalChangeInBackground(for: document)
                    if document.conflict != nil {
                        documentRegistry.cancelAutosave(for: document.id)
                    } else if document.fileURL != nil {
                        documentRegistry.updateAliases(for: document, in: workspace)
                    }
                }
            }
        } catch {
            presentError(
                "Clio detected a workspace change but couldn’t safely reconcile it.",
                underlying: error
            )
        }
    }

    func makeDefaultWorkspaceBookmarks(
        in selectedParentURL: URL
    ) throws -> (workspace: Data, recovery: Data) {
        defer {
            // App Sandbox starts access for NSOpenPanel URLs on Clio's
            // behalf. This balances that temporary Powerbox scope exactly
            // once; bookmark-resolved URLs are started explicitly elsewhere.
            selectedParentURL.stopAccessingSecurityScopedResource()
        }

        let parentURL = selectedParentURL.standardizedFileURL
        let grants = try RecoveryAuthorization.createDefaultGrants(
            in: parentURL,
            fileManager: fileManager
        )
        return (grants.workspaceBookmark, grants.recoveryBookmark)
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
