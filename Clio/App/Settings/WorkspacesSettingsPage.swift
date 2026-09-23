import SwiftUI

struct WorkspacesSettingsPage: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        @Bindable var discovery = appState.discoverySettings
        Form {
            Section("Folders") {
                if appState.workspaceDescriptors.isEmpty {
                    Text("No folders selected")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.workspaceDescriptors) { workspace in
                        LabeledContent(workspace.displayName) {
                            HStack {
                                Text(workspace.rootURL.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(workspace.rootURL.path)
                                    .foregroundStyle(.secondary)
                                Button("Remove") {
                                    appState.removeWorkspace(workspace.id)
                                }
                                .buttonStyle(.borderless)
                                .interactionCursor()
                            }
                        }
                    }
                }

                ForEach(appState.workspaceCatalog.authorizationFailures) { failure in
                    LabeledContent(failure.folderName) {
                        HStack {
                            Label("Access required", systemImage: "lock.trianglebadge.exclamationmark")
                                .foregroundStyle(.orange)
                            Button("Restore…") {
                                appState.reauthorizeWorkspace(failure)
                            }
                            Button("Forget") {
                                appState.removeWorkspace(failure.id)
                            }
                            .buttonStyle(.borderless)
                            .interactionCursor()
                        }
                    }
                    .help(failure.message)
                }

                HStack {
                    Button("Use Documents/Clio") {
                        appState.chooseDefaultWorkspace()
                    }

                    Button("Add Folder…") {
                        appState.chooseAnotherWorkspace()
                    }
                }

                if let errorMessage = appState.workspaceErrorMessage {
                    Label {
                        Text(errorMessage)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(appState.accent.color)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Recovery") {
                LabeledContent("Recovery folder") {
                    HStack {
                        Text(recoveryFolderDisplayText)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(appState.recoveryFolderURL?.path ?? "")
                        Button("Change…") { appState.changeRecoveryFolder() }
                            .accessibilityIdentifier("settings.workspaces.recoveryFolder")
                    }
                }
                SettingsFootnote("Clio writes a recovery copy here before replacing either side of a conflict. Copies are kept for seven days.")
            }

            Section("Discovery") {
                Toggle("Respect nested .gitignore files", isOn: $discovery.respectsGitIgnore)
                Toggle("Include hidden files", isOn: $discovery.includesHiddenFiles)
                Toggle("Include .txt files", isOn: $discovery.includesTextFiles)
                Toggle("Show ignored files temporarily", isOn: $discovery.temporarilyShowsIgnored)

                DisclosureGroup("Built-in exclusions") {
                    ForEach(BuiltInExclusion.allCases) { exclusion in
                        Toggle(
                            exclusion.displayName,
                            isOn: Binding(
                                get: { discovery.enabledBuiltIns.contains(exclusion) },
                                set: { discovery.set(exclusion, enabled: $0) }
                            )
                        )
                    }
                }

                LabeledContent("Additional Git patterns") {
                    TextEditor(text: $discovery.additionalPatternsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minWidth: 140, maxWidth: 260)
                        .frame(height: 66)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(nsColor: Palette.hairline))
                        }
                        .help("One gitignore-style exclusion pattern per line")
                }
            }
        }
        .onChange(of: discovery.policy) { _, _ in
            appState.discoveryPolicyDidChange()
        }
    }

    /// The recovery folder is authorized as soon as it is set (its path is
    /// never cleared), so a stale-looking path never survives an access
    /// failure: `needsRecoveryAuthorization` always wins the display.
    private var recoveryFolderDisplayText: String {
        if appState.needsRecoveryAuthorization {
            return "Access required"
        }
        return appState.recoveryFolderURL?.path ?? ""
    }
}
