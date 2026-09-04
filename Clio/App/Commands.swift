import SwiftUI

private struct EditorSessionFocusedValueKey: FocusedValueKey {
    typealias Value = EditorSession
}

extension FocusedValues {
    var editorSession: EditorSession? {
        get { self[EditorSessionFocusedValueKey.self] }
        set { self[EditorSessionFocusedValueKey.self] = newValue }
    }
}

struct ClioCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Bindable private var appState: AppState
    @FocusedValue(\.editorSession) private var editorSession

    init(appState: AppState) {
        self.appState = appState
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Document") {
                openWindow(id: "editor", value: EditorWindowRequest.newDocument())
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Window") {
                openWindow(id: "editor", value: EditorWindowRequest.mostRecent())
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button(editorSession?.requiresExplicitRestore == true ? "Restore Document" : "Save") {
                editorSession?.saveNow()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(editorSession?.isReady != true)
        }

        CommandMenu("Writing") {
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
