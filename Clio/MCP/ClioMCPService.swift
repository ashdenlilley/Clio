import AppKit
import Observation
import Security
import ServiceManagement
import SwiftUI

struct MCPStoredClient: Codable, Identifiable {
    let id: UUID
    let name: String
    let workspaceIDs: Set<WorkspaceID>
    let token: Data
}

enum MCPKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "olympus.clio.mac.mcp", kSecAttrAccount as String: "clients-v1",
         kSecAttrSynchronizable as String: false]
    }
    static func load() throws -> [MCPStoredClient] {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data, data.count < 65_536 else {
            throw MCPToolFailure(code: "keychain_unavailable")
        }
        let clients = try JSONDecoder().decode([MCPStoredClient].self, from: data)
        guard clients.count <= 32, Set(clients.map(\.id)).count == clients.count else { throw MCPAccessError.invalidRequest }
        return clients
    }
    static func save(_ clients: [MCPStoredClient]) throws {
        let data = try JSONEncoder().encode(clients)
        guard data.count < 65_536 else { throw MCPAccessError.oversizedRequest }
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MCPToolFailure(code: "keychain_write_failed") }
    }
    static func randomToken() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MCPAccessError.unauthorized }
        return Data(bytes)
    }
}

@MainActor
@Observable
final class ClioMCPService {
    private(set) var enabled = false
    private(set) var status = "MCP is off"
    private(set) var connectedSessions = 0
    private(set) var clients: [MCPStoredClient] = []
    private(set) var loginEnabled = false
    private(set) var loginStatus = ""
    private(set) var errorMessage: String?
    @ObservationIgnored private unowned let app: AppState
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let access = MCPAccessController()
    @ObservationIgnored private let server = MCPHTTPServer()
    @ObservationIgnored private lazy var tools = MCPTools(app: app, access: access)
    @ObservationIgnored private lazy var router = MCPRouter(access: access, tools: tools)
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored var openEditor: (() -> Void)? {
        didSet { tools.openEditor = openEditor }
    }

    init(appState: AppState, defaults: UserDefaults) {
        app = appState; self.defaults = defaults
    }

    func startConfigured() {
        guard ProcessInfo.processInfo.environment["CLIO_UI_TESTING"] != "1" else { return }
        refreshLoginStatus()
        if defaults.bool(forKey: "mcp.enabled") { setEnabled(true) }
    }

    private func loadCredentials() throws {
        guard !loaded else { return }
        let denied = Set(defaults.stringArray(forKey: "mcp.revokedClientIDs") ?? [])
        let stored = try MCPKeychain.load().filter { !denied.contains($0.id.uuidString) }
        do {
            for client in stored {
                _ = try access.authorizeClient(name: client.name, token: client.token,
                                              workspaces: client.workspaceIDs, id: client.id)
            }
        } catch { access.stop(); throw error }
        clients = stored; loaded = true
    }

    func setEnabled(_ value: Bool) {
        errorMessage = nil
        if !value {
            access.setEnabled(false); router.stop(); server.stop()
            enabled = false; status = "MCP is paused"
            defaults.set(false, forKey: "mcp.enabled")
            return
        }
        do {
            try loadCredentials()
            access.setEnabled(true)
            server.handle = { [weak self] in await self?.router.respond($0) ?? MCPHTTPResponse(status: 503) }
            server.stateChanged = { [weak self] message in
                self?.status = message
                if message.hasPrefix("Unable") {
                    self?.access.setEnabled(false); self?.router.stop(); self?.enabled = false
                }
            }
            router.connectionsChanged = { [weak self] in self?.connectedSessions = $0 }
            tools.clientName = { [weak self] id in self?.clients.first(where: { $0.id == id })?.name ?? "MCP client" }
            try server.start()
            enabled = true; status = "Starting local MCP…"
            defaults.set(true, forKey: "mcp.enabled")
        } catch {
            access.setEnabled(false); server.stop(); enabled = false
            errorMessage = "MCP could not start. Check Keychain access and whether port 19847 is in use."
            status = "MCP unavailable"
        }
    }

    /// Quiesce BEFORE the quit-save gate so modal cancellation cannot admit new
    /// tool writes. Caller may restart if saving cancels quit. Preference stays.
    func quiesceForQuit() {
        access.setEnabled(false); router.stop(); server.stop()
        enabled = false; status = "MCP stopped"
    }

