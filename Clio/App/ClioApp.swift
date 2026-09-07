import AppKit
import SwiftUI

@main
struct ClioApp: App {
    @NSApplicationDelegateAdaptor(ClioApplicationDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        WindowGroup(
            "Clio",
            id: "editor",
            for: EditorWindowRequest.self
        ) { request in
            EditorWindowRoot(
                request: request,
                appState: applicationDelegate.appState
            )
            .environment(applicationDelegate.appState)
            .preferredColorScheme(.dark)
        } defaultValue: {
            applicationDelegate.initialWindowRequest
        }
        .defaultSize(width: 900, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            ClioCommands(appState: applicationDelegate.appState)
        }

    }
}

private struct EditorWindowRoot: View {
    let appState: AppState
    @Binding private var request: EditorWindowRequest
    @State private var windowSession: EditorWindowSession

    init(request: Binding<EditorWindowRequest>, appState: AppState) {
        _request = request
        self.appState = appState
        let initialRequest = request.wrappedValue
        _windowSession = State(
            initialValue: EditorWindowSession(request: initialRequest)
        )
    }

    var body: some View {
        ContentView()
            .environment(windowSession)
            .environment(windowSession.exportPresentation)
            .focusedSceneValue(\.editorWindowSession, windowSession)
            .focusedSceneValue(\.editorSession, windowSession.activeTab)
            .focusedSceneValue(\.documentExportPresentation, windowSession.exportPresentation)
            .onAppear {
                ClioLaunchDiagnostics.mark("editor-window-appeared")
                windowSession.connect(to: appState)
                ClioLaunchDiagnostics.mark("editor-session-connected")
            }
            .task {
                // Opt-in profiling fixture: no AX queries or screenshot work
                // during the measured sequence, and never real user storage.
                let environment = ProcessInfo.processInfo.environment
                guard environment["CLIO_UI_TESTING"] == "1",
                      environment["CLIO_UI_TEST_MOTION_TRACE"] == "1" else { return }
                var frameGaps: [Double] = []
                var frameWork: [Double] = []
                var firstFrameLatencies: [Double] = []
                var previousFrame: (UInt64, TimeInterval)?
                windowSession.motion.frameSample = { generation, time, duration, firstFrameLatency in
                    if let firstFrameLatency { firstFrameLatencies.append(firstFrameLatency * 1_000) }
                    if let previousFrame, previousFrame.0 == generation {
                        frameGaps.append((time - previousFrame.1) * 1_000)
                    }
                    previousFrame = (generation, time)
                    frameWork.append(duration * 1_000)
                }
                defer { windowSession.motion.frameSample = nil }
                do {
                    try await Task.sleep(for: .seconds(2))
                    for _ in 0..<40 {
                        windowSession.toggleSidebar()
                        try await Task.sleep(for: .milliseconds(95))
                    }
                    for _ in 0..<8 {
                        windowSession.toggleSidebar()
                        try await Task.sleep(for: .milliseconds(350))
                    }
                    let identifier = environment["CLIO_UI_TEST_ID"] ?? "unknown"
                    let screenFPS = windowSession.motion.window?.screen?.maximumFramesPerSecond ?? 60
                    let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                    let range = WindowMotionAdapter.frameRateRange(maximumFPS: screenFPS, lowPower: lowPower)
                    let metrics: [String: Any] = [
                        "frameCount": frameWork.count,
                        "frameGapsMS": frameGaps,
                        "frameWorkMS": frameWork,
                        "firstFrameLatenciesMS": firstFrameLatencies,
                        "maximumScreenFPS": screenFPS,
                        "preferredFPS": range.preferred,
                        "minimumFPS": range.minimum,
                        "maximumFPS": range.maximum,
                        "lowPowerMode": lowPower
                    ]
                    let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
                    try data.write(to: FileManager.default.temporaryDirectory
                        .appendingPathComponent("ClioMotionMetrics-\(identifier).json"), options: .atomic)
                } catch { /* Window closure cancels the fixture. */ }
            }
            .onDisappear {
                windowSession.disconnect()
            }
            .onChange(of: windowSession.restorationState, initial: true) { _, state in
                request.restoration = state
                request.relativePath = windowSession.activeTab?.relativePath
                request.isFullScreen = state.isFullScreen
                if windowSession.tabs.count == 1,
                   windowSession.activeTab?.isReady == true,
                   windowSession.activeTab?.fileURL == nil {
                    request.openingMode = .newDocument
                }
            }
    }
}

