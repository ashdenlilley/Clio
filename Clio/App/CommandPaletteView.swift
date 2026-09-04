import SwiftUI

struct CommandPaletteView: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorWindowSession.self) private var windowSession
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: windowSession.paletteMode == .search
                    ? "magnifyingglass"
                    : "command")
                    .foregroundStyle(appState.accent.color)

                TextField(
                    windowSession.paletteMode == .search
                        ? "Search every workspace"
                        : "Type a command",
                    text: Binding(
                        get: { windowSession.paletteQuery },
                        set: { windowSession.updatePaletteQuery($0) }
                    )
                )
                .textFieldStyle(.plain)
                .focused($isQueryFocused)
                .font(.custom(Typography.family, fixedSize: 14))
                .onSubmit { chooseFirstResult() }

                if windowSession.paletteMode == .search {
                    Picker(
                        "Folder",
                        selection: Binding(
                            get: { windowSession.workspaceFilter },
                            set: { windowSession.updateWorkspaceFilter($0) }
                        )
                    ) {
                        Text("All Folders").tag(nil as WorkspaceID?)
                        ForEach(appState.workspaceDescriptors) { workspace in
                            Text(workspace.displayName).tag(Optional(workspace.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)

                    Toggle(
                        "Show Ignored",
                        isOn: Binding(
                            get: { appState.discoverySettings.temporarilyShowsIgnored },
                            set: { newValue in
                                appState.discoverySettings.temporarilyShowsIgnored = newValue
                                appState.discoveryPolicyDidChange()
                                windowSession.updatePaletteQuery(windowSession.paletteQuery)
                            }
                        )
                    )
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Include ignored documents and explain the matching rule")
                }

                Text("esc")
                    .font(.custom(Typography.family, fixedSize: 10))
                    .foregroundStyle(Color(nsColor: Palette.muted))
            }
            .padding(.horizontal, 15)
            .frame(height: 48)

            Rectangle()
                .fill(Color(nsColor: Palette.hairline))
                .frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 1) {
                    if windowSession.paletteMode == .commands {
                        commandResults
                    } else {
                        searchResults
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 620)
        .background(Color(nsColor: Palette.backgroundRaised))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: Palette.hairline), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.7), radius: 28, y: 12)
        .onAppear { isQueryFocused = true }
        .onExitCommand { windowSession.dismissPalette() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(windowSession.paletteMode == .search
            ? "Workspace search"
            : "Command palette")
    }

    @ViewBuilder
    private var commandResults: some View {
        if windowSession.filteredCommands.isEmpty {
            EmptyPaletteRow(message: "No matching command")
        } else {
            ForEach(windowSession.filteredCommands) { descriptor in
                Button {
                    windowSession.perform(descriptor.command)
                } label: {
                    PaletteRow(
                        icon: descriptor.systemImage,
                        title: descriptor.command.slashName,
                        detail: descriptor.title
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if let error = windowSession.paletteErrorMessage {
            EmptyPaletteRow(message: error)
        } else if windowSession.paletteQuery
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyPaletteRow(message: "Type to search document contents")
        } else if windowSession.searchResults.isEmpty {
            EmptyPaletteRow(
                message: windowSession.isSearching ? "Searching…" : "No results"
            )
        } else {
            ForEach(windowSession.searchResults) { result in
                Button {
                    windowSession.chooseSearchResult(result)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(result.relativePath)
                                .foregroundStyle(Color(nsColor: Palette.emphasis))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let workspace = appState.workspaceDescriptors.first(where: {
                                $0.id == result.workspaceID
                            }) {
                                Text(workspace.displayName)
                                    .foregroundStyle(Color(nsColor: Palette.muted))
                            }
                        }
                        if let excerpt = result.excerpt, !excerpt.isEmpty {
                            Text(excerpt.replacingOccurrences(of: "\n", with: " "))
                                .foregroundStyle(Color(nsColor: Palette.foreground))
                                .lineLimit(2)
                        }
                        if let reason = result.exclusionReason {
                            Text("Ignored: \(reason.pattern)")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }
                    .font(.custom(Typography.family, fixedSize: 11))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chooseFirstResult() {
        if windowSession.paletteMode == .commands,
           let command = windowSession.filteredCommands.first?.command {
            windowSession.perform(command)
        } else if let result = windowSession.searchResults.first {
            windowSession.chooseSearchResult(result)
        }
    }
}

private struct PaletteRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(Color(nsColor: Palette.muted))
            Text(title)
                .foregroundStyle(Color(nsColor: Palette.emphasis))
            Text(detail)
                .foregroundStyle(Color(nsColor: Palette.muted))
            Spacer()
        }
        .font(.custom(Typography.family, fixedSize: 12))
        .padding(.horizontal, 10)
        .frame(height: 35)
        .contentShape(Rectangle())
    }
}

private struct EmptyPaletteRow: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.custom(Typography.family, fixedSize: 11))
            .foregroundStyle(Color(nsColor: Palette.muted))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}
