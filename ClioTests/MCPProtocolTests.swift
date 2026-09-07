import XCTest
@testable import Clio

@MainActor
final class MCPProtocolTests: XCTestCase {
    func testHTTPFramingRejectsSmugglingAndPartialBodies() throws {
        let body = Data("{}".utf8)
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:19847\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: 2\r\n"
        XCTAssertNil(try MCPHTTPRequest.decode(Data((head + "\r\n{").utf8), port: 19847))
        XCTAssertEqual(try MCPHTTPRequest.decode(Data((head + "\r\n").utf8) + body, port: 19847)?.body, body)
        for extra in ["Content-Length: 3\r\n", "Transfer-Encoding: chunked\r\n", "Origin: null\r\n", "Expect: 100-continue\r\n"] {
            XCTAssertThrowsError(try MCPHTTPRequest.decode(Data((head + extra + "\r\n{}").utf8), port: 19847))
        }
        XCTAssertThrowsError(try MCPHTTPRequest.decode(Data((head + "\r\n{}extra").utf8), port: 19847))
        XCTAssertThrowsError(try MCPHTTPRequest.decode(Data(repeating: 65, count: 16_385), port: 19847))
    }

    func testProtocolRequiresAuthenticationAndSessionInitialization() async throws {
        let app = isolatedAppState()
        let access = MCPAccessController()
        let token = Data(repeating: 8, count: 32)
        _ = try access.authorizeClient(name: "Test", token: token, workspaces: [WorkspaceID()])
        access.setEnabled(true)
        let router = MCPRouter(access: access, tools: MCPTools(app: app, access: access))
        let unauthorized = await router.respond(request(method: "initialize", id: 1, token: Data(),
            params: ["protocolVersion": "2025-11-25"]))
        XCTAssertEqual(unauthorized.status, 401)
        let initial = await router.respond(request(method: "initialize", id: 1, token: token,
            params: ["protocolVersion": "future-version"]))
        let session = try XCTUnwrap(initial.headers["MCP-Session-Id"])
        let early = await router.respond(request(method: "tools/list", id: 2, token: token, session: session))
        XCTAssertNotNil(try json(early)["error"])
        let initialized = await router.respond(request(method: "notifications/initialized", token: token, session: session))
        XCTAssertEqual(initialized.status, 202)
        let list = await router.respond(request(method: "tools/list", id: 3, token: token, session: session))
        let result = try XCTUnwrap(try json(list)["result"] as? [String: Any])
        XCTAssertEqual((result["tools"] as? [[String: Any]])?.count, 12)
        XCTAssertFalse(MCPTools.definitions.contains { ($0["name"] as? String)?.contains("approve") == true })
        router.stop()
        let stopped = await router.respond(request(method: "tools/list", id: 4, token: token, session: session))
        XCTAssertEqual(stopped.status, 404)
    }

    func testSessionsCannotBeSharedBetweenAuthorizedClients() async throws {
        let app = isolatedAppState(), access = MCPAccessController()
        let first = Data(repeating: 1, count: 32), second = Data(repeating: 2, count: 32)
        let workspace = WorkspaceID()
        let id = try access.authorizeClient(name: "One", token: first, workspaces: [workspace])
        _ = try access.authorizeClient(name: "Two", token: second, workspaces: [workspace])
        access.setEnabled(true)
        let router = MCPRouter(access: access, tools: MCPTools(app: app, access: access))
        let initial = await router.respond(request(method: "initialize", id: 1, token: first,
            params: ["protocolVersion": "2025-11-25"]))
        let session = try XCTUnwrap(initial.headers["MCP-Session-Id"])
        let stolen = await router.respond(request(method: "ping", id: 2, token: second, session: session))
        XCTAssertEqual(stolen.status, 404)
        access.revoke(id)
        let revoked = await router.respond(request(method: "ping", id: 3, token: first, session: session))
        XCTAssertEqual(revoked.status, 401)
    }