    func addClient(name: String, workspaces: Set<WorkspaceID>) {
        do {
            try loadCredentials()
            guard workspaces.isSubset(of: Set(app.workspaceDescriptors.map(\.id))) else { throw MCPAccessError.outsideWorkspace }
            let token = try MCPKeychain.randomToken()
            let id = try access.authorizeClient(name: name, token: token, workspaces: workspaces)
            let record = MCPStoredClient(id: id, name: name, workspaceIDs: workspaces, token: token)
            do { try MCPKeychain.save(clients + [record]) }
            catch { access.revoke(id); throw error }
            clients.append(record); errorMessage = nil
        } catch { errorMessage = "Client was not added. Select at least one folder, use a short name, and allow Keychain access." }
    }

    func revoke(_ id: UUID) {
        // Revocation takes effect in memory even if persisting it fails. On a
        // storage failure disable automatic startup until the owner retries.
        var denied = Set(defaults.stringArray(forKey: "mcp.revokedClientIDs") ?? [])
        denied.insert(id.uuidString)
        defaults.set(Array(denied), forKey: "mcp.revokedClientIDs")
        access.revoke(id); router.revoke(id)
        let updated = clients.filter { $0.id != id }
        do { try MCPKeychain.save(updated); clients = updated; errorMessage = nil }
        catch {
            setEnabled(false)
            errorMessage = "Access is paused. Keychain could not persist revocation; retry Remove before enabling MCP again."
        }
    }

    func copyToken(_ id: UUID) {
        guard let client = clients.first(where: { $0.id == id }) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); pasteboard.setString(client.token.base64EncodedString(), forType: .string)
        let change = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if pasteboard.changeCount == change { pasteboard.clearContents() }
        }
    }

    func copyDesktopConfiguration(_ id: UUID) {
        guard let client = clients.first(where: { $0.id == id }) else { return }
        let bridge = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ClioMCPBridge").path
        let object: [String: Any] = ["mcpServers": ["clio": ["command": bridge,
            "env": ["CLIO_MCP_TOKEN": client.token.base64EncodedString()]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        let change = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if pasteboard.changeCount == change { pasteboard.clearContents() }
        }
    }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        loginStatus = status == .requiresApproval ? "Approval needed in System Settings → General → Login Items" : (status == .enabled ? "Open at login is enabled" : "Open at login is off")
    }

    func setLoginEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            errorMessage = nil
        } catch { errorMessage = "Login setting could not be changed. Check System Settings → General → Login Items." }
        refreshLoginStatus()
    }

    func showSettings() {
        do { try loadCredentials() } catch { errorMessage = "Allow Keychain access to manage MCP clients." }
        refreshLoginStatus()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Clio MCP"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MCPSettingsView(service: self, app: app))
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct MCPSettingsView: View {
    @Bindable var service: ClioMCPService
    let app: AppState
    @State private var name = ""
    @State private var selected: Set<WorkspaceID> = []

    var body: some View {
        Form {
            Toggle("Enable local MCP", isOn: Binding(get: { service.enabled }, set: { service.setEnabled($0) }))
            Text(service.status).font(.caption)
            Text("Endpoint: http://127.0.0.1:19847/mcp").textSelection(.enabled)
            Text("Available only while Clio runs. Authorized clients can read and change selected folders, including unsaved text. Only deletion asks for confirmation. Browser/hosted connections are not enabled.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Open Clio at login without a window", isOn: Binding(get: { service.loginEnabled }, set: { service.setLoginEnabled($0) }))
            Text(service.loginStatus).font(.caption)
            Section("Authorize a client") {
                TextField("Client name", text: $name)
                ForEach(app.workspaceDescriptors) { workspace in
                    Toggle(workspace.displayName, isOn: Binding(
                        get: { selected.contains(workspace.id) },
                        set: { if $0 { selected.insert(workspace.id) } else { selected.remove(workspace.id) } }))
                }
                Button("Authorize selected folders") {
                    service.addClient(name: name, workspaces: selected)
                    if service.errorMessage == nil { name = ""; selected = [] }
                }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
            }
            Section("Authorized clients (\(service.connectedSessions) sessions)") {
                ForEach(service.clients) { client in
                    HStack {
                        Text(client.name)
                        Spacer()
                        Button("Copy token") { service.copyToken(client.id) }
                        Button("Desktop config") { service.copyDesktopConfiguration(client.id) }
                        Button("Remove") { service.revoke(client.id) }
                    }
                }
                Text("Tokens are credentials. Paste only into your client's local configuration. Clipboard clears after 60 seconds; do not share tokens in chat or logs.").font(.caption)
            }
            if let error = service.errorMessage { Text(error).foregroundStyle(.red) }
        }.formStyle(.grouped).padding().frame(minWidth: 480, minHeight: 460)
    }
}
