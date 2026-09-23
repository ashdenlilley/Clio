import AppKit
import ObjectiveC
import SwiftUI

private var clioEditorWindowSessionKey: UInt8 = 0

private func markAsClioEditorWindow(_ window: NSWindow, sessionID: UUID) {
    objc_setAssociatedObject(
        window,
        &clioEditorWindowSessionKey,
        sessionID as NSUUID,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    if ProcessInfo.processInfo.environment["CLIO_UI_TESTING"] == "1" {
        // Stable across front-to-back ordering changes and fullscreen Spaces.
        window.setAccessibilityIdentifier("diagnostics.editor-window.\(sessionID.uuidString)")
    }
}

func clioEditorSessionID(for window: NSWindow) -> UUID? {
    (objc_getAssociatedObject(window, &clioEditorWindowSessionKey) as? NSUUID)
        .map { $0 as UUID }
}

func isClioEditorWindow(_ window: NSWindow) -> Bool {
    clioEditorSessionID(for: window) != nil
}

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorWindowSession.self) private var windowSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var displayedConflict: DocumentConflict?
    @State private var conflictEditorSession: EditorSession?
    @State private var pasteStructure = PasteStructureController()
    @FocusState private var settingsDoneFocused: Bool

    private var motion: WindowMotionAdapter { windowSession.motion }

    var body: some View {
        ZStack {
          Group {
            if let editorSession = windowSession.activeTab, editorSession.isReady {
                editorPane(editorSession)
                .overlay(alignment: .leading) {
                    MotionSidebarOverlay()
                }
                .clipped()
                .task(id: editorSession.contentRevision) {
                    editorSession.refreshDerivedStateForCurrentRevision()
                }
                .overlay(alignment: .top) {
                    if editorSession.requiresExplicitRestore {
                        DetachedDocumentBanner(
                            filename: editorSession.filename,
                            canRestore: editorSession.canRestoreAtPreviousLocation,
                            restore: editorSession.saveNow
                        )
                    } else if let recovery = appState.pendingExportRecoveries.first {
                        ExportRecoveryBanner(
                            item: recovery,
                            remainingCount: appState.pendingExportRecoveries.count,
                            reveal: { appState.revealExportRecovery(recovery) },
                            discard: { appState.discardExportRecovery(recovery) }
                        )
                    } else if let errorMessage = editorSession.errorMessage
                        ?? appState.crashRecoveryMessage
                        ?? appState.workspaceErrorMessage {
                        WorkspaceErrorBanner(
                            message: errorMessage,
                            dismiss: {
                                editorSession.dismissError()
                                appState.dismissTransientMessage()
                            }
                        )
                    }
                }
            } else {
                WorkspaceSetupView()
            }
          }
          .allowsHitTesting(!motion.hasActiveSurfaces)
          .accessibilityHidden(motion.hasActiveSurfaces)
          transientSurfaces
        }
        .frame(
            minWidth: Metrics.minimumWindowWidth,
            minHeight: Metrics.minimumWindowHeight
        )
        .background(Color(nsColor: Palette.background))
        .environment(\.clioAccent, appState.accent.color)
        .background(
            WindowChromeProbe(
                windowSession: windowSession,
                editorSession: windowSession.activeTab,
                hidesPointerWhileTyping: appState.preferences.hidesPointerWhileTyping
            )
        )
        .overlay(alignment: .bottomTrailing) {
            if ProcessInfo.processInfo.environment["CLIO_UI_TESTING"] == "1" {
                // New windows start windowed; the notifications below update
                // this only when AppKit has completed a fullscreen transition,
                // not when its shortcut is sent. Never present in normal use.
                Text(windowSession.isFullScreenEnabled ? "fullscreen" : "windowed")
                    .font(.system(size: 8))
                    .accessibilityIdentifier("diagnostics.window.fullscreen")
                    .accessibilityLabel(Text("Window fullscreen state"))
                    .accessibilityValue(Text(windowSession.isFullScreenEnabled ? "fullscreen" : "windowed"))
                    .allowsHitTesting(false)
            }
        }
        .transaction { $0.animation = nil }
        .onChange(of: reduceMotion, initial: true) { _, _ in updateMotionPreferences() }
        .onChange(of: reduceTransparency) { _, _ in updateMotionPreferences() }
        .onChange(of: appState.isChromeFadeEnabled, initial: true) { _, enabled in
            motion.update { $0.setChromeFadeEnabled(enabled) }
        }
        .onChange(of: windowSession.isSettingsPresented) { _, presented in
            motion.synchronizeSurface(.settings, presented: presented, viewport: windowSession.activeTab?.viewportState ?? .zero)
        }
        .onChange(of: windowSession.activeTab?.activeConflict?.id, initial: true) { _, id in
            synchronizeConflict()
        }
        .onChange(of: conflictEditorSession?.activeConflict?.id) { _, id in
            synchronizeConflict()
        }
        .alert(
            "A file already exists",
            isPresented: Binding(
                get: { windowSession.activeTab?.pendingCollision != nil },
                set: { _ in }
            ),
            presenting: windowSession.activeTab?.pendingCollision
        ) { _ in
            Button("Cancel", role: .cancel) {
                if let tab = windowSession.activeTab {
                    appState.resolvePendingFileCollision(.cancel, for: tab)
                }
            }
            Button("Keep Both") {
                if let tab = windowSession.activeTab {
                    appState.resolvePendingFileCollision(.keepBoth, for: tab)
                }
            }
            Button("Replace", role: .destructive) {
                if let tab = windowSession.activeTab {
                    appState.resolvePendingFileCollision(.replace, for: tab)
                }
            }
        } message: { collision in
            Text("\(collision.proposedLocator.relativePath) is already present. Replace it or keep both using the next “name (2).md” variant.")
        }
        .modifier(DocumentExportPresentationModifier())
        .environment(windowSession.exportPresentation)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  clioEditorSessionID(for: window) == windowSession.id else { return }
            windowSession.isFullScreenEnabled = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  clioEditorSessionID(for: window) == windowSession.id else { return }
            windowSession.isFullScreenEnabled = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            windowSession.flushForLifecycleEvent()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            windowSession.flushForLifecycleEvent()
        }
        .onChange(of: windowSession.focusRestorationGeneration) { _, _ in
            restoreEditorFocus()
        }
    }

    private func editorPane(_ editorSession: EditorSession) -> some View {
        let onSlashCommand: (@MainActor (SlashCommandPresentation) -> Void)?
        if appState.preferences.isSlashCommandEnabled {
            onSlashCommand = { presentation in windowSession.presentInlineSlashPalette(presentation) }
        } else {
            onSlashCommand = nil
        }
        let configuration = EditorConfiguration(
            fontSize: CGFloat(appState.fontSize),
            fontName: appState.editorFontName,
            measure: appState.measure,
            lineHeightMultiple: CGFloat(appState.lineHeight),
            isSpellCheckingEnabled: appState.isSpellCheckingEnabled,
            isTypewriterScrollingEnabled: appState.isTypewriterModeEnabled,
            typewriterAnchor: CGFloat(appState.typewriterAnchor),
            isFocusModeEnabled: appState.isFocusModeEnabled,
            focusDimmingOpacity: CGFloat(appState.focusDimmingOpacity),
            accent: appState.accent,
            caretStyle: appState.preferences.caretStyle,
            isGrammarCheckingEnabled: appState.preferences.isGrammarCheckingEnabled,
            isSmartPunctuationEnabled: appState.preferences.isSmartPunctuationEnabled,
            autoWrapsSelection: appState.preferences.autoWrapsSelection
        )
        return VStack(spacing: 0) {
            EditorView(
                text: editorSession.draftText,
                contentGeneration: editorSession.bufferGeneration,
                viewport: Binding(
                    get: { editorSession.viewportState },
                    set: { editorSession.updateViewport($0) }
                ),
                configuration: configuration,
                onTextEdit: { edit in
                    windowSession.noteEditorEdit(edit)
                },
                onSlashCommand: onSlashCommand,
                onPlainTextPasted: { pasted, range, textView in
                    pasteStructure.recover(
                        pasted: pasted,
                        range: range,
                        in: textView,
                        using: appState.intelligence
                    )
                },
                minimap: windowSession.minimap,
                onEditorReady: { [weak editorSession] in editorSession?.mcpTextView = $0 }
            )
            .overlay(alignment: .topTrailing) {
                if appState.preferences.showsMinimap {
                    EditorMinimapOverlay().frame(width: 32)
                }
            }

            if appState.preferences.showsStatusLine {
                StatusLine(
                    relativePath: editorSession.relativePath,
                    wordCountLabel: editorSession.wordCountLabel,
                    wordCount: editorSession.wordCount,
                    fontSize: appState.fontSize,
                    showsReadingTime: appState.preferences.showsReadingTime,
                    showsSpeakingTime: appState.preferences.showsSpeakingTime
                )
                .modifier(ContextChromeMotion(motion: motion))
            }
        }
        .background(Color(nsColor: Palette.background))
    }

    private func updateMotionPreferences() {
        motion.setPreferences(MotionPreferences(reduceMotion: reduceMotion, reduceTransparency: reduceTransparency))
    }

    private func synchronizeConflict() {
        if let conflict = conflictEditorSession?.activeConflict {
            displayedConflict = conflict
            return
        }
        motion.synchronizeSurface(.conflict, presented: false, viewport: conflictEditorSession?.viewportState ?? .zero)
        guard let session = windowSession.activeTab, let conflict = session.activeConflict else { return }
        conflictEditorSession = session
        displayedConflict = conflict
        motion.synchronizeSurface(.conflict, presented: true, viewport: session.viewportState)
    }

    private var transientSurfaces: some View {
        GeometryReader { geometry in
          let state = motion.surfaceState
          ZStack {
            if state.conflictBanner.presentation > 0 {
                VStack {
                    Label("Outside changes need your decision. Autosave is paused.", systemImage: "exclamationmark.triangle")
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color(nsColor: Palette.backgroundRaised))
                        .modifier(SurfacePresentation(progress: state.conflictBanner.presentation, y: -8, scale: 1, reduceMotion: reduceMotion))
                    Spacer()
                }
            }
            if state.overlay.presentation > 0 {
                Color.black.opacity((windowSession.paletteAnchor != nil && state.activeSurfaceStack.last == .palette ? 0.001 : (reduceTransparency ? 0.85 : 0.38)) * state.overlay.presentation)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if state.activeSurfaceStack.last == .palette { windowSession.dismissPalette() }
                        if state.activeSurfaceStack.last == .settings { windowSession.isSettingsPresented = false }
                    }
                    .allowsHitTesting(!state.activeSurfaces.isEmpty)
                    .accessibilityHidden(true)
            }
            ForEach(state.visualSurfaceStack, id: \.self) { surface in
                surfaceView(surface, availableSize: geometry.size, origin: geometry.frame(in: .global).origin)
                    .allowsHitTesting(state.activeSurfaceStack.last == surface)
                    .accessibilityHidden(state.activeSurfaceStack.last != surface)
                    .accessibilityAddTraits(.isModal)
            }
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    @ViewBuilder private func surfaceView(_ surface: TransientSurface, availableSize: CGSize, origin: CGPoint) -> some View {
        let state = motion.surfaceState
        switch surface {
        case .palette:
            if let anchor = windowSession.paletteAnchor {
                let frame = CommandPalettePlacement.frame(below: anchor.offsetBy(dx: -origin.x, dy: -origin.y), in: availableSize)
                CommandPaletteView(maximumWidth: frame.width, maximumResultsHeight: max(1, frame.height - 64))
                    .frame(height: frame.height)
                    .modifier(SurfacePresentation(progress: state.palette.presentation, y: -6, scale: 0.985, reduceMotion: reduceMotion))
                    .frame(width: availableSize.width, height: availableSize.height, alignment: .topLeading)
                    .offset(x: frame.minX, y: frame.minY)
            } else {
                CommandPaletteView(maximumWidth: min(620, availableSize.width - 32), maximumResultsHeight: min(360, max(100, availableSize.height - 140)))
                    .modifier(SurfacePresentation(progress: state.palette.presentation, y: -6, scale: 0.985, reduceMotion: reduceMotion))
            }
        case .settings:
            VStack(spacing: 0) {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    Button("Done") { windowSession.isSettingsPresented = false }
                        .keyboardShortcut(.cancelAction)
                        .focused($settingsDoneFocused)
                }.padding(16)
                SettingsView()
            }
            .frame(width: min(500, availableSize.width - 32), height: min(650, availableSize.height - 32))
            .background(Color(nsColor: Palette.background))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .modifier(SurfacePresentation(progress: state.settings.presentation, y: 8, scale: 0.99, reduceMotion: reduceMotion))
            .onAppear { settingsDoneFocused = true }
            .onChange(of: windowSession.isSettingsPresented) { _, presented in settingsDoneFocused = presented }
        case .conflict:
            if let conflict = displayedConflict, let editorSession = conflictEditorSession {
                ScrollView {
                    ConflictResolutionView(conflict: conflict, isResolving: editorSession.isResolvingConflict, resolve: editorSession.resolveConflict)
                }
                    .frame(width: min(560, availableSize.width - 32), height: min(520, availableSize.height - 32))
                    .background(Color(nsColor: Palette.background))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .modifier(SurfacePresentation(progress: state.conflict.presentation, y: 8, scale: 0.99, reduceMotion: reduceMotion))
            }
        }
    }

    private func restoreEditorFocus() {
        let generation = windowSession.focusRestorationGeneration
        let tabID = windowSession.activeTabID
        DispatchQueue.main.async {
            guard windowSession.focusRestorationGeneration == generation,
                  windowSession.activeTabID == tabID,
                  !windowSession.isPalettePresented,
                  !windowSession.isSettingsPresented,
                  !windowSession.motion.hasActiveSurfaces,
                  let window = NSApplication.shared.windows.first(where: {
                clioEditorSessionID(for: $0) == windowSession.id
            }), window.isKeyWindow, let contentView = window.contentView,
              let editor = findEditorTextView(in: contentView) else { return }
            window.makeFirstResponder(editor)
        }
    }
}