@MainActor
final class ClioApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationTextViews: [NSTextView] = []
    let appState: AppState
    let initialWindowRequest: EditorWindowRequest

    override init() {
        ClioLaunchDiagnostics.mark("application-delegate-init")
        let configuration = ClioLaunchConfiguration.current()
        ClioLaunchDiagnostics.mark("launch-configuration-ready")
        appState = configuration.appState
        initialWindowRequest = configuration.initialWindowRequest
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        ClioLaunchDiagnostics.mark("application-will-finish-launching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClioLaunchDiagnostics.mark("application-did-finish-launching")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ClioLaunchDiagnostics.mark("application-became-active")
    }

    init(appState: AppState) {
        self.appState = appState
        initialWindowRequest = .mostRecent()
        super.init()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "Clio")

        let newDocumentItem = NSMenuItem(
            title: "New Document",
            action: #selector(openNewDocumentFromDock(_:)),
            keyEquivalent: ""
        )
        newDocumentItem.target = self
        menu.addItem(newDocumentItem)

        let newWindowItem = NSMenuItem(
            title: "New Window",
            action: #selector(openNewWindowFromDock(_:)),
            keyEquivalent: ""
        )
        newWindowItem.target = self
        menu.addItem(newWindowItem)

        return menu
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        appState.enqueueExternalDocumentURLs(urls)
        if !application.windows.contains(where: isClioEditorWindow) {
            _ = performWindowCommand(titled: "New Window")
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard appState.flushAllEditorSessions() else {
            sender.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Clio couldn’t save every document"
            alert.informativeText = "Quit was cancelled so your unsaved text remains in Clio. Restore workspace access or free disk space, then try again."
            alert.addButton(withTitle: "Keep Clio Open")
            alert.runModal()
            return .terminateCancel
        }

        // AppKit may still have deferred drag-registration work queued for a
        // text view as SwiftUI dismantles the window. Keep live text views and
        // their TextKit stacks alive until process exit, only after saves pass.
        terminationTextViews = sender.windows.filter(isClioEditorWindow).flatMap {
            Self.textViews(in: $0.contentView)
        }
        ClioLaunchDiagnostics.mark("quit-save-flush-complete")
        return .terminateNow
    }

    private static func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        return (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        let editorWindow = [sender.keyWindow, sender.mainWindow]
            .compactMap { $0 }
            .first(where: isClioEditorWindow)
            ?? sender.windows.first {
                isClioEditorWindow($0) && $0.isVisible
            }
            ?? sender.windows.first(where: isClioEditorWindow)

        if let editorWindow {
            sender.activate(ignoringOtherApps: true)
            if editorWindow.isMiniaturized {
                editorWindow.deminiaturize(nil)
            }
            editorWindow.makeKeyAndOrderFront(nil)
        } else {
            return !performWindowCommand(titled: "New Window")
        }

        return false
    }

    @objc
    private func openNewDocumentFromDock(_ sender: Any?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        performWindowCommand(titled: "New Document")
    }

    @objc
    private func openNewWindowFromDock(_ sender: Any?) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        performWindowCommand(titled: "New Window")
    }

    @discardableResult
    private func performWindowCommand(titled title: String) -> Bool {
        guard let mainMenu = NSApplication.shared.mainMenu,
              let menuItem = menuItem(titled: title, in: mainMenu),
              menuItem.isEnabled else { return false }

        guard let action = menuItem.action else { return false }
        return NSApplication.shared.sendAction(
            action,
            to: menuItem.target,
            from: menuItem
        )
    }

    private func menuItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title, item.action != nil {
                return item
            }

            if let submenu = item.submenu,
               let match = menuItem(titled: title, in: submenu) {
                return match
            }
        }

        return nil
    }
}
