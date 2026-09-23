import SwiftUI

struct GeneralSettingsPage: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var app = appState.appPreferences
        @Bindable var appState = appState
        Form {
            Section("Startup") {
                Picker("When Clio opens", selection: $app.launchBehavior) {
                    ForEach(LaunchBehavior.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.general.launch")
                SettingsFootnote("Applies to the first window when macOS has no windows to restore.")
            }
            Section("New Windows") {
                Toggle("Show sidebar", isOn: $app.showsSidebarInNewWindows)
                    .accessibilityIdentifier("settings.general.sidebarVisible")
                Toggle("Pin sidebar", isOn: $app.pinsSidebarInNewWindows)
                    .disabled(!app.showsSidebarInNewWindows)
                    .accessibilityIdentifier("settings.general.sidebarPinned")
            }
            Section("Appearance") {
                Picker("Accent colour", selection: $appState.accent) {
                    ForEach(AppState.AccentPreset.allCases) { accent in
                        Label {
                            Text(accent.title)
                        } icon: {
                            Image(nsImage: AccentSwatch.image(for: accent.nsColor))
                                .renderingMode(.original)
                        }
                        .tag(accent)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }
}
