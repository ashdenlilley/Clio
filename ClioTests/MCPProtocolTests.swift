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

    func testLiveSearchUsesIndexTokenPrefixesAndUnicodeSemantics() async throws {
        let matcher = SQLiteLiveBufferMatcher()
        let cases: [(String, String, Bool)] = [
            ("alpha ... beta", "alpha beta", true),
            ("alphabet betatron", "alp bet", true),
            ("alphabet only", "alpha beta", false),
            ("CAFÉ résumé", "cafe resu", true),
            ("alpha_beta", "alpha_beta", true),
            ("xalpha beta", "alpha", false),
            ("日本語 alpha", "日本 alpha", true)
        ]
        for (text, query, expected) in cases {
            let actual = try await matcher.matches(text: text, relativePath: "sample.md", query: query)
            XCTAssertEqual(actual, expected, "query: \(query)")
        }
        let filenameFallback = try await matcher.matches(text: "", relativePath: "sample.md", query: "")
        XCTAssertTrue(filenameFallback)
        let filenameOnly = try await matcher.matches(text: "unrelated", relativePath: "alpha.md", query: "alp")
        XCTAssertTrue(filenameOnly)
        let splitFields = try await matcher.matches(text: "beta", relativePath: "alpha.md", query: "alpha beta")
        XCTAssertTrue(splitFields)
        let noRetainedText = try await matcher.matches(text: "unrelated", relativePath: "other.md", query: "alpha")
        XCTAssertFalse(noRetainedText, "One live buffer must not leak matches into another")
    }

    func testDiscoverySkipsDetachedAndOversizedBuffersWithoutLosingOtherResults() async throws {
        let root = try mcpTemporaryDirectory()
        let catalog = try mcpCatalog(root: root)
        let workspace = try XCTUnwrap(catalog.workspaces.first)
        for name in ["small.md", "large.md", "detached.md"] {
            try Data("alpha ... beta".utf8).write(to: root.appendingPathComponent(name))
        }
        let app = isolatedAppState(workspaceCatalog: catalog), access = MCPAccessController()
        try await waitForDiscovery(app)
        let token = Data(repeating: 11, count: 32)
        let clientID = try access.authorizeClient(name: "Discovery", token: token, workspaces: [workspace.id])
        access.setEnabled(true)
        let grant = try access.authenticate(token: token), tools = MCPTools(app: app, access: access)
        let searchArguments: [String: Any] = ["workspaceID": workspace.id.rawValue.uuidString, "query": "alpha beta"]
        let before = try await tools.call("search_documents", arguments: searchArguments, grant: grant)
        XCTAssertEqual((before["documents"] as? [[String: Any]])?.count, 3)
        let small = try app.documentRegistry.open(root.appendingPathComponent("small.md"), in: workspace)
        let large = try app.documentRegistry.open(root.appendingPathComponent("large.md"), in: workspace)
        let detached = try app.documentRegistry.open(root.appendingPathComponent("detached.md"), in: workspace)
        large.replaceText(with: String(repeating: "x", count: 1_048_577))
        detached.markUnbacked(previous: try workspace.locator(for: root.appendingPathComponent("detached.md")))
        let search = try await tools.call("search_documents", arguments: searchArguments, grant: grant)
        let documents = try XCTUnwrap(search["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.compactMap { $0["documentID"] as? String }, [small.id.rawValue.uuidString])
        let list = try await tools.call("list_documents", arguments: ["workspaceID": workspace.id.rawValue.uuidString], grant: grant)
        let listed = try XCTUnwrap(list["documents"] as? [[String: Any]])
        XCTAssertEqual(Set(listed.compactMap { $0["documentID"] as? String }),
                       Set([small.id.rawValue.uuidString, large.id.rawValue.uuidString]))
        access.revoke(clientID)
        do {
            _ = try await tools.call("list_documents", arguments: ["workspaceID": workspace.id.rawValue.uuidString], grant: grant)
            XCTFail("Discovery must propagate revocation")
        } catch let error as MCPAccessError { XCTAssertEqual(error, .unauthorized) }
    }

    func testUntitledEditorLookupFindsSecondWindow() throws {
        let workspace = try Workspace(rootURL: mcpTemporaryDirectory(), accessSecurityScopedResource: false,
                                      recoverWorkspaceTransactions: false)
        let app = isolatedAppState(initialWorkspace: workspace)
        let first = EditorWindowSession(request: .newDocument()), second = EditorWindowSession(request: .newDocument())
        first.connect(to: app); second.connect(to: app)
        let document = try XCTUnwrap(second.activeTab?.document)
        XCTAssertNil(document.fileURL)
        let tools = MCPTools(app: app, access: MCPAccessController())
        XCTAssertTrue(tools.owningWindow(for: document) === second)
        XCTAssertFalse(tools.owningWindow(for: document) === first)
    }

    func testRevisionLookupAmortizesCleanupWithoutChangingTokens() throws {
        let app = isolatedAppState(), access = MCPAccessController()
        let reader = MCPDocumentAccess(access: access, registry: app.documentRegistry)
        let documents = (0..<5_000).map { Document(text: "\($0)") }
        let tokens = documents.map { reader.revision(for: $0) }
        let scans = reader.incarnationCleanupCount
        for (document, token) in zip(documents, tokens) { XCTAssertEqual(reader.revision(for: document), token) }
        XCTAssertEqual(reader.incarnationCleanupCount, scans, "Reads must never scan the incarnation table")
        XCTAssertLessThan(scans, 20, "Cleanup must be amortized across insertions")
        for _ in 0..<10_000 { _ = reader.revision(for: Document(text: "temporary")) }
        XCTAssertGreaterThan(reader.incarnationCleanupCount, scans, "Cleanup must not starve as the table grows")
        XCTAssertEqual(reader.revision(for: documents[0]), tokens[0])
    }

    func testMCPCreateUsesIncrementalIndexUpdatesNotRebuilds() async throws {
        let catalog = try mcpCatalog(root: mcpTemporaryDirectory())
        let workspace = try XCTUnwrap(catalog.workspaces.first)
        let index = MCPIndexUpdateSpy()
        let app = isolatedAppState(workspaceCatalog: catalog, searchIndex: index)
        try await waitForDiscovery(app)
        let baseline = await index.rebuildCount
        let access = MCPAccessController(), token = Data(repeating: 12, count: 32)
        _ = try access.authorizeClient(name: "Create", token: token, workspaces: [workspace.id])
        access.setEnabled(true)
        let grant = try access.authenticate(token: token), tools = MCPTools(app: app, access: access)
        for name in ["one.md", "two.md"] {
            _ = try await tools.call("create_document", arguments: ["workspaceID": workspace.id.rawValue.uuidString,
                "filename": name, "text": "small", "mutationID": UUID().uuidString], grant: grant)
        }
        let rebuilds = await index.rebuildCount, events = await index.events
        XCTAssertEqual(rebuilds, baseline)
        XCTAssertTrue(events.contains { $0.kind == .created && $0.fileURL?.lastPathComponent == "one.md" })
        XCTAssertTrue(events.contains { $0.kind == .created && $0.fileURL?.lastPathComponent == "two.md" })
    }

    private func mcpTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClioMCPReview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func mcpCatalog(root: URL) throws -> WorkspaceCatalog {
        let suite = "ClioMCPReview.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let catalog = WorkspaceCatalog(defaults: defaults,
            bookmarkMaker: { Data($0.path.utf8) },
            bookmarkResolver: { Workspace.BookmarkResolution(url: URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), isStale: false) },
            crashRecoveryJournal: CrashRecoveryJournal(rootURL: root.appendingPathComponent(".test-journal")),
            workspaceFactory: { try Workspace(id: $0, rootURL: $1, accessSecurityScopedResource: false,
                crashRecoveryJournal: $2, recoverWorkspaceTransactions: false) })
        try catalog.addAuthorizedFolder(root)
        return catalog
    }

    private func waitForDiscovery(_ app: AppState) async throws {
        for _ in 0..<200 {
            if !app.isRefreshingWorkspaces { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Initial workspace discovery did not finish")
        throw CancellationError()
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

private actor MCPIndexUpdateSpy: SearchIndexing {
    private(set) var rebuildCount = 0
    private(set) var events: [WorkspaceEvent] = []
    func rebuild(workspaces: [WorkspaceDescriptor], policy: DiscoveryPolicy) async throws { rebuildCount += 1 }
    func apply(_ events: [WorkspaceEvent]) async throws { self.events += events }
    func quickOpen(_ query: WorkspaceSearchQuery) async -> AsyncThrowingStream<SearchBatch, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func search(_ query: WorkspaceSearchQuery) async -> AsyncThrowingStream<SearchBatch, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
