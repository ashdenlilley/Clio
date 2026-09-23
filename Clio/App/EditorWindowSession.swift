import AppKit
import Foundation
import Observation

enum CommandPaletteMode: String, Codable, Hashable, Sendable {
    case commands
    case search
}

struct ClioCommandDescriptor: Identifiable, Hashable, Sendable {
    let command: ClioCommandID
    let title: String
    let detail: String
    let systemImage: String

    var id: ClioCommandID { command }

    static let all: [Self] = [
        Self(command: .new, title: "New Document", detail: "Open a blank tab", systemImage: "square.and.pencil"),
        Self(command: .open, title: "Open…", detail: "Choose a Markdown or text file", systemImage: "doc"),
        Self(command: .search, title: "Search Workspaces", detail: "Search every bookmarked folder", systemImage: "magnifyingglass"),
        Self(command: .rename, title: "Rename Document", detail: "Rename the current file", systemImage: "pencil"),
        Self(command: .delete, title: "Move Document to Trash", detail: "Delete the current file safely", systemImage: "trash"),
        Self(command: .reveal, title: "Reveal in Finder", detail: "Show the current file", systemImage: "finder"),
        Self(command: .folder, title: "Add Workspace Folder…", detail: "Bookmark another searchable folder", systemImage: "folder.badge.plus"),
        Self(command: .export, title: "Export…", detail: "Export the current document", systemImage: "square.and.arrow.up"),
        Self(command: .focus, title: "Toggle Focus Mode", detail: "Dim text away from the caret", systemImage: "scope"),
        Self(command: .typewriter, title: "Toggle Typewriter Scrolling", detail: "Keep the caret near its anchor", systemImage: "text.cursor"),
        Self(command: .sidebar, title: "Toggle Sidebar", detail: "Show or hide navigation", systemImage: "sidebar.left"),
        Self(command: .settings, title: "Settings…", detail: "Configure the writing workspace", systemImage: "gearshape"),
    ]
}

@MainActor
@Observable
final class EditorWindowSession: Identifiable {
    static let writingCollapseDelay: Duration = .seconds(5)
    static let temporarySidebarDelay: Duration = .seconds(3.5)

    let id: UUID
    private(set) var tabs: [EditorSession]
    var activeTabID: UUID? {
        didSet {
            if activeTabID != oldValue { exportPresentation.cancel() }
        }
    }
    private(set) var exportPresentation = DocumentExportPresentation()
    var isSidebarVisible: Bool
    var isSidebarPinned: Bool
    let motion: WindowMotionAdapter
    let minimap = EditorMinimapModel()
    var isSettingsPresented = false
    var isFullScreenEnabled: Bool
    private(set) var isSidebarInteractionActive = false

    var isPalettePresented = false
    var paletteMode = CommandPaletteMode.commands
    var paletteQuery = ""
    var paletteSource = ClioCommandSource.palette
    private(set) var paletteAnchor: CGRect?
    @ObservationIgnored private var restoreSlashLiteral: (@MainActor (String) -> Void)?
    var workspaceFilter: WorkspaceID?
    var searchResults: [WorkspaceSearchResult] = []
    var paletteErrorMessage: String?
    var isSearching = false
    private(set) var paletteSelectionIndex = 0

    @ObservationIgnored
    private var palettePointerAtPresentation = NSPoint.zero
    private(set) var focusRestorationGeneration = 0

    @ObservationIgnored
    private weak var appState: AppState?

    @ObservationIgnored
    private var searchTask: Task<Void, Never>?

    /// The assisted match for `intentQuery`, when one was found. Held
    /// alongside the query it belongs to so a stale answer can never be
    /// applied to text the writer has since changed.
    private(set) var intentResult: CommandIntentResult?
    private(set) var intentQuery = ""
    private(set) var isResolvingIntent = false

    @ObservationIgnored
    private var intentTask: Task<Void, Never>?

    @ObservationIgnored
    private var cachedLiteralNeedle: String?
    @ObservationIgnored
    private var cachedLiteralCommands: [ClioCommandDescriptor] = []

    @ObservationIgnored
    private var horizontalGestureDistance: CGFloat = 0

    @ObservationIgnored
    private var isSidebarHovered = false

    @ObservationIgnored
    private var isSidebarFocused = false

