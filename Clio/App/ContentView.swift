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
    @Environment(EditorSession.self) private var editorSession

    var body: some View {
        @Bindable var appState = appState
        @Bindable var editorSession = editorSession

        Group {
            if appState.isWorkspaceReady, editorSession.isReady {
                VStack(spacing: 0) {
                    EditorView(
                        text: editorSession.draftText,
                        contentGeneration: editorSession.bufferGeneration,
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
                        onTextEdit: editorSession.editorTextDidChange
                    )

                    StatusLine(
                        relativePath: editorSession.relativePath,
                        wordCountLabel: editorSession.wordCountLabel,
                        fontSize: appState.fontSize,
                        accent: appState.accent
                    )
                }
                .task(id: editorSession.contentRevision) {
                    editorSession.refreshDerivedStateForCurrentRevision()
                }
                .overlay(alignment: .top) {
                    if editorSession.requiresExplicitRestore {
                        DetachedDocumentBanner(
                            filename: editorSession.filename,
                            restore: editorSession.saveNow
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
                startInFullScreen: editorSession.isFullScreenEnabled,
                editorSession: editorSession
            )
        )
        .sheet(
            isPresented: Binding(
                get: { editorSession.activeConflict != nil },
                set: { _ in }
            )
        ) {
            if let conflict = editorSession.activeConflict {
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
                get: { editorSession.pendingCollision != nil },
                set: { _ in }
            ),
            presenting: editorSession.pendingCollision
        ) { _ in
            Button("Cancel", role: .cancel) {
                editorSession.resolveCollision(.cancel)
            }
            Button("Keep Both") {
                editorSession.resolveCollision(.keepBoth)
            }
            Button("Replace", role: .destructive) {
                editorSession.resolveCollision(.replace)
            }
        } message: { collision in
            Text("\(collision.proposedLocator.relativePath) is already present. Replace it or keep both using the next “name (2).md” variant.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  clioEditorSessionID(for: window) == editorSession.id else { return }
            editorSession.isFullScreenEnabled = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  clioEditorSessionID(for: window) == editorSession.id else { return }
            editorSession.isFullScreenEnabled = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            editorSession.flushForLifecycleEvent()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            editorSession.flushForLifecycleEvent()
        }
    }
}

private struct DetachedDocumentBanner: View {
    let filename: String
    let restore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.badge.clock")
                .foregroundStyle(.orange)
            Text("\(filename) was removed from disk. Its text is safe in Clio and will not be recreated automatically.")
            Spacer(minLength: 8)
            Button("Restore Document", action: restore)
                .keyboardShortcut(.defaultAction)
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
    let conflict: DocumentConflict
    let isResolving: Bool
    let resolve: (ConflictChoice) -> Void
    @State private var preview = "Preparing a bounded preview…"

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
                Text(preview)
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
            preview = await ConflictPreviewBuilder.preview(for: conflict)
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
    let startInFullScreen: Bool
    let editorSession: EditorSession

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.startInFullScreen = startInFullScreen
        view.editorSession = editorSession
        return view
    }

    func updateNSView(_ view: WindowProbeView, context: Context) {
        view.startInFullScreen = startInFullScreen
        view.editorSession = editorSession
        view.configureWindowIfNeeded()
    }

    static func dismantleNSView(_ view: WindowProbeView, coordinator: ()) {
        view.detachFromWindow()
    }
}

private final class WindowProbeView: NSView, NSWindowDelegate {
    var startInFullScreen = false
    weak var editorSession: EditorSession?

    private var hasAppliedInitialState = false
    private var forwardedWindowDelegate: NSWindowDelegate?

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
        guard let window else { return }

        let relativePath = editorSession?.relativePath ?? ""
        let documentTitle = relativePath.isEmpty ? "Untitled" : relativePath
        window.title = "\(documentTitle) — Clio"
        window.miniwindowTitle = documentTitle
        window.representedURL = editorSession?.fileURL
        if let editorSession {
            markAsClioEditorWindow(window, sessionID: editorSession.id)
        }
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

        guard !hasAppliedInitialState else { return }
        hasAppliedInitialState = true

        if startInFullScreen, !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editorSession?.flushForLifecycleEvent() != false else {
            sender.makeKeyAndOrderFront(nil)

            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Clio couldn’t save your document"
            alert.informativeText = "The window stayed open so your unsaved text remains visible. Restore access to the workspace or free disk space, then try again."
            alert.addButton(withTitle: "Keep Writing")
            alert.beginSheetModal(for: sender)
            return false
        }

        return forwardedWindowDelegate?.windowShouldClose?(sender) ?? true
    }

    func windowDidResignKey(_ notification: Notification) {
        editorSession?.flushForLifecycleEvent()
        forwardedWindowDelegate?.windowDidResignKey?(notification)
    }

    func detachFromWindow() {
        if let window {
            if window.delegate === self {
                window.delegate = forwardedWindowDelegate
            }
            if clioEditorSessionID(for: window) == editorSession?.id {
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
