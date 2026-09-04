import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

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
                Picker("Literal accent", selection: $appState.accent) {
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
                LabeledContent("Folder") {
                    Text(appState.workspaceRootPath ?? "Not selected")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(appState.workspaceRootPath ?? "No workspace selected")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Use Documents/Clio") {
                        appState.chooseDefaultWorkspace()
                    }

                    Button(appState.workspaceRootPath == nil ? "Choose Another Folder…" : "Change Folder…") {
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
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .tint(appState.accent.color)
        .frame(width: 500, height: 590)
        .background(Color(nsColor: Palette.background))
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
                    .frame(width: 220)

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
                .frame(width: 220)

                Text(valueLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 110, alignment: .trailing)
            }
        }
    }
}