    init(
        request: EditorWindowRequest,
        sidebarVisibleByDefault: Bool = true,
        sidebarPinnedByDefault: Bool = false
    ) {
        id = request.id
        isFullScreenEnabled = request.restoration?.isFullScreen
            ?? request.isFullScreen
        let sidebarVisible = request.restoration?.isSidebarVisible ?? sidebarVisibleByDefault
        let sidebarPinned = request.restoration?.isSidebarPinned ?? sidebarPinnedByDefault
        isSidebarVisible = sidebarVisible
        isSidebarPinned = sidebarPinned
        motion = WindowMotionAdapter(
            sidebarVisible: sidebarVisible,
            pinned: sidebarPinned
        )

        var restoration = request.restoration
        restoration?.normalize()
        if let restoration, !restoration.tabs.isEmpty {
            tabs = restoration.tabs.map { tab in
                EditorSession(
                    id: tab.id,
                    openingMode: tab.locator == nil && tab.externalFileBookmark == nil
                        ? .newDocument
                        : .mostRecent,
                    restoredLocator: tab.locator,
                    restoredViewport: tab.viewport,
                    restoredPreferredFilename: tab.preferredFilename,
                    restoredDocumentID: tab.documentID,
                    restoredExternalFileBookmark: tab.externalFileBookmark,
                    restoredExternalFileURL: tab.externalFileURL,
                    startInFullScreen: restoration.isFullScreen
                )
            }
            activeTabID = restoration.activeTabID
                .flatMap { requested in tabs.contains(where: { $0.id == requested }) ? requested : nil }
                ?? tabs.first?.id
        } else {
            let tab = EditorSession(
                openingMode: request.openingMode,
                restoredRelativePath: request.relativePath,
                startInFullScreen: request.isFullScreen
            )
            tabs = [tab]
            activeTabID = tab.id
        }
        exportPresentation.attach(to: self)
        motion.sidebarIntentChanged = { [weak self] visible in
            if self?.isSidebarVisible != visible { self?.isSidebarVisible = visible }
        }
        motion.documentIdentity = { [weak self] in self?.activeTabID }
    }

    deinit {
        searchTask?.cancel()
        intentTask?.cancel()
    }

