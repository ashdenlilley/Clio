import SwiftUI

struct ExportSettingsPage: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorWindowSession.self) private var windowSession

    var body: some View {
        @Bindable var app = appState.appPreferences
        let presentation = windowSession.exportPresentation
        Form {
            Section("Format") {
                Picker("Default format", selection: $app.defaultExportFormat) {
                    Text("PDF").tag(ExportFormat.pdf)
                    Text("Word (.docx)").tag(ExportFormat.docx)
                    Text("Plain Text (.txt)").tag(ExportFormat.txt)
                    Text("HTML").tag(ExportFormat.html)
                }
                .accessibilityIdentifier("settings.export.defaultFormat")
            }
            Section("PDF Page Setup") {
                LabeledContent("Page", value: presentation.pageSetupSummary)
                HStack {
                    Button("Page Setup…") { presentation.presentPageSetup() }
                        .accessibilityIdentifier("settings.export.pageSetup")
                    Button("Reset to Regional Default") { presentation.printSettingsStore.resetToRegionalDefault() }
                        .accessibilityIdentifier("settings.export.resetPageSetup")
                }
            }
        }
    }
}
