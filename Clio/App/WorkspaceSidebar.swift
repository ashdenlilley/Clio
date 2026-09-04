import SwiftUI

struct WorkspaceSidebar: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorWindowSession.self) private var windowSession
    @FocusState private var focusedTabID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SidebarToggleButton()
                Spacer()
            }
            .frame(height: 38)
            .padding(.leading, 76)
            .padding(.trailing, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    openDocuments

                    ForEach(appState.workspaceDescriptors) { workspace in
                        WorkspaceTreeSection(
                            workspace: workspace,
                            snapshot: appState.workspaceTrees[workspace.id]
                        )
                    }

                    if appState.isRefreshingWorkspaces {
                        ProgressView("Refreshing…")
                            .controlSize(.small)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .frame(width: 252)
        .background(Color(nsColor: Palette.backgroundRaised))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: Palette.hairline))
                .frame(width: 1)
        }
        .contextMenu {
            Button(windowSession.isSidebarPinned ? "Unpin Sidebar" : "Pin Sidebar") {
                windowSession.setSidebarPinned(!windowSession.isSidebarPinned)
            }
        }
        .onHover { windowSession.setSidebarHovered($0) }
        .onChange(of: focusedTabID) { _, value in
            windowSession.setSidebarFocused(value != nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document sidebar")
        .accessibilityIdentifier("sidebar")
    }

    private var openDocuments: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OPEN DOCUMENTS")
                .font(.custom(Typography.family, fixedSize: 10))
                .foregroundStyle(Color(nsColor: Palette.muted))
                .padding(.horizontal, 12)

            ForEach(windowSession.tabs) { tab in
                HStack(spacing: 6) {
                    Button {
                        windowSession.select(tabID: tab.id)
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(tab.id == windowSession.activeTabID
                                    ? appState.accent.color
                                    : Color.clear)
                                .frame(width: 5, height: 5)
                            Text(tab.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedTabID, equals: tab.id)
                    .accessibilityIdentifier("sidebar.tab")
                    .modifier(SidebarSelectedTrait(
                        isSelected: tab.id == windowSession.activeTabID
                    ))

                    Button {
                        windowSession.close(tabID: tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(nsColor: Palette.muted))
                    .accessibilityLabel("Close \(tab.displayName)")
                }
                .font(.custom(Typography.family, fixedSize: 12))
                .foregroundStyle(tab.id == windowSession.activeTabID
                    ? Color(nsColor: Palette.emphasis)
                    : Color(nsColor: Palette.foreground))
                .padding(.horizontal, 12)
                .frame(height: 27)
                .background {
                    if tab.id == windowSession.activeTabID {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: Palette.hairline).opacity(0.7))
                    }
                }
                .padding(.horizontal, 5)
            }
        }
    }
}

struct SidebarToggleButton: View {
    @Environment(EditorWindowSession.self) private var windowSession

