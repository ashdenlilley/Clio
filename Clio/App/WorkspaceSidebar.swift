import SwiftUI

struct WorkspaceSidebar: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorWindowSession.self) private var windowSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                appState.requestNewDocument(from: windowSession)
            } label: {
                Label("New Document", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .interactionCursor()
            .accessibilityIdentifier("sidebar.newDocument")
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        openDocuments
                        ForEach(appState.workspaceDescriptors) { workspace in
                            WorkspaceTreeSection(workspace: workspace, snapshot: appState.workspaceTrees[workspace.id])
                        }
                        if appState.isRefreshingWorkspaces {
                            ProgressView("Refreshing…").controlSize(.small)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .onChange(of: windowSession.activeTabID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
        .frame(width: 252)
        .background(Color(nsColor: Palette.backgroundRaised))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: Palette.hairline)).frame(width: 1)
        }
        .contextMenu {
            Button(windowSession.isSidebarPinned ? "Unpin Sidebar" : "Pin Sidebar") {
                windowSession.setSidebarPinned(!windowSession.isSidebarPinned)
            }
        }
        .onHover { windowSession.setSidebarHovered($0) }
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
                HStack(spacing: 4) {
                    SidebarDocumentRow(
                        name: tab.displayName,
                        isSelected: tab.id == windowSession.activeTabID,
                        canRename: tab.fileURL != nil,
                        identifier: "sidebar.tab",
                        open: { windowSession.select(tabID: tab.id) },
                        rename: { try await appState.renameDocument(tab, to: $0) }
                    )
                    Button { windowSession.close(tabID: tab.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .interactionCursor()
                    .accessibilityLabel("Close \(tab.displayName)")
                    .modifier(ContextChromeMotion(motion: windowSession.motion))
                }
                .padding(.horizontal, 10)
                .id(tab.id)
            }
        }
    }
}

private struct WorkspaceTreeSection: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorWindowSession.self) private var windowSession
    let workspace: WorkspaceDescriptor
    let snapshot: WorkspaceTreeSnapshot?
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").frame(width: 10)
                    Image(systemName: "folder.fill")
                    Text(workspace.displayName).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .interactionCursor()
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .help(workspace.rootURL.path)
            .dropDestination(for: String.self) { payloads, _ in
                guard let payload = payloads.first else { return false }
                return appState.moveDocument(dragPayload: payload, toWorkspaceID: workspace.id, parentRelativePath: "")
            }
            if isExpanded {
                if let snapshot, !snapshot.files.isEmpty {
                    let items = SidebarTreeItem.makeTree(workspaceID: workspace.id, files: snapshot.files)
                    ForEach(items) { item in
                        SidebarTreeBranch(item: item, workspaceID: workspace.id, isLast: item.id == items.last?.id)
                    }
                } else {
                    Text(snapshot == nil ? "Indexing…" : "No documents")
                        .foregroundStyle(.secondary).padding(.leading, 20).padding(.vertical, 6)
                }
            }
        }
        .font(.custom(Typography.family, fixedSize: 11))
        .foregroundStyle(Color(nsColor: Palette.foreground))
        .padding(.horizontal, 12)
        .onChange(of: windowSession.activeTab?.relativePath) { _, _ in
            if windowSession.activeTab?.workspaceID == workspace.id { isExpanded = true }
        }
    }
}

