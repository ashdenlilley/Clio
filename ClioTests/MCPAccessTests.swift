import XCTest
@testable import Clio

@MainActor
final class MCPAccessTests: XCTestCase {
    func testLoopbackPolicyRejectsForeignHostAndEveryBrowserOrigin() throws {
        let policy = MCPLoopbackPolicy(port: 19847)
        try policy.validate(host: "127.0.0.1:19847", origin: nil, bodyByteCount: 10)
        for host in ["evil.example:19847", "127.0.0.1:80", "localhost:19847", "127.0.0.1:19847.evil"] {
            XCTAssertThrowsError(try policy.validate(host: host, origin: nil, bodyByteCount: 10))
        }
        for origin in ["null", "", "https://evil.example", "http://127.0.0.1:19847"] {
            XCTAssertThrowsError(try policy.validate(host: "127.0.0.1:19847", origin: origin, bodyByteCount: 10))
        }
        XCTAssertThrowsError(try policy.validate(host: "127.0.0.1:19847", origin: nil, bodyByteCount: -1))
        XCTAssertThrowsError(try policy.validate(host: "127.0.0.1:19847", origin: nil, bodyByteCount: 1_048_577))
    }

    func testDefaultDisabledRevocationAndPauseInvalidateOutstandingGrants() throws {
        let access = MCPAccessController()
        let token = Data(repeating: 0x31, count: 32)
        let workspace = WorkspaceID()
        let id = try access.authorizeClient(name: "Test client", token: token, workspaces: [workspace])
        XCTAssertThrowsError(try access.authenticate(token: token))
        access.setEnabled(true)
        let grant = try access.authenticate(token: token)
        try access.validate(grant, workspaceID: workspace)
        XCTAssertThrowsError(try access.validate(grant, workspaceID: WorkspaceID()))
        XCTAssertThrowsError(try access.authenticate(token: Data(repeating: 0x32, count: 32)))
        access.setEnabled(false)
        access.setEnabled(true)
        XCTAssertThrowsError(try access.validate(grant, workspaceID: workspace))
        let resumed = try access.authenticate(token: token)
        access.revoke(id)
        XCTAssertThrowsError(try access.validate(resumed, workspaceID: workspace))
        XCTAssertThrowsError(try access.authenticate(token: token))
    }

    func testAuthorizationRejectsAmbiguousTokensAndEmptyScope() throws {
        let access = MCPAccessController()
        let token = Data(repeating: 5, count: 32)
        let workspace = WorkspaceID()
        XCTAssertThrowsError(try access.authorizeClient(name: "Client", token: token, workspaces: []))
        XCTAssertThrowsError(try access.authorizeClient(name: "Client", token: Data(), workspaces: [workspace]))
        _ = try access.authorizeClient(name: "Client", token: token, workspaces: [workspace])
        XCTAssertThrowsError(try access.authorizeClient(name: "Other", token: token, workspaces: [WorkspaceID()]))
        access.setEnabled(true)
        let grant = try access.authenticate(token: token)
        access.stop()
        access.setEnabled(true)
        XCTAssertThrowsError(try access.validate(grant, workspaceID: workspace))
        XCTAssertThrowsError(try access.authenticate(token: token))
    }

    func testUnicodeReplacementAndOverflowDefense() throws {
        let source = "A🙂e\u{301}Z"
        XCTAssertEqual(try MCPTextReplacement(location: 1, length: 2, text: "🌱").applying(to: source), "A🌱e\u{301}Z")
        for edit in [
            MCPTextReplacement(location: 2, length: 1, text: "x"),
            MCPTextReplacement(location: 4, length: 0, text: "x"),
            MCPTextReplacement(location: -1, length: 0, text: ""),
            MCPTextReplacement(location: 1, length: Int.max, text: ""),
            MCPTextReplacement(location: Int.max, length: Int.max, text: "")
        ] {
            XCTAssertThrowsError(try edit.applying(to: source))
        }
        XCTAssertEqual(try MCPTextReplacement(location: 0, length: 0, text: "a").applying(to: ""), "a")
        XCTAssertThrowsError(try MCPTextReplacement(location: 0, length: 0, text: String(repeating: "x", count: 1_048_577)).applying(to: ""))
    }

