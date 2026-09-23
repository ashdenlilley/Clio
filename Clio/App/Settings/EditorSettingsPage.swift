import SwiftUI

struct EditorSettingsPage: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        @Bindable var preferences = appState.preferences
        Form {
            Section("Typography") {
                LabeledContent("Editor font") {
                    NativeEditorFontPicker(name: $appState.editorFontName, size: $appState.fontSize)
                        .frame(maxWidth: 260)
                    Button("Reset") { appState.editorFontName = "Hack-Regular" }
                }
                Text("Applies to the editor only. Documents remain plain Markdown. Font size is limited to 12–20 pt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SliderRow(
                    title: "Font size",
                    value: $appState.fontSize,
                    range: 12...20,
                    step: 1,
                    valueLabel: "\(Int(appState.fontSize)) pt"
                )

                IntegerSliderRow(
                    title: "Measure",
                    value: $appState.measure,
                    range: 60...90,
                    valueLabel: "\(appState.measure) characters"
                )

                SliderRow(
                    title: "Line height",
                    value: $appState.lineHeight,
                    range: 1.2...2.0,
                    step: 0.05,
                    valueLabel: appState.lineHeight.formatted(.number.precision(.fractionLength(2)))
                )
            }

            Section("Caret") {
                Picker("Caret", selection: $preferences.caretStyle) {
                    ForEach(CaretStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.editor.caret")
            }

            Section("Chrome") {
                Toggle("Show minimap", isOn: $preferences.showsMinimap)
                    .accessibilityIdentifier("settings.editor.minimap")
                Toggle("Show status line", isOn: $preferences.showsStatusLine)
                    .accessibilityIdentifier("settings.editor.statusLine")
                Toggle("Reading time", isOn: $preferences.showsReadingTime)
                    .disabled(!preferences.showsStatusLine)
                    .accessibilityIdentifier("settings.editor.readingTime")
                Toggle("Speaking time", isOn: $preferences.showsSpeakingTime)
                    .disabled(!preferences.showsStatusLine)
                    .accessibilityIdentifier("settings.editor.speakingTime")
            }
        }
    }
}
