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

        Settings {
            SettingsView()
                .environment(applicationDelegate.appState)
                .preferredColorScheme(.dark)
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
            .focusedSceneValue(\.editorWindowSession, windowSession)
            .focusedSceneValue(\.editorSession, windowSession.activeTab)
            .onAppear {
                windowSession.connect(to: appState)
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
    let appState: AppState
    let initialWindowRequest: EditorWindowRequest

    override init() {
        #if DEBUG
        CrashTestDriver.runIfRequested()
        #endif
        let configuration = ClioLaunchConfiguration.current()
        appState = configuration.appState
        initialWindowRequest = configuration.initialWindowRequest
        super.init()
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

        return .terminateNow
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