/// Observe sidebar frames below the editor's structural identity boundary.
private struct MotionSidebarOverlay: View {
    @Environment(EditorWindowSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let motion = session.motion
        if motion.sidebarProgress > 0 || session.isSidebarVisible {
            WorkspaceSidebar()
                .offset(x: reduceMotion ? 0 : -252 * (1 - motion.sidebarProgress))
                .opacity(reduceMotion ? motion.sidebarProgress : 1)
                .allowsHitTesting(motion.chrome.sidebarAllowsHitTesting)
                .accessibilityHidden(!motion.chrome.sidebarAllowsHitTesting)
        }
    }
}

struct ContextChromeMotion: ViewModifier {
    let motion: WindowMotionAdapter
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content
            .opacity(motion.contextProgress * (reduceTransparency ? 1 : 0.65))
            .allowsHitTesting(motion.contextProgress > 0.001)
            .accessibilityHidden(motion.contextProgress <= 0.001)
    }
}

private func findEditorTextView(in view: NSView) -> EditorTextView? {
    if let editor = view as? EditorTextView { return editor }
    for child in view.subviews {
        if let editor = findEditorTextView(in: child) { return editor }
    }
    return nil
}

private struct ExportRecoveryBanner: View {
    let item: ExportRecoveryItem
    let remainingCount: Int
    let reveal: () -> Void
    let discard: () -> Void
    @State private var isConfirmingDiscard = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.badge.clock")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .foregroundStyle(Color(nsColor: Palette.muted))
            }
            Spacer(minLength: 8)
            Button("Show in Finder", action: reveal)
            if item.kind == .completedDestination {
                Button("Dismiss", action: discard)
            } else {
                Button("Discard", role: .destructive) {
                    isConfirmingDiscard = true
                }
            }
        }
        .font(.custom(Typography.family, fixedSize: 12))
        .foregroundStyle(Color(nsColor: Palette.foreground))
        .padding(12)
        .background(Color(nsColor: Palette.backgroundRaised))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Palette.hairline))
                .frame(height: 1)
        }
        .alert("Discard recovered export?", isPresented: $isConfirmingDiscard) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive, action: discard)
        } message: {
            Text("This permanently removes Clio's preserved copy of \(item.filename).")
        }
    }

    private var detail: String {
        let size = item.byteCount.formatted(.byteCount(style: .file))
        guard remainingCount > 1 else {
            return "\(size) · preserved securely for seven days"
        }
        return "\(size) · \(remainingCount - 1) more preserved · kept securely for seven days"
    }

    private var title: String {
        switch item.kind {
        case .renderedCandidate:
            "Interrupted export preserved: \(item.filename)"
        case .displacedDestination:
            "Pre-export version preserved: \(item.filename)"
        case .completedDestination:
            "Export completed before Clio closed: \(item.filename)"
        }
    }
}

