import SwiftUI

struct LocalMCPSettingsPage: View {
    @Environment(AppState.self) private var appState
    @State private var name = ""
    @State private var selected: Set<WorkspaceID> = []

    var body: some View {
        @Bindable var service = appState.mcpService
        Form {
            Section("Server") {
                Toggle("Enable local MCP", isOn: Binding(get: { service.enabled }, set: { service.setEnabled($0) }))
                    .accessibilityIdentifier("settings.mcp.enabled")
                Text(service.status).font(.caption)
                LabeledContent("Endpoint") {
                    Text("http://127.0.0.1:19847/mcp").textSelection(.enabled)
                }
                Text("Available only while Clio runs. Authorized clients can read and change selected folders, including unsaved text. Only deletion asks for confirmation. Browser/hosted connections are not enabled.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Open Clio at login without a window", isOn: Binding(get: { service.loginEnabled }, set: { service.setLoginEnabled($0) }))
                    .accessibilityIdentifier("settings.mcp.openAtLogin")
                Text(service.loginStatus).font(.caption)
            }
            Section("Authorize a client") {
                TextField("Client name", text: $name)
                ForEach(appState.workspaceDescriptors) { workspace in
                    Toggle(workspace.displayName, isOn: Binding(
                        get: { selected.contains(workspace.id) },
                        set: { if $0 { selected.insert(workspace.id) } else { selected.remove(workspace.id) } }))
                }
                Button("Authorize selected folders") {
                    service.addClient(name: name, workspaces: selected)
                    if service.errorMessage == nil { name = ""; selected = [] }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
                .accessibilityIdentifier("settings.mcp.authorize")
            }
            Section("Authorized clients (\(service.connectedSessions) sessions)") {
                ForEach(service.clients) { client in
                    HStack {
                        Text(client.name)
                        Spacer()
                        Button("Copy token") { service.copyToken(client.id) }
                        Button("Desktop config") { service.copyDesktopConfiguration(client.id) }
                        Button("Remove") { service.revoke(client.id) }
                            .accessibilityIdentifier("settings.mcp.revoke.\(client.id)")
                    }
                }
                Text("Tokens are credentials. Paste only into your client's local configuration. Clipboard clears after 60 seconds; do not share tokens in chat or logs.").font(.caption)
            }
            if let error = service.errorMessage { Text(error).foregroundStyle(.red) }
        }
        .onAppear { service.prepareSettingsPage() }
    }
}
