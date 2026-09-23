import SwiftUI

struct WritingSettingsPage: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        @Bindable var preferences = appState.preferences
        Form {
            Section("Focus") {
                Toggle("Focus mode", isOn: $appState.isFocusModeEnabled)
                    .help("Dims text outside the active paragraph or Markdown block; does not hide controls or move the viewport.")
                Toggle("Typewriter scrolling", isOn: $appState.isTypewriterModeEnabled)
                    .help("Keeps the typing line at the chosen position. Manual scrolling releases it; typing returns smoothly over two seconds.")
                Toggle("Fade chrome while typing", isOn: $appState.isChromeFadeEnabled)
                Toggle("Hide pointer while typing", isOn: $preferences.hidesPointerWhileTyping)
                    .disabled(!appState.isChromeFadeEnabled)
                    .accessibilityIdentifier("settings.writing.hidePointer")

                SliderRow(
                    title: "Typewriter position",
                    value: $appState.typewriterAnchor,
                    range: 0.3...0.6,
                    step: 0.05,
                    valueLabel: appState.typewriterAnchor.formatted(.percent)
                )

                SliderRow(
                    title: "Background text",
                    value: $appState.focusDimmingOpacity,
                    range: 0.1...0.6,
                    step: 0.05,
                    valueLabel: appState.focusDimmingOpacity.formatted(.percent)
                )
            }

            Section("Text") {
                Toggle("Check spelling", isOn: $appState.isSpellCheckingEnabled)
                Toggle("Check grammar", isOn: $preferences.isGrammarCheckingEnabled)
                    .disabled(!appState.isSpellCheckingEnabled)
                    .accessibilityIdentifier("settings.writing.grammar")
                SettingsFootnote("Grammar checking only runs while spelling is checked; AppKit performs it alongside spellchecking, not on its own.")
                Toggle("Smart quotes and dashes", isOn: $preferences.isSmartPunctuationEnabled)
                    .accessibilityIdentifier("settings.writing.smartPunctuation")
                SettingsFootnote("Off by default so Markdown stays literal: smart quotes change the characters written to disk.")
            }

            Section("Shortcuts") {
                Toggle("Slash command palette", isOn: $preferences.isSlashCommandEnabled)
                    .accessibilityIdentifier("settings.writing.slash")
                SettingsFootnote("Typing / opens commands. When off, / is always a literal slash; ⌘K still opens the palette.")
                Toggle("Wrap selection when typing * _ ~ `", isOn: $preferences.autoWrapsSelection)
                    .accessibilityIdentifier("settings.writing.autoWrap")
            }
        }
    }
}