private struct DetachedDocumentBanner: View {
    let filename: String
    let canRestore: Bool
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.badge.clock")
                .foregroundStyle(.orange)
            Text(canRestore
                ? "\(filename) was removed from disk. Its text is safe in Clio and will not be recreated automatically."
                : "\(filename) could not be restored. Clio kept this exact tab detached and did not substitute another document.")
            Spacer(minLength: 8)
            if canRestore {
                Button("Restore Document", action: restore)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.custom(Typography.family, fixedSize: 12))
        .foregroundStyle(Color(nsColor: Palette.foreground))
        .padding(12)
        .background(Color(nsColor: Palette.backgroundRaised))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Palette.hairline))
                .frame(height: 1)
        }
    }
}

private struct ConflictResolutionView: View {
    private struct Preview {
        let conflictID: UUID
        let text: String
    }

    let conflict: DocumentConflict
    let isResolving: Bool
    let resolve: (ConflictChoice) -> Void
    @State private var preview: Preview?
    @FocusState private var decisionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("This document changed outside Clio", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(Color(nsColor: Palette.foreground))

            Text("Autosave is paused. Choose which content becomes canonical; Clio creates a recovery copy before replacing either version.")
                .foregroundStyle(Color(nsColor: Palette.muted))

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Clio")
                    Text(conflict.clio.modificationDate, format: .dateTime)
                }
                GridRow {
                    Text("Outside")
                    Text(conflict.external.modificationDate, format: .dateTime)
                }
            }
            .font(.custom(Typography.family, fixedSize: 12))

            ScrollView {
                Text(
                    preview?.conflictID == conflict.id
                        ? preview?.text ?? ""
                        : "Preparing a bounded preview…"
                )
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .background(Color(nsColor: Palette.backgroundRaised))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Load External") { resolve(.loadExternal) }
                Button("Keep Both") { resolve(.keepBoth) }
                Spacer()
                Button("Keep Clio") { resolve(.keepClio) }
                    .keyboardShortcut(.defaultAction)
                    .focused($decisionFocused)
            }
            .disabled(isResolving)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: Palette.background))
        .accessibilityElement(children: .contain)
        .task(id: conflict.id) {
            decisionFocused = true
            let conflictID = conflict.id
            let text = await ConflictPreviewBuilder.preview(for: conflict)
            guard !Task.isCancelled, conflict.id == conflictID else { return }
            preview = Preview(conflictID: conflictID, text: text)
        }
    }
}