    var activeTab: EditorSession? {
        guard let activeTabID else { return tabs.first }
        return tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    /// The palette's own substring match. Instant, offline, and unchanged:
    /// it decides the list whenever it finds anything at all.
    ///
    /// Memoized on the command token. SwiftUI reads this once per row while the
    /// palette is open, and each miss costs three locale-aware substring
    /// searches per command; recomputing it per row turned one keystroke into
    /// hundreds of them. The cache is `@ObservationIgnored`, so reading
    /// `paletteQuery` above is still what registers the dependency.
    var literalCommands: [ClioCommandDescriptor] {
        let needle = ClioCommandParser.commandToken(in: paletteQuery)
        if let cachedLiteralNeedle, cachedLiteralNeedle == needle {
            return cachedLiteralCommands
        }
        let matches: [ClioCommandDescriptor]
        if needle.isEmpty {
            matches = ClioCommandDescriptor.all
        } else {
            matches = ClioCommandDescriptor.all.filter {
                $0.command.rawValue.localizedCaseInsensitiveContains(needle)
                    || $0.title.localizedCaseInsensitiveContains(needle)
                    || $0.detail.localizedCaseInsensitiveContains(needle)
            }
        }
        cachedLiteralNeedle = needle
        cachedLiteralCommands = matches
        return matches
    }

    /// Falls back to an assisted match only where the palette would otherwise
    /// show nothing. Typing a command name never reaches the network, and a
    /// writer who is offline or has the feature off sees exactly what they saw
    /// before: an empty list.
    var filteredCommands: [ClioCommandDescriptor] {
        let literal = literalCommands
        guard literal.isEmpty, let intentResult, intentQuery == paletteQuery else {
            return literal
        }
        let byID = Dictionary(
            uniqueKeysWithValues: ClioCommandDescriptor.all.map { ($0.command, $0) }
        )
        return intentResult.ranked.compactMap { byID[$0] }
    }

    /// Whether the visible list came from an assisted match rather than from
    /// the writer's own typing. The palette says so rather than presenting a
    /// guess as if it were a literal match.
    var isShowingIntentMatch: Bool {
        literalCommands.isEmpty && intentResult != nil && intentQuery == paletteQuery
    }

    /// The slash name a palette row shows, carrying any argument an assisted
    /// match filled in so "send this to my editor in Word" reads back as
    /// `/export docx` before the writer commits to it.
    func paletteRowTitle(for descriptor: ClioCommandDescriptor) -> String {
        guard isShowingIntentMatch, let intentResult,
              intentResult.invocation.command == descriptor.command,
              !intentResult.invocation.arguments.isEmpty else {
            return descriptor.command.slashName
        }
        return ([descriptor.command.slashName] + intentResult.invocation.arguments)
            .joined(separator: " ")
    }

    var selectedPaletteItemAnchor: String? {
        if paletteMode == .commands {
            guard filteredCommands.indices.contains(paletteSelectionIndex) else { return nil }
            return "command:\(filteredCommands[paletteSelectionIndex].command.rawValue)"
        }
        guard searchResults.indices.contains(paletteSelectionIndex) else { return nil }
        return "search:\(searchResults[paletteSelectionIndex].id.uuidString)"
    }

    var restorationState: EditorWindowRestorationState {
        var state = EditorWindowRestorationState(
            id: id,
            tabs: tabs.map { $0.restorationState() },
            activeTabID: activeTabID,
            isSidebarVisible: isSidebarVisible,
            isSidebarPinned: isSidebarPinned,
            isFullScreen: isFullScreenEnabled
        )
        state.normalize()
        return state
    }

    func connect(to appState: AppState) {
        if self.appState !== appState {
            exportPresentation.cancel()
            exportPresentation = appState.makeWindowExportPresentation()
            exportPresentation.attach(to: self)
        }
        self.appState = appState
        appState.register(self)
    }

    func disconnect() {
        exportPresentation.cancel()
        guard let appState else { return }
        appState.unregister(self)
        self.appState = nil
    }

    @discardableResult
    func newDocument(activate: Bool = true) -> EditorSession {
        let tab = EditorSession(openingMode: .newDocument)
        tabs.append(tab)
        appState?.activateNewDocument(tab)
        if activate {
            activeTabID = tab.id
        }
        return tab
    }

    func append(_ tab: EditorSession, activate: Bool = true) {
        guard !tabs.contains(where: { $0 === tab }) else {
            if activate { activeTabID = tab.id }
            return
        }
        tabs.append(tab)
        if activate { activeTabID = tab.id }
    }

    func select(tabID: UUID) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        activeTabID = tabID
    }

