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
            .mostRecent()
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
    @State private var editorSession: EditorSession

    init(request: Binding<EditorWindowRequest>, appState: AppState) {
        _request = request
        self.appState = appState
        let initialRequest = request.wrappedValue
        _editorSession = State(
            initialValue: EditorSession(
                id: initialRequest.id,
                openingMode: initialRequest.openingMode,
                restoredRelativePath: initialRequest.relativePath,
                startInFullScreen: initialRequest.isFullScreen
            )
        )
    }

    var body: some View {
        ContentView()
            .environment(editorSession)
            .focusedSceneValue(\.editorSession, editorSession)
            .onAppear {
                appState.register(editorSession)
            }
            .onDisappear {
                appState.unregister(editorSession)
            }
            .onChange(of: editorSession.relativePath) { _, relativePath in
                guard !relativePath.isEmpty,
                      request.relativePath != relativePath else { return }
                request.relativePath = relativePath
            }
            .onChange(of: editorSession.isReady, initial: true) { _, isReady in
                guard isReady,
                      editorSession.fileURL == nil,
                      request.openingMode == .mostRecent else { return }
                editorSession.resolveAsNewDocument()
                request.openingMode = .newDocument
            }
            .onChange(of: editorSession.isFullScreenEnabled) { _, isFullScreen in
                request.isFullScreen = isFullScreen
            }
    }
}

@MainActor
final class ClioApplicationDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState

    override init() {
        appState = AppState()
        super.init()
    }

    init(appState: AppState) {
        self.appState = appState
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