private struct SidebarTreeBranch: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorWindowSession.self) private var windowSession
    let item: SidebarTreeItem
    let workspaceID: WorkspaceID
    let isLast: Bool
    @State private var isExpanded = false

    private var containsSelection: Bool {
        guard windowSession.activeTab?.workspaceID == workspaceID,
              let path = item.dropTargetPath else { return false }
        return windowSession.activeTab?.relativePath.hasPrefix(path + "/") == true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Path { path in
                path.move(to: CGPoint(x: 7, y: 0))
                path.addLine(to: CGPoint(x: 7, y: 14))
                path.addLine(to: CGPoint(x: 17, y: 14))
            }
            .stroke(Color(nsColor: Palette.muted).opacity(0.45), lineWidth: 1)
            .frame(width: 18, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                if let children = item.children {
                    Button { isExpanded.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 8))
                            Image(systemName: isExpanded ? "folder.fill" : "folder")
                            Text(item.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .interactionCursor()
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .dropDestination(for: String.self) { payloads, _ in
                        guard let payload = payloads.first else { return false }
                        return appState.moveDocument(dragPayload: payload, toWorkspaceID: workspaceID, parentRelativePath: item.dropTargetPath ?? "")
                    }
                    if isExpanded {
                        ForEach(children) { child in
                            SidebarTreeBranch(item: child, workspaceID: workspaceID, isLast: child.id == children.last?.id)
                        }
                    }
                } else if let relativePath = item.relativePath, let documentID = item.documentID {
                    SidebarDocumentRow(
                        name: item.name,
                        isSelected: windowSession.activeTab?.workspaceID == workspaceID && windowSession.activeTab?.relativePath == relativePath,
                        canRename: true,
                        identifier: "sidebar.workspace.file",
                        open: {
                            appState.openWorkspaceFile(documentID: documentID, workspaceID: workspaceID, relativePath: relativePath, from: windowSession)
                        },
                        rename: { name in
                            let tab = try await appState.openWorkspaceFileNow(documentID: documentID, workspaceID: workspaceID, relativePath: relativePath, from: windowSession)
                            try await appState.renameDocument(tab, to: name)
                        }
                    )
                    .help(item.helpText)
                    .onDrag {
                        windowSession.motion.update { $0.setSidebarFileDragged(true) }
                        return NSItemProvider(object: (appState.dragPayload(documentID: documentID, workspaceID: workspaceID, relativePath: relativePath) ?? "") as NSString)
                    }
                }
            }
        }
        .background(alignment: .leading) {
            if !isLast {
                Rectangle().fill(Color(nsColor: Palette.muted).opacity(0.45))
                    .frame(width: 1).padding(.leading, 6.5).accessibilityHidden(true)
            }
        }
        .onAppear { if containsSelection { isExpanded = true } }
        .onChange(of: containsSelection) { _, selected in
            if selected { isExpanded = true }
        }
    }
}

private struct SidebarDocumentRow: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorWindowSession.self) private var windowSession
    let name: String
    let isSelected: Bool
    let canRename: Bool
    let identifier: String
    let open: () -> Void
    let rename: (String) async throws -> Void
    @State private var isRenaming = false
    @State private var proposedName = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool
    @FocusState private var rowFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isRenaming {
                TextField("Document name", text: $proposedName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .disabled(isSaving)
                    .onSubmit(commitRename)
                    .onExitCommand { if !isSaving { cancelRename() } }
                    .accessibilityIdentifier("sidebar.rename")
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button(action: open) {
                    Label(name, systemImage: "doc.text")
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($rowFocused)
                .interactionCursor()
                .highPriorityGesture(TapGesture(count: 2).onEnded { beginRename() })
                .contextMenu {
                    Button("Rename", action: beginRename).disabled(!canRename)
                }
                .accessibilityIdentifier(identifier)
                .modifier(SidebarSelectedTrait(isSelected: isSelected))
            }
        }
        .font(.custom(Typography.family, fixedSize: 12))
        .padding(.horizontal, 3)
        .background(isSelected ? Color(nsColor: Palette.hairline).opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onChange(of: rowFocused || isRenaming) { _, focused in windowSession.setSidebarFocused(focused) }
        .onChange(of: nameFocused) { _, focused in
            if !focused && isRenaming && !isSaving { cancelRename() }
        }
        .onDisappear { if isRenaming || rowFocused { windowSession.setSidebarFocused(false) } }
    }

    private func beginRename() {
        guard canRename else { return }
        proposedName = name
        errorMessage = nil
        isRenaming = true
        nameFocused = true
    }

    private func cancelRename() {
        isRenaming = false
        errorMessage = nil
        nameFocused = false
    }

    private func commitRename() {
        guard !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            do {
                try await rename(proposedName)
                isSaving = false
                cancelRename()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
                nameFocused = true
            }
        }
    }
}

extension View {
    /// Set the cursor on every hover update without accumulating cursor-stack entries.
    func interactionCursor() -> some View {
        onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
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