private struct WorkspaceErrorBanner: View {
    @Environment(AppState.self) private var appState
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(appState.accent.color)

            Text(message)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(appState.needsRecoveryAuthorization ? "Authorize Recovery…" : "Choose Folder…") {
                if appState.needsRecoveryAuthorization {
                    appState.chooseRecoveryFolder()
                } else {
                    appState.chooseAnotherWorkspace()
                }
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .interactionCursor()
            .accessibilityLabel("Dismiss error")
        }
        .font(.custom(Typography.family, fixedSize: 12))
        .foregroundStyle(Color(nsColor: Palette.foreground))
        .padding(12)
        .background(Color(nsColor: Palette.backgroundRaised))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: Palette.hairline))
                .frame(height: 1)
        }
    }
}

private struct StatusLine: View {
    let relativePath: String
    let wordCountLabel: String
    let wordCount: Int
    let fontSize: Double
    let showsReadingTime: Bool
    let showsSpeakingTime: Bool

    private var statistics: String {
        StatusLineText.statistics(
            wordCountLabel: wordCountLabel,
            wordCount: wordCount,
            showsReadingTime: showsReadingTime,
            showsSpeakingTime: showsSpeakingTime
        )
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(relativePath)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Spacer(minLength: 40)

            Text(statistics)
                .fixedSize()
                .accessibilityIdentifier("editor.statistics")
        }
        .font(.custom(Typography.family, fixedSize: fontSize * 0.85))
        .foregroundStyle(Color(nsColor: Palette.muted))
        .padding(.horizontal, 18)
        .frame(height: Metrics.statusHeight)
        .background(Color(nsColor: Palette.background))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(relativePath), \(statistics)")
    }
}