    func testRetryLedgerReplaysResultsAndNeverEvictsMutations() throws {
        let ledger = MCPMutationLedger(capacity: 1)
        let client = UUID(), request = UUID()
        let arguments = Data("canonical arguments".utf8)
        XCTAssertEqual(try ledger.reserve(client: client, request: request, canonicalArguments: arguments), .execute)
        XCTAssertEqual(try ledger.reserve(client: client, request: request, canonicalArguments: arguments), .pending)
        XCTAssertThrowsError(try ledger.reserve(client: client, request: request, canonicalArguments: Data("different".utf8)))
        try ledger.complete(client: client, request: request, result: Data("saved result".utf8))
        XCTAssertEqual(try ledger.reserve(client: client, request: request, canonicalArguments: arguments), .completed(Data("saved result".utf8)))
        XCTAssertThrowsError(try ledger.reserve(client: client, request: UUID(), canonicalArguments: arguments))
        XCTAssertThrowsError(try ledger.reserve(client: UUID(), request: request, canonicalArguments: arguments))
        XCTAssertThrowsError(try ledger.complete(client: client, request: request, result: Data()))
    }

    func testDeletionNeedsOneShotNativeApprovalBoundToRevisionAndClient() throws {
        var now: TimeInterval = 100
        let approvals = MCPDeletionApprovals(now: { now })
        let client = UUID()
        let revision = MCPRevision(incarnation: UUID(), documentID: DocumentID(), revision: 4)
        XCTAssertThrowsError(try approvals.consume(UUID(), client: client, revision: revision))
        let id = try approvals.recordNativeConfirmation(client: client, revision: revision)
        try approvals.consume(id, client: client, revision: revision)
        XCTAssertThrowsError(try approvals.consume(id, client: client, revision: revision))
        let stale = try approvals.recordNativeConfirmation(client: client, revision: revision)
        XCTAssertThrowsError(try approvals.consume(stale, client: client, revision: MCPRevision(incarnation: revision.incarnation, documentID: revision.documentID, revision: 5)))
        let wrongClient = try approvals.recordNativeConfirmation(client: client, revision: revision)
        XCTAssertThrowsError(try approvals.consume(wrongClient, client: UUID(), revision: revision))
        let expired = try approvals.recordNativeConfirmation(client: client, revision: revision)
        now = 160
        XCTAssertThrowsError(try approvals.consume(expired, client: client, revision: revision))
    }

    func testPathScopeBlocksSymlinkAndSiblingPrefixEscape() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = root.appendingPathComponent("scope", isDirectory: true)
        let other = root.appendingPathComponent("scope-other", isDirectory: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let link = scope.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        try MCPWorkspaceBoundary.validate(scope.appendingPathComponent("ok.md"), beneath: scope)
        XCTAssertThrowsError(try MCPWorkspaceBoundary.validate(scope, beneath: scope))
        XCTAssertThrowsError(try MCPWorkspaceBoundary.validate(other.appendingPathComponent("no.md"), beneath: scope))
        XCTAssertThrowsError(try MCPWorkspaceBoundary.validate(link.appendingPathComponent("no.md"), beneath: scope))
        XCTAssertThrowsError(try MCPWorkspaceBoundary.validate(scope.appendingPathComponent("../no.md"), beneath: scope))
    }

