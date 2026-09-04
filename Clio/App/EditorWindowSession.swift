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
    var activeTabID: UUID?
    var isSidebarVisible: Bool
    var isSidebarPinned: Bool
    var isFullScreenEnabled: Bool
    private(set) var isSidebarInteractionActive = false

    var isPalettePresented = false
    var paletteMode = CommandPaletteMode.commands
    var paletteQuery = ""
    var paletteSource = ClioCommandSource.palette
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
    private var sidebarTimer: Task<Void, Never>?

    @ObservationIgnored
    private var searchTask: Task<Void, Never>?

    @ObservationIgnored
    private var horizontalGestureDistance: CGFloat = 0

    @ObservationIgnored
    private var isSidebarHovered = false

    @ObservationIgnored
    private var isSidebarFocused = false

    @ObservationIgnored
    private var deferredSidebarDismissal: SidebarDismissal?

    @ObservationIgnored
    private var activeSidebarDismissal: SidebarDismissal?

    init(request: EditorWindowRequest) {
        id = request.id
        isFullScreenEnabled = request.restoration?.isFullScreen
            ?? request.isFullScreen
        isSidebarVisible = request.restoration?.isSidebarVisible ?? true
        isSidebarPinned = request.restoration?.isSidebarPinned ?? false

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
    }

    deinit {
        sidebarTimer?.cancel()
        searchTask?.cancel()
    }

    var activeTab: EditorSession? {
        guard let activeTabID else { return tabs.first }
        return tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    var filteredCommands: [ClioCommandDescriptor] {
        let needle = ClioCommandParser.commandToken(in: paletteQuery)
        guard !needle.isEmpty else { return ClioCommandDescriptor.all }
        return ClioCommandDescriptor.all.filter {
            $0.command.rawValue.localizedCaseInsensitiveContains(needle)
                || $0.title.localizedCaseInsensitiveContains(needle)
                || $0.detail.localizedCaseInsensitiveContains(needle)
        }
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
        self.appState = appState
        appState.register(self)
    }

    func disconnect() {
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
        scheduleWritingCollapse()
    }

    /// Production editor mutations arrive as bounded UTF-16 deltas so typing
    /// never snapshots a multi-megabyte NSTextView on the main actor.
    func noteEditorEdit(_ edit: MarkdownTextEdit) {
        activeTab?.editorTextDidChange(edit)
        scheduleWritingCollapse()
    }

    func presentInlineSlashPalette() {
        presentPalette(source: .inlineSlash, query: "/")
    }

    func toggleSidebar() {
        sidebarTimer?.cancel()
        sidebarTimer = nil
        deferredSidebarDismissal = nil
        activeSidebarDismissal = nil
        isSidebarVisible.toggle()
        if !isSidebarVisible { clearSidebarInteraction() }
    }

    func setSidebarPinned(_ pinned: Bool) {
        isSidebarPinned = pinned
        sidebarTimer?.cancel()
        sidebarTimer = nil
        deferredSidebarDismissal = nil
        activeSidebarDismissal = nil
        if !pinned, isSidebarVisible {
            scheduleTemporarySidebarDismissal(after: Self.temporarySidebarDelay)
        }
    }

    func revealSidebarTemporarily() {
        isSidebarVisible = true
        scheduleTemporarySidebarDismissal(after: Self.temporarySidebarDelay)
    }

    func hideSidebar() {
        sidebarTimer?.cancel()
        sidebarTimer = nil
        deferredSidebarDismissal = nil
        activeSidebarDismissal = nil
        isSidebarVisible = false
        clearSidebarInteraction()
    }

    func setSidebarHovered(_ hovered: Bool) {
        isSidebarHovered = hovered
        sidebarInteractionDidChange()
    }

    func setSidebarFocused(_ focused: Bool) {
        isSidebarFocused = focused
        sidebarInteractionDidChange()
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
        paletteSource = source
        paletteMode = mode
        paletteQuery = query
        paletteErrorMessage = nil
        paletteSelectionIndex = 0
        palettePointerAtPresentation = NSEvent.mouseLocation
        isPalettePresented = true
        if mode == .search {
            updateSearch()
        }
    }

    func dismissPalette() {
        searchTask?.cancel()
        isPalettePresented = false
        paletteErrorMessage = nil
        isSearching = false
        focusRestorationGeneration &+= 1
    }

    func updatePaletteQuery(_ query: String) {
        paletteQuery = query
        paletteErrorMessage = nil
        paletteSelectionIndex = 0
        if paletteMode == .search {
            updateSearch()
        }
    }

    func updateWorkspaceFilter(_ workspaceID: WorkspaceID?) {
        workspaceFilter = workspaceID
        if paletteMode == .search {
            updateSearch()
        }
    }

    func chooseSearchResult(_ result: WorkspaceSearchResult) {
        dismissPalette()
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
        dismissPalette()
        Task { @MainActor in
            await appState.perform(
                invocation,
                context: context
            )
        }
    }
}

private extension EditorWindowSession {
    enum SidebarDismissal {
        case writing
        case temporary
    }

    func sidebarInteractionDidChange() {
        let isActive = isSidebarHovered || isSidebarFocused
        guard isSidebarInteractionActive != isActive else { return }
        isSidebarInteractionActive = isActive
        if isActive {
            if let activeSidebarDismissal {
                deferredSidebarDismissal = activeSidebarDismissal
            }
            sidebarTimer?.cancel()
            sidebarTimer = nil
            activeSidebarDismissal = nil
        } else if let deferredSidebarDismissal {
            self.deferredSidebarDismissal = nil
            switch deferredSidebarDismissal {
            case .writing:
                scheduleWritingCollapse()
            case .temporary:
                scheduleTemporarySidebarDismissal(after: Self.temporarySidebarDelay)
            }
        }
    }

    func clearSidebarInteraction() {
        isSidebarHovered = false
        isSidebarFocused = false
        isSidebarInteractionActive = false
    }

    func scheduleWritingCollapse() {
        guard isSidebarVisible, !isSidebarPinned else { return }
        guard !isSidebarInteractionActive else {
            deferredSidebarDismissal = .writing
            return
        }
        guard sidebarTimer == nil else { return }
        activeSidebarDismissal = .writing
        sidebarTimer = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.writingCollapseDelay)
            } catch {
                return
            }
            guard let self,
                  !self.isSidebarPinned,
                  !self.isSidebarInteractionActive else { return }
            self.isSidebarVisible = false
            self.sidebarTimer = nil
            self.activeSidebarDismissal = nil
        }
    }

    func scheduleTemporarySidebarDismissal(after duration: Duration) {
        guard !isSidebarPinned else { return }
        guard !isSidebarInteractionActive else {
            deferredSidebarDismissal = .temporary
            return
        }
        sidebarTimer?.cancel()
        activeSidebarDismissal = .temporary
        sidebarTimer = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self,
                  !self.isSidebarPinned,
                  !self.isSidebarInteractionActive else { return }
            self.isSidebarVisible = false
            self.sidebarTimer = nil
            self.activeSidebarDismissal = nil
        }
    }

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
