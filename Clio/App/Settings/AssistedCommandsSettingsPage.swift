import SwiftUI

struct AssistedCommandsSettingsPage: View {
    @Environment(AppState.self) private var appState
    /// Held only until it reaches the Keychain, and cleared on save. The key
    /// itself never goes into `UserDefaults` or the view's persisted state.
    @State private var typeSafeKeyEntry = ""

    private var trimmedTypeSafeKeyEntry: String {
        typeSafeKeyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveTypeSafeKey() {
        guard !trimmedTypeSafeKeyEntry.isEmpty else { return }
        appState.intelligence.setAPIKey(trimmedTypeSafeKeyEntry)
        typeSafeKeyEntry = ""
    }

    var body: some View {
        Form {
            Section("TypeSafe") {
                Toggle(
                    "Enable assisted commands",
                    isOn: Binding(
                        get: { appState.intelligence.isEnabled },
                        set: { appState.intelligence.isEnabled = $0 }
                    )
                )
                .accessibilityIdentifier("settings.intelligence.enabled")

                Text("Clio is otherwise offline. Turning this on lets it send text to TypeSafe, a third-party service, to work out what a typed command means and to rebuild the structure of pasted plain text. Your documents are never uploaded on their own, and nothing is sent while this is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if appState.intelligence.isEnabled {
                    Toggle(
                        "Reformat long plain-text pastes",
                        isOn: Binding(
                            get: { appState.intelligence.formatsPastes },
                            set: { appState.intelligence.formatsPastes = $0 }
                        )
                    )
                    .accessibilityIdentifier("settings.intelligence.formatPastes")

                    Text("Sends the pasted text only, and only when it arrives with no Markdown of its own. The command bar sends what you typed there plus whether a document is open — never the document.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LabeledContent("Your API key") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                SecureField(
                                    appState.intelligence.hasAPIKey
                                        ? "Replace the stored key"
                                        : "Paste your TypeSafe API key",
                                    text: $typeSafeKeyEntry
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .accessibilityIdentifier("settings.intelligence.key")
                                .onSubmit { saveTypeSafeKey() }

                                Button("Save", action: saveTypeSafeKey)
                                    .disabled(trimmedTypeSafeKeyEntry.isEmpty)
                            }

                            HStack(spacing: 8) {
                                Label(
                                    appState.intelligence.hasAPIKey
                                        ? "A key is stored in your Keychain"
                                        : "No key stored",
                                    systemImage: appState.intelligence.hasAPIKey
                                        ? "key.fill"
                                        : "key"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("settings.intelligence.keyState")

                                if appState.intelligence.hasAPIKey {
                                    Button("Check") {
                                        Task { await appState.intelligence.verifyKey() }
                                    }
                                    .disabled(appState.intelligence.keyVerification == .checking)
                                    .accessibilityIdentifier("settings.intelligence.checkKey")
                                    Button("Remove") {
                                        appState.intelligence.clearAPIKey()
                                    }
                                    .accessibilityIdentifier("settings.intelligence.removeKey")
                                }
                            }
                        }
                    }

                    Text("The key is yours, not Clio's. It is kept in this macOS account's login Keychain, is never written to preferences or the app bundle, and is not synced to your other devices. Each person using this Mac adds their own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Link(
                        "Where to get a key",
                        destination: URL(string: "https://docs.typesafe.ai/introduction/quickstart")!
                    )
                    .font(.caption)
                }

                Text(appState.intelligence.statusDescription).font(.caption)
            }
        }
    }
}
