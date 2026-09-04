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

    var body: some View {
        Group {
            if let editorSession = windowSession.activeTab, editorSession.isReady {
                HStack(spacing: 0) {
                    if windowSession.isSidebarVisible {
                        WorkspaceSidebar()
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }

                    editorPane(editorSession)
                }
                .overlay(alignment: .topLeading) {
                    if !windowSession.isSidebarVisible {
                        SidebarToggleButton()
                            .padding(.leading, 76)
                            .padding(.top, 7)
                    }
                }
                .overlay {
                    if windowSession.isPalettePresented {
                        ZStack(alignment: .top) {
                            Color.black.opacity(0.38)
                                .ignoresSafeArea()
                                .contentShape(Rectangle())
                                .onTapGesture { windowSession.dismissPalette() }

                            CommandPaletteView()
                                .padding(.top, 58)
                        }
                        .transition(.opacity)
                    }
                }
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
        .frame(
            minWidth: Metrics.minimumWindowWidth,
            minHeight: Metrics.minimumWindowHeight
        )
        .background(Color(nsColor: Palette.background))
        .background(
            WindowChromeProbe(
                windowSession: windowSession,
                editorSession: windowSession.activeTab
            )
        )
        .sheet(
            isPresented: Binding(
                get: { windowSession.activeTab?.activeConflict != nil },
                set: { _ in }
            )
        ) {
            if let editorSession = windowSession.activeTab,
               let conflict = editorSession.activeConflict {
                ConflictResolutionView(
                    conflict: conflict,
                    isResolving: editorSession.isResolvingConflict,
                    resolve: editorSession.resolveConflict
                )
                .interactiveDismissDisabled()
            }
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
        VStack(spacing: 0) {
            EditorView(
                text: editorSession.draftText,
                contentGeneration: editorSession.bufferGeneration,
                viewport: Binding(
                    get: { editorSession.viewportState },
                    set: { editorSession.updateViewport($0) }
                ),
                configuration: EditorConfiguration(
                    fontSize: CGFloat(appState.fontSize),
                    measure: appState.measure,
                    lineHeightMultiple: CGFloat(appState.lineHeight),
                    isSpellCheckingEnabled: appState.isSpellCheckingEnabled,
                    isTypewriterScrollingEnabled: appState.isTypewriterModeEnabled,
                    typewriterAnchor: CGFloat(appState.typewriterAnchor),
                    isFocusModeEnabled: appState.isFocusModeEnabled,
                    focusDimmingOpacity: CGFloat(appState.focusDimmingOpacity)
                ),
                onTextEdit: { edit in
                    windowSession.noteEditorEdit(edit)
                },
                onSlashCommand: {
                    windowSession.presentInlineSlashPalette()
                }
            )

            StatusLine(
                relativePath: editorSession.relativePath,
                wordCountLabel: editorSession.wordCountLabel,
                fontSize: appState.fontSize,
                accent: appState.accent
            )
        }
        .background(Color(nsColor: Palette.background))
    }

    private func restoreEditorFocus() {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: {
                clioEditorSessionID(for: $0) == windowSession.id
            }), let contentView = window.contentView,
              let editor = findEditorTextView(in: contentView) else { return }
            window.makeFirstResponder(editor)
        }
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
            }
            .disabled(isResolving)
        }
        .padding(24)
        .frame(width: 560)
        .background(Color(nsColor: Palette.background))
        .accessibilityElement(children: .contain)
        .task(id: conflict.id) {
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
    let fontSize: Double
    let accent: AppState.AccentPreset

    var body: some View {
        HStack(spacing: 16) {
            Text(relativePath)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Spacer(minLength: 40)

            Text(wordCountLabel)
                .fixedSize()
        }
        .overlay {
            Text("❯")
                .foregroundStyle(accent.color)
                .accessibilityHidden(true)
        }
        .font(.custom(Typography.family, fixedSize: fontSize * 0.85))
        .foregroundStyle(Color(nsColor: Palette.muted))
        .padding(.horizontal, 18)
        .frame(height: Metrics.statusHeight)
        .background(Color(nsColor: Palette.background))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(relativePath), \(wordCountLabel)")
    }
}

private struct WindowChromeProbe: NSViewRepresentable {
    let windowSession: EditorWindowSession
    let editorSession: EditorSession?

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.windowSession = windowSession
        view.editorSession = editorSession
        view.configureWindowIfNeeded()
        return view
    }

    func updateNSView(_ view: WindowProbeView, context: Context) {
        view.windowSession = windowSession
        view.editorSession = editorSession
        view.configureWindowIfNeeded()
    }

    static func dismantleNSView(_ view: WindowProbeView, coordinator: ()) {
        view.detachFromWindow()
    }
}

private final class WindowProbeView: NSView, NSWindowDelegate {
    weak var windowSession: EditorWindowSession?
    weak var editorSession: EditorSession?

    private var hasAppliedInitialState = false
    private var forwardedWindowDelegate: NSWindowDelegate?
    private var scrollMonitor: Any?

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
        windowSession?.flushForLifecycleEvent()
        forwardedWindowDelegate?.windowDidResignKey?(notification)
    }

    func detachFromWindow() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let window {
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
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
            [weak self, weak window] event in
            guard let self, event.window === window,
                  event.hasPreciseScrollingDeltas,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.25 else {
                return event
            }
            let physicalDeltaX = event.isDirectionInvertedFromDevice
                ? -event.scrollingDeltaX
                : event.scrollingDeltaX
            self.windowSession?.handleHorizontalGesture(
                // AppKit reports a physical rightward swipe as a negative X
                // delta. The model uses positive values for reveal progress.
                deltaX: -physicalDeltaX,
                phaseEnded: event.phase == .ended || event.momentumPhase == .ended
            )
            return event
        }
    }
}

extension AppState.AccentPreset {
    var color: Color {
        switch self {
        case .green:
            Color(nsColor: Palette.literal)
        case .amber:
            Color(red: 0.922, green: 0.647, blue: 0.220)
        case .cyan:
            Color(red: 0.337, green: 0.776, blue: 0.851)
        }
    }
}