    func close(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        guard tab.flushForLifecycleEvent() else { return }
        tab.deactivate()
        appState?.release(tab)
        tabs.remove(at: index)

        if tabs.isEmpty {
            newDocument()
        } else if activeTabID == tabID {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Used only after a file mutation has already flushed and committed.
    /// Re-flushing an intentionally detached buffer could recreate its path.
    func closeAfterSuccessfulFileMutation(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = tabs[index]
        tab.deactivate()
        appState?.release(tab)
        tabs.remove(at: index)

        if tabs.isEmpty {
            newDocument()
        } else if activeTabID == tabID {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    @discardableResult
    func flushForLifecycleEvent() -> Bool {
        tabs.allSatisfy { $0.flushForLifecycleEvent() }
    }

    func focus(tabID: UUID) {
        select(tabID: tabID)
        appState?.focusWindow(id)
    }

    func noteEditorChange(to newText: String, edit: EditorTextEdit? = nil) {
        activeTab?.editorTextDidChange(newText, edit: edit)
        motion.update { $0.noteTyping() }
    }

    /// Production editor mutations arrive as bounded UTF-16 deltas so typing
    /// never snapshots a multi-megabyte NSTextView on the main actor.
    func noteEditorEdit(_ edit: MarkdownTextEdit) {
        activeTab?.editorTextDidChange(edit)
        motion.update { $0.noteTyping() }
    }

    func presentInlineSlashPalette(_ presentation: SlashCommandPresentation = .init(anchor: nil)) {
        presentPalette(source: .inlineSlash, query: "/")
        paletteAnchor = presentation.anchor
        restoreSlashLiteral = presentation.restoreLiteral
    }

    func toggleSidebar() {
        motion.update { $0.toggleSidebar() }
    }

    func setSidebarPinned(_ pinned: Bool) {
        isSidebarPinned = pinned
        motion.update { $0.setSidebarPinned(pinned) }
    }

    func revealSidebarTemporarily() {
        motion.update { $0.revealSidebarTemporarily() }
    }

    func hideSidebar() {
        motion.update { $0.hideSidebar() }
    }

    func setSidebarHovered(_ hovered: Bool) {
        isSidebarHovered = hovered
        isSidebarInteractionActive = isSidebarHovered || isSidebarFocused
        motion.update { $0.setSidebarHovered(hovered) }
    }

    func setSidebarFocused(_ focused: Bool) {
        isSidebarFocused = focused
        isSidebarInteractionActive = isSidebarHovered || isSidebarFocused
        motion.update { $0.setSidebarFocused(focused) }
    }

    func handleHorizontalGesture(deltaX: CGFloat, phaseEnded: Bool) {
        horizontalGestureDistance += deltaX
        let threshold: CGFloat = 42
        if horizontalGestureDistance >= threshold {
            revealSidebarTemporarily()
            horizontalGestureDistance = 0
        } else if horizontalGestureDistance <= -threshold {
            hideSidebar()
            horizontalGestureDistance = 0
        }
        if phaseEnded {
            horizontalGestureDistance = 0
        }
    }

    func presentPalette(
        source: ClioCommandSource = .palette,
        query: String = "",
        mode: CommandPaletteMode = .commands
    ) {
        if isPalettePresented { dismissPalette() }
        paletteAnchor = nil
        restoreSlashLiteral = nil
        paletteSource = source
        paletteMode = mode
        paletteQuery = query
        paletteErrorMessage = nil
        paletteSelectionIndex = 0
        palettePointerAtPresentation = NSEvent.mouseLocation
        motion.synchronizeSurface(.palette, presented: true, viewport: activeTab?.viewportState ?? .zero)
        isPalettePresented = true
        if mode == .search {
            updateSearch()
        }
    }

    func dismissPalette(preservingLiteral: Bool = true) {
        guard isPalettePresented else { return }
        let restore = restoreSlashLiteral
        restoreSlashLiteral = nil
        searchTask?.cancel()
        isPalettePresented = false
        motion.synchronizeSurface(.palette, presented: false, viewport: activeTab?.viewportState ?? .zero)
        // Restore the pre-palette responder/selection first, then insert the
        // cancelled query so its final caret is not reset to the old position.
        if preservingLiteral, let restore {
            restore(paletteQuery.hasPrefix("/") ? paletteQuery : "/" + paletteQuery)
        }
        paletteErrorMessage = nil
        isSearching = false
        clearCommandIntent()
        // SwiftUI's field editor relinquishes focus after its presentation
        // update. Request a guarded follow-up without restoring the old range.
        focusRestorationGeneration &+= 1
    }

    func updatePaletteQuery(_ query: String) {
        // Two literal spaces escape an empty slash command. Do not trim:
        // whitespace within a real command or workspace search remains input.
        if isPalettePresented, paletteMode == .commands, paletteSource == .inlineSlash,
           query == "/  " || query == "  " {
            paletteQuery = "/"
            dismissPalette()
            return
        }
        paletteQuery = query
        paletteErrorMessage = nil
        paletteSelectionIndex = 0
        if paletteMode == .search {
            updateSearch()
        } else {
            updateCommandIntent()
        }
    }

    func updateWorkspaceFilter(_ workspaceID: WorkspaceID?) {
        workspaceFilter = workspaceID
        if paletteMode == .search {
            updateSearch()
        }
    }

    func chooseSearchResult(_ result: WorkspaceSearchResult) {
        dismissPalette(preservingLiteral: false)
        appState?.openSearchResult(result, from: self)
    }

    func selectPaletteItem(at index: Int) {
        let count = paletteMode == .commands
            ? filteredCommands.count
            : searchResults.count
        guard count > 0 else {
            paletteSelectionIndex = 0
            return
        }
        paletteSelectionIndex = min(max(0, index), count - 1)
    }

    func movePaletteSelection(by offset: Int) {
        selectPaletteItem(at: paletteSelectionIndex + offset)
    }

    func selectPaletteItemFromPointer(at index: Int) {
        // Opening a palette under a stationary pointer must not override its
        // initial keyboard selection. Hover takes over once the pointer moves.
        guard NSEvent.mouseLocation != palettePointerAtPresentation else { return }
        selectPaletteItem(at: index)
    }

    func performSelectedPaletteItem() {
        if paletteMode == .search {
            guard searchResults.indices.contains(paletteSelectionIndex) else { return }
            chooseSearchResult(searchResults[paletteSelectionIndex])
            return
        }
        guard filteredCommands.indices.contains(paletteSelectionIndex) else { return }
        let command = filteredCommands[paletteSelectionIndex].command
        do {
            try perform(invocation(for: command))
        } catch {
            paletteErrorMessage = error.localizedDescription
        }
    }

    func invocation(for command: ClioCommandID) throws -> ClioCommandInvocation {
        let token = ClioCommandParser.commandToken(in: paletteQuery).lowercased()
        guard token == command.rawValue else {
            // An assisted match may have filled an argument from the request,
            // such as the format in "send this to my editor in Word".
            if let intentResult, intentQuery == paletteQuery,
               intentResult.invocation.command == command {
                return intentResult.invocation
            }
            return ClioCommandInvocation(command: command, arguments: [])
        }
        let trimmed = paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandLine = trimmed.first == "/" ? trimmed : "/\(trimmed)"
        return try ClioCommandParser.parse(commandLine)
    }

    func perform(_ command: ClioCommandID) {
        perform(ClioCommandInvocation(command: command, arguments: []))
    }

    func perform(_ invocation: ClioCommandInvocation) {
        guard let appState else { return }
        let context = ClioCommandContext(
            windowID: id,
            tabID: activeTabID,
            source: paletteSource
        )
        dismissPalette(preservingLiteral: false)
        Task { @MainActor in
            await appState.perform(
                invocation,
                context: context
            )
        }
    }
}

extension EditorWindowSession {
    /// Asks for an assisted match, but only where the palette has nothing of
    /// its own to show.
    ///
    /// The order of these guards is the privacy contract: the literal filter
    /// runs first, and a request is built only once it has come up empty and
    /// the feature is switched on with a key in place.
    func updateCommandIntent() {
        intentTask?.cancel()
        isResolvingIntent = false
        let query = paletteQuery
        guard isPalettePresented, paletteMode == .commands else {
            clearCommandIntent()
            return
        }
        guard literalCommands.isEmpty else {
            clearCommandIntent()
            return
        }
        guard let appState, appState.intelligence.isReady else {
            clearCommandIntent()
            return
        }
        let request = ClioCommandParser.commandToken(in: query).isEmpty
            ? query.trimmingCharacters(in: .whitespacesAndNewlines)
            : String(query.drop(while: { $0 == "/" }))
        guard request.count >= 3 else {
            clearCommandIntent()
            return
        }

        let context = commandIntentContext()
        isResolvingIntent = true
        intentTask = Task { @MainActor [weak self, weak appState] in
            // The writer is still typing. Settle before spending a request.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let appState else { return }
            let result = await appState.intelligence.resolveCommand(
                for: request,
                context: context
            )
            guard !Task.isCancelled, self.paletteQuery == query else { return }
            self.isResolvingIntent = false
            self.intentResult = result
            self.intentQuery = query
            self.selectPaletteItem(at: 0)
        }
    }

    func commandIntentContext() -> CommandIntentContext {
        CommandIntentContext(
            hasOpenDocument: activeTab != nil,
            documentExistsOnDisk: activeTab?.fileURL != nil,
            isFocusModeEnabled: appState?.isFocusModeEnabled ?? false,
            isTypewriterEnabled: appState?.isTypewriterModeEnabled ?? false,
            isSidebarVisible: isSidebarVisible
        )
    }

    func clearCommandIntent() {
        intentTask?.cancel()
        intentTask = nil
        isResolvingIntent = false
        intentResult = nil
        intentQuery = ""
    }
}

private extension EditorWindowSession {
    func updateSearch() {
        searchTask?.cancel()
        searchResults = []
        paletteErrorMessage = nil
        guard let appState else { return }
        let query = paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }
            do {
                for try await batch in await appState.search(
                    query,
                    workspaceFilter: self.workspaceFilter
                ) {
                    guard !Task.isCancelled else { return }
                    self.searchResults = batch.results
                    self.selectPaletteItem(at: self.paletteSelectionIndex)
                    self.isSearching = !batch.isFinal
                }
            } catch is CancellationError {
                return
            } catch {
                self.isSearching = false
                self.paletteErrorMessage = error.localizedDescription
            }
        }
    }
}
