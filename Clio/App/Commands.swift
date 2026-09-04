import SwiftUI

private struct EditorSessionFocusedValueKey: FocusedValueKey {
    typealias Value = EditorSession
}

private struct EditorWindowSessionFocusedValueKey: FocusedValueKey {
    typealias Value = EditorWindowSession
}

extension FocusedValues {
    var editorSession: EditorSession? {
        get { self[EditorSessionFocusedValueKey.self] }
        set { self[EditorSessionFocusedValueKey.self] = newValue }
    }


    var editorWindowSession: EditorWindowSession? {
        get { self[EditorWindowSessionFocusedValueKey.self] }
        set { self[EditorWindowSessionFocusedValueKey.self] = newValue }
    }
}

struct ClioCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Bindable private var appState: AppState
    @FocusedValue(\.editorSession) private var editorSession
    @FocusedValue(\.editorWindowSession) private var editorWindowSession

    init(appState: AppState) {
        self.appState = appState
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Document") {
                if let editorWindowSession {
                    editorWindowSession.newDocument()
                } else {
                    openWindow(id: "editor", value: EditorWindowRequest.newDocument())
                }
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Window") {
                openWindow(id: "editor", value: EditorWindowRequest.newDocument())
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                editorSession?.saveNow()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(editorSession?.isReady != true)
        }


        CommandGroup(after: .newItem) {
            Button("Open…") {
                if let editorWindowSession {
                    appState.openDocumentPicker(from: editorWindowSession)
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(editorWindowSession == nil)

            Button("Search Workspaces…") {
                editorWindowSession?.presentPalette(
                    source: .keyboardShortcut,
                    mode: .search
                )
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(editorWindowSession == nil)
        }

        CommandMenu("Writing") {
            Button("Command Palette…") {
                editorWindowSession?.presentPalette(source: .keyboardShortcut)
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(editorWindowSession == nil)

            Button(editorWindowSession?.isSidebarVisible == true
                ? "Hide Sidebar"
                : "Show Sidebar") {
                editorWindowSession?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(editorWindowSession == nil)

            Divider()

            Toggle("Focus Mode", isOn: $appState.isFocusModeEnabled)
                .keyboardShortcut("d", modifiers: .command)

            Toggle("Typewriter Scrolling", isOn: $appState.isTypewriterModeEnabled)
                .keyboardShortcut("t", modifiers: .command)

            Toggle("Check Spelling", isOn: $appState.isSpellCheckingEnabled)

            Divider()

            Button("Increase Text Size") {
                appState.adjustFontSize(by: 1)
            }
            .keyboardShortcut("+", modifiers: .command)

            Button("Decrease Text Size") {
                appState.adjustFontSize(by: -1)
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Reset Text Size") {
                appState.resetFontSize()
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
