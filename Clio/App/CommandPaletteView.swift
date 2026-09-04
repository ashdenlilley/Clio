import AppKit
import SwiftUI

struct CommandPaletteView: View {
    var maximumWidth: CGFloat = 620
    var maximumResultsHeight: CGFloat = 360
    @Environment(AppState.self) private var appState
    @Environment(EditorWindowSession.self) private var windowSession
    @FocusState private var isQueryFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .accessibilityIdentifier("palette.query")

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

            ScrollViewReader { proxy in
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
                .frame(maxHeight: maximumResultsHeight)
                .onChange(of: windowSession.selectedPaletteItemAnchor) { _, anchor in
                    guard let anchor else { return }
                    if reduceMotion {
                        proxy.scrollTo(anchor, anchor: .center)
                    } else {
                        withAnimation(.easeOut(duration: 0.08)) {
                            proxy.scrollTo(anchor, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: maximumWidth)
        .background(Color(nsColor: Palette.backgroundRaised))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: Palette.hairline), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.7), radius: 28, y: 12)
        .task(id: windowSession.isPalettePresented && windowSession.motion.surfaceState.activeSurfaceStack.last == .palette) {
            guard windowSession.isPalettePresented,
                  windowSession.motion.surfaceState.activeSurfaceStack.last == .palette else {
                isQueryFocused = false
                return
            }
            // Menu-command presentation must finish its current responder
            // transaction before the palette claims the field editor.
            await Task.yield()
            guard !Task.isCancelled else { return }
            isQueryFocused = true
        }
        .onExitCommand { windowSession.dismissPalette() }
        .background(
            PaletteKeyboardMonitor(isActive: windowSession.isPalettePresented && windowSession.motion.surfaceState.activeSurfaceStack.last == .palette) { key in
                switch key {
                case .up:
                    windowSession.movePaletteSelection(by: -1)
                case .down:
                    windowSession.movePaletteSelection(by: 1)
                case .pageUp:
                    windowSession.movePaletteSelection(by: -8)
                case .pageDown:
                    windowSession.movePaletteSelection(by: 8)
                case .return:
                    windowSession.performSelectedPaletteItem()
                }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(windowSession.paletteMode == .search
            ? "Workspace search"
            : "Command palette")
        .accessibilityIdentifier("command.palette")
    }

    @ViewBuilder
    private var commandResults: some View {
        if let error = windowSession.paletteErrorMessage {
            EmptyPaletteRow(message: error)
        } else if windowSession.filteredCommands.isEmpty {
            EmptyPaletteRow(message: "No matching command")
        } else {
            ForEach(
                Array(windowSession.filteredCommands.enumerated()),
                id: \.element.id
            ) { index, descriptor in
                Button {
                    windowSession.selectPaletteItem(at: index)
                    windowSession.performSelectedPaletteItem()
                } label: {
                    PaletteRow(
                        icon: descriptor.systemImage,
                        title: descriptor.command.slashName,
                        detail: descriptor.title,
                        isSelected: index == windowSession.paletteSelectionIndex
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { windowSession.selectPaletteItemFromPointer(at: index) }
                }
                .id("command:\(descriptor.command.rawValue)")
                .accessibilityIdentifier("palette.command.\(descriptor.command.rawValue)")
                .modifier(SelectedAccessibilityTrait(
                    isSelected: index == windowSession.paletteSelectionIndex
                ))
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
            ForEach(
                Array(windowSession.searchResults.enumerated()),
                id: \.element.id
            ) { index, result in
                Button {
                    windowSession.selectPaletteItem(at: index)
                    windowSession.performSelectedPaletteItem()
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
                    .background {
                        if index == windowSession.paletteSelectionIndex {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: Palette.hairline).opacity(0.8))
                        }
                    }
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { windowSession.selectPaletteItemFromPointer(at: index) }
                }
                .id("search:\(result.id.uuidString)")
                .accessibilityIdentifier("palette.search-result")
                .modifier(SelectedAccessibilityTrait(
                    isSelected: index == windowSession.paletteSelectionIndex
                ))
            }
        }
    }
}

private struct PaletteRow: View {
    let icon: String
    let title: String
    let detail: String
    let isSelected: Bool

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
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: Palette.hairline).opacity(0.8))
            }
        }
    }
}

private struct SelectedAccessibilityTrait: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityValue(isSelected ? "Selected" : "")
    }
}

private enum PaletteNavigationKey {
    case up
    case down
    case pageUp
    case pageDown
    case `return`
}

/// A window-scoped event monitor lets arrow and paging keys continue to drive
/// palette selection while the plain TextField remains first responder.
private struct PaletteKeyboardMonitor: NSViewRepresentable {
    let isActive: Bool
    let handler: (PaletteNavigationKey) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler)
    }

    func makeNSView(context: Context) -> PaletteKeyboardMonitorView {
        let view = PaletteKeyboardMonitorView(frame: .zero)
        context.coordinator.isActive = isActive
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(
        _ nsView: PaletteKeyboardMonitorView,
        context: Context
    ) {
        context.coordinator.handler = handler
        context.coordinator.isActive = isActive
    }

    final class Coordinator {
        var isActive = false
        var handler: (PaletteNavigationKey) -> Void
        private weak var view: PaletteKeyboardMonitorView?
        private var monitor: Any?

        init(handler: @escaping (PaletteNavigationKey) -> Void) {
            self.handler = handler
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func attach(to view: PaletteKeyboardMonitorView) {
            self.view = view
            view.onWindowChanged = { [weak self] in self?.installMonitorIfNeeded() }
            installMonitorIfNeeded()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil, view?.window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard let self,
                      self.isActive,
                      let window = self.view?.window,
                      (event.window ?? NSApp.keyWindow) === window,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      (window.firstResponder as? NSTextView)?.hasMarkedText() != true,
                      let key = Self.navigationKey(for: event) else { return event }
                self.handler(key)
                return nil
            }
        }

        private static func navigationKey(for event: NSEvent) -> PaletteNavigationKey? {
            switch event.keyCode {
            case 126: return .up
            case 125: return .down
            case 116: return .pageUp
            case 121: return .pageDown
            case 36, 76: return .return
            default: return nil
            }
        }
    }
}

private final class PaletteKeyboardMonitorView: NSView {
    var onWindowChanged: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?()
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