private struct WindowChromeProbe: NSViewRepresentable {
    let windowSession: EditorWindowSession
    let editorSession: EditorSession?
    let hidesPointerWhileTyping: Bool

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.windowSession = windowSession
        view.editorSession = editorSession
        view.hidesPointerWhileTyping = hidesPointerWhileTyping
        view.configureWindowIfNeeded()
        return view
    }

    func updateNSView(_ view: WindowProbeView, context: Context) {
        view.windowSession = windowSession
        view.editorSession = editorSession
        view.hidesPointerWhileTyping = hidesPointerWhileTyping
        view.restorePointerIfDisabled()
        view.configureWindowIfNeeded()
    }

    static func dismantleNSView(_ view: WindowProbeView, coordinator: ()) {
        view.detachFromWindow()
    }
}

private final class WindowProbeView: NSView, NSWindowDelegate {
    // This is a lifecycle probe, never an input surface (including fullscreen).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    weak var windowSession: EditorWindowSession?
    weak var editorSession: EditorSession?
    var hidesPointerWhileTyping = true

    private var hasAppliedInitialState = false
    private var forwardedWindowDelegate: NSWindowDelegate?
    private var scrollMonitor: Any?
    private var dragEndMonitor: Any?
    private var titlebarAccessory: NSTitlebarAccessoryViewController?
    private var sidebarButton: NSButton?
    private var pointerIsHidden = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let currentWindow = window, currentWindow !== newWindow {
            detachFromWindow()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func configureWindowIfNeeded() {
        guard let window, let windowSession else { return }

        let relativePath = editorSession?.relativePath ?? ""
        let documentTitle = relativePath.isEmpty ? "Untitled" : relativePath
        window.title = "\(documentTitle) — Clio"
        window.miniwindowTitle = documentTitle
        window.representedURL = editorSession?.fileURL
        markAsClioEditorWindow(window, sessionID: windowSession.id)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.backgroundColor = Palette.background
        window.isOpaque = true
        window.minSize = NSSize(
            width: Metrics.minimumWindowWidth,
            height: Metrics.minimumWindowHeight
        )

        if window.delegate !== self {
            forwardedWindowDelegate = window.delegate
            window.delegate = self
        }

        installScrollMonitor(for: window)
        installTitlebarControl(in: window)
        windowSession.motion.window = window
        windowSession.motion.applyNativeChrome = { [weak self] in self?.updateNativeChrome() }
        guard !hasAppliedInitialState else { return }
        hasAppliedInitialState = true

        if windowSession.isFullScreenEnabled,
           !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard windowSession?.flushForLifecycleEvent() != false else {
            sender.makeKeyAndOrderFront(nil)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Clio couldn’t save every document"
            alert.informativeText = "The window stayed open so your unsaved text remains visible. Restore access or free disk space, then try again."
            alert.addButton(withTitle: "Keep Writing")
            alert.beginSheetModal(for: sender)
            return false
        }
        return forwardedWindowDelegate?.windowShouldClose?(sender) ?? true
    }

    func windowDidResignKey(_ notification: Notification) {
        restorePointer()
        windowSession?.motion.update { $0.endWritingBurst(); $0.setSidebarFileDragged(false) }
        windowSession?.flushForLifecycleEvent()
        forwardedWindowDelegate?.windowDidResignKey?(notification)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        windowSession?.motion.update { $0.noteIntentionalInteraction() }
        forwardedWindowDelegate?.windowDidBecomeKey?(notification)
    }

    func detachFromWindow() {
        restorePointer()
        windowSession?.motion.stop()
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let dragEndMonitor {
            NSEvent.removeMonitor(dragEndMonitor)
            self.dragEndMonitor = nil
        }
        if let window {
            if let accessory = titlebarAccessory,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            if window.delegate === self {
                window.delegate = forwardedWindowDelegate
            }
            if clioEditorSessionID(for: window) == windowSession?.id {
                objc_setAssociatedObject(
                    window,
                    &clioEditorWindowSessionKey,
                    nil,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            }
        }
        forwardedWindowDelegate = nil
        titlebarAccessory = nil
        sidebarButton = nil
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector)
            || forwardedWindowDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedWindowDelegate?.responds(to: selector) == true {
            return forwardedWindowDelegate
        }
        return super.forwardingTarget(for: selector)
    }

    private func installScrollMonitor(for window: NSWindow) {
        guard scrollMonitor == nil else { return }
        window.acceptsMouseMovedEvents = true
        dragEndMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.windowSession?.motion.update { $0.setSidebarFileDragged(false) }
        }
        windowSession?.motion.chrome.seedPointerLocation(.init(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y))
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) {
            [weak self, weak window] event in
            guard let self, (event.window ?? NSApplication.shared.keyWindow) === window,
                  let motion = self.windowSession?.motion else { return event }
            if event.type == .scrollWheel {
                if motion.handleScroll(event) { return nil }
            } else if event.type == .mouseMoved {
                let location = NSEvent.mouseLocation
                motion.update { $0.pointerMoved(to: .init(x: location.x, y: location.y)) }
            } else if event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp {
                motion.update { $0.noteIntentionalInteraction() }
                if event.locationInWindow.x < 252, motion.chrome.isSidebarIntendedVisible {
                    motion.update { $0.recordSidebarInteraction() }
                    if event.type == .leftMouseDragged { motion.update { $0.setSidebarFileDragged(true) } }
                }
                if event.type == .leftMouseUp { motion.update { $0.setSidebarFileDragged(false) } }
            } else if event.type == .keyDown,
                      event.modifierFlags.contains(.command) || [53, 123, 124, 125, 126].contains(event.keyCode) {
                motion.update { $0.noteIntentionalInteraction() }
                if event.keyCode == 53 { motion.update { $0.setSidebarFileDragged(false) } }
            }
            return event
        }
    }

    private func installTitlebarControl(in window: NSWindow) {
        guard titlebarAccessory == nil else { updateNativeChrome(); return }
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 38, height: 28))
        let button = InteractionButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")!, target: self, action: #selector(toggleSidebar))
        button.frame = NSRect(x: 4, y: 2, width: 30, height: 24)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.refusesFirstResponder = true
        button.setAccessibilityIdentifier("sidebar.toggle")
        button.setAccessibilityRole(.button)
        container.addSubview(button)
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)
        titlebarAccessory = accessory
        sidebarButton = button
        updateNativeChrome()
    }

    @objc private func toggleSidebar() { windowSession?.toggleSidebar() }

    private func updateNativeChrome() {
        guard let window, let session = windowSession else { return }
        let progress = session.motion.chrome.titlebar.presentation
        for button in [window.standardWindowButton(.closeButton), window.standardWindowButton(.miniaturizeButton), window.standardWindowButton(.zoomButton), sidebarButton].compactMap({ $0 }) {
            if button.alphaValue != progress { button.alphaValue = progress }
            if button.isEnabled != (progress > 0.001) { button.isEnabled = progress > 0.001 }
            if button.isHidden != (progress <= 0.001) { button.isHidden = progress <= 0.001 }
        }
        let label = session.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        if sidebarButton?.toolTip != label {
            sidebarButton?.toolTip = label
            sidebarButton?.setAccessibilityLabel(label)
        }
        if hidesPointerWhileTyping, session.motion.chrome.pointer.target == 0,
           session.motion.chrome.pointer.presentation <= 0.001, window.isKeyWindow {
            if !pointerIsHidden { NSCursor.hide(); pointerIsHidden = true }
        } else { restorePointer() }
    }

    func restorePointerIfDisabled() {
        if !hidesPointerWhileTyping { restorePointer() }
    }

    private func restorePointer() {
        if pointerIsHidden { NSCursor.unhide(); pointerIsHidden = false }
    }
}

extension AppState.AccentPreset {
    var color: Color {
        Color(nsColor: nsColor)
    }
}

private struct SurfacePresentation: ViewModifier {
    let progress: Double
    let y: Double
    let scale: Double
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        content.opacity(progress)
            .offset(y: reduceMotion ? 0 : y * (1 - progress))
            .scaleEffect(reduceMotion ? 1 : scale + (1 - scale) * progress)
    }
}

/// AppKit titlebar controls participate in the same cursor behavior as sidebar rows.
final class InteractionButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
