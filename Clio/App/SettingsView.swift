import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        @Bindable var discovery = appState.discoverySettings

        Form {
            Section("Typography") {
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

            Section("Focus") {
                Toggle("Focus mode", isOn: $appState.isFocusModeEnabled)
                Toggle("Typewriter scrolling", isOn: $appState.isTypewriterModeEnabled)
                Toggle("Fade chrome while typing", isOn: $appState.isChromeFadeEnabled)

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

            Section("Editing") {
                Toggle("Check spelling", isOn: $appState.isSpellCheckingEnabled)
            }

            Section("Appearance") {
                Picker("Accent colour", selection: $appState.accent) {
                    ForEach(AppState.AccentPreset.allCases) { accent in
                        Label {
                            Text(accent.title)
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(accent.color)
                        }
                        .tag(accent)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Workspace") {
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

            Section("Workspace Rules") {
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
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .tint(appState.accent.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Palette.background))
        .onChange(of: discovery.policy) { _, _ in
            appState.discoveryPolicyDidChange()
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueLabel: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: $value, in: range, step: step)
                    .frame(minWidth: 100, maxWidth: 220)

                Text(valueLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 88, alignment: .trailing)
            }
        }
    }
}

private struct IntegerSliderRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let valueLabel: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { value = Int($0.rounded()) }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 1
                )
                .frame(minWidth: 100, maxWidth: 220)

                Text(valueLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 110, alignment: .trailing)
            }
        }
    }
}
