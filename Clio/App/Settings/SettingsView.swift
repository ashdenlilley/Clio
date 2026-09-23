import SwiftUI

/// The Settings panel: a category list beside one page. Presented inside the
/// editor window by `ContentView`; the panel's glass is applied there, so
/// nothing in here draws its own glass background (no glass on glass). The
/// selected category is drawn with a plain accent fill instead.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.clioAccent) private var accent
    let done: () -> Void
    let doneFocus: FocusState<Bool>.Binding
    let compact: Bool

    var body: some View {
        let selection = appState.appPreferences.lastSettingsCategory
        HStack(spacing: 0) {
            categoryList(selection: selection)
                .frame(width: compact ? 52 : 176)
                .padding(.vertical, 12)
            Divider().opacity(0.4)
            VStack(spacing: 0) {
                HStack {
                    Text(selection.title).font(.headline)
                    Spacer()
                    Button("Done", action: done)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.cancelAction)
                        .focused(doneFocus)
                }
                .padding(16)
                page(for: selection)
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
            }
        }
        .tint(appState.accent.color)
    }

    private func categoryList(selection: SettingsCategory) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { category in
                let isSelected = category == selection
                Button {
                    appState.appPreferences.lastSettingsCategory = category
                } label: {
                    Label(category.title, systemImage: category.symbol)
                        .labelStyle(CategoryLabelStyle(compact: compact))
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: compact ? .center : .leading)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(accent.opacity(ClioGlass.selectedTintOpacity))
                    }
                }
                .opacity(isSelected ? 1 : 0.85)
                .help(category.title)
                .accessibilityIdentifier("settings.category.\(category.rawValue)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder private func page(for category: SettingsCategory) -> some View {
        switch category {
        case .general: GeneralSettingsPage()
        case .editor: EditorSettingsPage()
        case .writing: WritingSettingsPage()
        case .workspaces: WorkspacesSettingsPage()
        case .export: ExportSettingsPage()
        case .assisted: AssistedCommandsSettingsPage()
        case .localMCP: LocalMCPSettingsPage()
        }
    }
}

private struct CategoryLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 18)
            if !compact { configuration.title }
        }
    }
}