    func testCreateRetriesDoNotDuplicateAndReadUsesLiveBuffer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClioMCPProtocol-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace(rootURL: root, accessSecurityScopedResource: false, recoverWorkspaceTransactions: false)
        let app = isolatedAppState(initialWorkspace: workspace), access = MCPAccessController()
        let token = Data(repeating: 7, count: 32)
        _ = try access.authorizeClient(name: "Test", token: token, workspaces: [workspace.id])
        access.setEnabled(true)
        let router = MCPRouter(access: access, tools: MCPTools(app: app, access: access))
        let initialized = await router.respond(request(method: "initialize", id: 1, token: token,
            params: ["protocolVersion": "2025-11-25"]))
        let session = try XCTUnwrap(initialized.headers["MCP-Session-Id"])
        _ = await router.respond(request(method: "notifications/initialized", token: token, session: session))
        let arguments: [String: Any] = ["workspaceID": workspace.id.rawValue.uuidString,
            "filename": "sample.md", "text": "", "mutationID": UUID().uuidString]
        let params: [String: Any] = ["name": "create_document", "arguments": arguments]
        let first = await router.respond(request(method: "tools/call", id: 2, token: token, session: session, params: params))
        let second = await router.respond(request(method: "tools/call", id: 3, token: token, session: session, params: params))
        let created = try toolJSON(first)
        XCTAssertEqual(created["documentID"] as? String, try toolJSON(second)["documentID"] as? String)
        let filenames = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(filenames, ["sample.md"])
        let rawID = try XCTUnwrap(created["documentID"] as? String)
        let document = try XCTUnwrap(app.documentRegistry.document(withID: DocumentID(rawValue: UUID(uuidString: rawID)!)))
        document.replaceText(with: "Unsaved live text")
        let read = await router.respond(request(method: "tools/call", id: 4, token: token, session: session,
            params: ["name": "read_document", "arguments": ["workspaceID": workspace.id.rawValue.uuidString, "documentID": rawID]]))
        XCTAssertEqual(try toolJSON(read)["text"] as? String, "Unsaved live text")
        var conflicting = arguments; conflicting["text"] = "different intent"
        let retry = await router.respond(request(method: "tools/call", id: 5, token: token, session: session,
            params: ["name": "create_document", "arguments": conflicting]))
        XCTAssertEqual(try toolJSON(retry)["error"] as? String, "retryConflict")
        router.stop()
    }

    func testToolSchemaRejectsExtraAuthorityAndBooleanInteger() {
        let schema = MCPTools.definitions.first { $0["name"] as? String == "read_document" }!["inputSchema"] as! [String: Any]
        XCTAssertFalse(MCPRouter.validate(["workspaceID": "w", "documentID": "d", "approve": true], schema: schema))
        XCTAssertFalse(MCPRouter.validate(["workspaceID": "w", "documentID": "d", "limit": true], schema: schema))
        XCTAssertFalse(MCPRouter.validID(true))
        XCTAssertFalse(MCPRouter.validID(NSNull()))
    }

    func testServiceDefaultsOffAndQuitDoesNotRegisterLoginOrOpenKeychain() {
        let app = isolatedAppState()
        XCTAssertFalse(app.mcpService.enabled)
        app.mcpService.quiesceForQuit()
        XCTAssertFalse(app.mcpService.enabled)
        XCTAssertEqual(app.mcpService.connectedSessions, 0)
        XCTAssertTrue(app.mcpService.clients.isEmpty)
    }

    private func request(method: String, id: Int? = nil, token: Data, session: String? = nil,
                         params: [String: Any] = [:]) -> MCPHTTPRequest {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { object["id"] = id }
        var headers = ["authorization": "Bearer " + token.base64EncodedString(), "mcp-protocol-version": "2025-11-25"]
        if let session { headers["mcp-session-id"] = session }
        return MCPHTTPRequest(method: "POST", headers: headers, body: try! JSONSerialization.data(withJSONObject: object))
    }
    private func json(_ response: MCPHTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }
    private func toolJSON(_ response: MCPHTTPResponse) throws -> [String: Any] {
        let result = try XCTUnwrap(try json(response)["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