    var body: some View {
        Button {
            windowSession.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(nsColor: Palette.foreground))
        .help(windowSession.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(windowSession.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityIdentifier("sidebar.toggle")
    }
}

private struct WorkspaceTreeSection: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorWindowSession.self) private var windowSession
    let workspace: WorkspaceDescriptor
    let snapshot: WorkspaceTreeSnapshot?
    @State private var isExpanded = true
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let snapshot, !snapshot.files.isEmpty {
                OutlineGroup(
                    SidebarTreeItem.makeTree(
                        workspaceID: workspace.id,
                        files: snapshot.files
                    ),
                    children: \.children
                ) { item in
                    if let relativePath = item.relativePath,
                       let documentID = item.documentID {
                        let isSelected = windowSession.activeTab?.workspaceID == workspace.id
                            && windowSession.activeTab?.relativePath == relativePath
                        Button {
                            appState.openWorkspaceFile(
                                documentID: documentID,
                                workspaceID: workspace.id,
                                relativePath: relativePath,
                                from: windowSession
                            )
                        } label: {
                            Label(item.name, systemImage: "doc.text")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($hasKeyboardFocus)
                        .help(item.helpText)
                        .accessibilityIdentifier("sidebar.workspace.file")
                        .modifier(SidebarSelectedTrait(isSelected: isSelected))
                        .onDrag {
                            NSItemProvider(
                                object: (appState.dragPayload(
                                    documentID: documentID,
                                    workspaceID: workspace.id,
                                    relativePath: relativePath
                                ) ?? "") as NSString
                            )
                        }
                    } else {
                        Label(item.name, systemImage: "folder")
                            .foregroundStyle(Color(nsColor: Palette.muted))
                            .dropDestination(for: String.self) { payloads, _ in
                                guard let payload = payloads.first else { return false }
                                return appState.moveDocument(
                                    dragPayload: payload,
                                    toWorkspaceID: workspace.id,
                                    parentRelativePath: item.dropTargetPath ?? ""
                                )
                            }
                    }
                }
                .font(.custom(Typography.family, fixedSize: 11))
                .foregroundStyle(Color(nsColor: Palette.foreground))
                .padding(.leading, 4)
            } else {
                Text(snapshot == nil ? "Indexing…" : "No documents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 19)
                    .padding(.vertical, 4)
            }
        } label: {
            Label(workspace.displayName, systemImage: "folder.fill")
                .font(.custom(Typography.family, fixedSize: 11))
                .foregroundStyle(Color(nsColor: Palette.foreground))
                .lineLimit(1)
                .help(workspace.rootURL.path)
                .dropDestination(for: String.self) { payloads, _ in
                    guard let payload = payloads.first else { return false }
                    return appState.moveDocument(
                        dragPayload: payload,
                        toWorkspaceID: workspace.id,
                        parentRelativePath: ""
                    )
                }
        }
        .padding(.horizontal, 12)
        .onChange(of: hasKeyboardFocus) { _, focused in
            windowSession.setSidebarFocused(focused)
        }
    }
}

private struct SidebarSelectedTrait: ViewModifier {
    let isSelected: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isSelected {
            content.accessibilityAddTraits(.isSelected)
        } else {
            content
        }
    }
}

private struct SidebarTreeItem: Identifiable {
    let id: String
    let name: String
    let documentID: DocumentID?
    let relativePath: String?
    let dropTargetPath: String?
    let exclusionReason: ExclusionReason?
    let children: [SidebarTreeItem]?

    var helpText: String {
        guard let exclusionReason else { return relativePath ?? name }
        if let builtIn = exclusionReason.builtIn {
            return "Ignored by Clio rule: \(builtIn.displayName)"
        }
        let source = exclusionReason.sourceURL?.lastPathComponent ?? "workspace settings"
        return "Ignored by \(source): \(exclusionReason.pattern)"
    }

    static func makeTree(
        workspaceID: WorkspaceID,
        files: [WorkspaceFile],
        prefix: String = ""
    ) -> [SidebarTreeItem] {
        var directFiles: [WorkspaceFile] = []
        var grouped: [String: [WorkspaceFile]] = [:]

        for file in files {
            let remaining: String
            if prefix.isEmpty {
                remaining = file.relativePath
            } else {
                let marker = prefix + "/"
                guard file.relativePath.hasPrefix(marker) else { continue }
                remaining = String(file.relativePath.dropFirst(marker.count))
            }

            let components = remaining.split(separator: "/", maxSplits: 1).map(String.init)
            if components.count == 1 {
                directFiles.append(file)
            } else {
                grouped[components[0], default: []].append(file)
            }
        }

        let folders = grouped.keys.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map { folder -> SidebarTreeItem in
            let path = prefix.isEmpty ? folder : "\(prefix)/\(folder)"
            return SidebarTreeItem(
                id: "\(workspaceID.rawValue.uuidString):folder:\(path)",
                name: folder,
                documentID: nil,
                relativePath: nil,
                dropTargetPath: path,
                exclusionReason: nil,
                children: makeTree(
                    workspaceID: workspaceID,
                    files: grouped[folder] ?? [],
                    prefix: path
                )
            )
        }

        let leaves = directFiles.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }.map { file in
            SidebarTreeItem(
                id: "\(workspaceID.rawValue.uuidString):file:\(file.relativePath)",
                name: URL(fileURLWithPath: file.relativePath).lastPathComponent,
                documentID: file.documentID,
                relativePath: file.relativePath,
                dropTargetPath: nil,
                exclusionReason: file.exclusionReason,
                children: nil
            )
        }

        return folders + leaves
    }
}