    func testLiveReadReturnsUnsavedTextAndRejectsStalePagination() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("document.md")
        try Data("disk text".utf8).write(to: file)
        let workspace = try Workspace(rootURL: root, accessSecurityScopedResource: false,
                                      recoverWorkspaceTransactions: false)
        let registry = DocumentBufferRegistry(identityStore: DocumentIdentityStore(storageURL: root.appendingPathComponent("ids.json")))
        let document = try registry.open(file, in: workspace)
        document.replaceText(with: "A🙂BC")
        let access = MCPAccessController()
        let token = Data(repeating: 3, count: 32)
        _ = try access.authorizeClient(name: "Test", token: token, workspaces: [workspace.id])
        access.setEnabled(true)
        let grant = try access.authenticate(token: token)
        let reader = MCPDocumentAccess(access: access, registry: registry)
        let first = try await reader.read(documentID: document.id, workspace: workspace, grant: grant, limit: 2)
        XCTAssertEqual(first.text, "A")
        XCTAssertEqual(first.nextUTF16Offset, 1)
        XCTAssertEqual(first.saveState, "pending")
        let second = try await reader.read(documentID: document.id, workspace: workspace, grant: grant,
                                           offset: 1, expectedRevision: first.revision)
        XCTAssertEqual(first.text + second.text, "A🙂BC")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "disk text")
        document.replaceText(with: "Changed by typing")
        do {
            _ = try await reader.read(documentID: document.id, workspace: workspace, grant: grant,
                                      offset: 1, expectedRevision: first.revision)
            XCTFail("Stale pagination must fail")
        } catch { XCTAssertEqual(error as? MCPAccessError, .staleRevision) }
        access.setEnabled(false)
        do {
            _ = try await reader.read(documentID: document.id, workspace: workspace, grant: grant)
            XCTFail("Paused server must not read")
        } catch { XCTAssertEqual(error as? MCPAccessError, .disabled) }
    }

    func testFinalEditorAuthorityRejectsMoveWithoutTextRevisionChange() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let approved = root.appendingPathComponent("approved", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let file = approved.appendingPathComponent("draft.md")
        try Data("unchanged".utf8).write(to: file)
        let workspace = try Workspace(rootURL: approved, accessSecurityScopedResource: false,
                                      recoverWorkspaceTransactions: false)
        let app = isolatedAppState(initialWorkspace: workspace)
        let document = try app.documentRegistry.open(file, in: workspace)
        let access = MCPAccessController(), token = Data(repeating: 9, count: 32)
        _ = try access.authorizeClient(name: "Editor authority", token: token, workspaces: [workspace.id])
        access.setEnabled(true)
        let grant = try access.authenticate(token: token)
        let tools = MCPTools(app: app, access: access)
        let revision = tools.reader.revision(for: document)
        try tools.validateMCPFinalEditorAuthority(document, workspace: workspace,
            sessionWorkspaceID: workspace.id, grant: grant)

        // Model a move while editor discovery or editor settlement is suspended.
        await Task.yield()
        document.didMove(to: other.appendingPathComponent("draft.md"), revision: nil)
        XCTAssertEqual(tools.reader.revision(for: document), revision)
        XCTAssertThrowsError(try tools.validateMCPFinalEditorAuthority(document, workspace: workspace,
            sessionWorkspaceID: workspace.id, grant: grant)) {
            XCTAssertEqual($0 as? MCPAccessError, .outsideWorkspace)
        }
        document.didMove(to: file, revision: nil)
        XCTAssertThrowsError(try tools.validateMCPFinalEditorAuthority(document, workspace: workspace,
            sessionWorkspaceID: WorkspaceID(), grant: grant))
        let replacementWorkspace = try Workspace(id: workspace.id, rootURL: other,
            accessSecurityScopedResource: false, recoverWorkspaceTransactions: false)
        XCTAssertThrowsError(try tools.validateMCPFinalEditorAuthority(document, workspace: replacementWorkspace,
            sessionWorkspaceID: workspace.id, grant: grant))
        access.setEnabled(false)
        XCTAssertThrowsError(try tools.validateMCPFinalEditorAuthority(document, workspace: workspace,
            sessionWorkspaceID: workspace.id, grant: grant))
        XCTAssertEqual(document.text, "unchanged")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clio-MCP-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
