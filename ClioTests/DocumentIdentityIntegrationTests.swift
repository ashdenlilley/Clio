import Foundation
import SQLite3
import XCTest
@testable import Clio

final class DocumentIdentityIntegrationTests: XCTestCase {
    func testIdentityPersistsAcrossStoreAndIndexRecreation() async throws {
        try await withTemporaryDirectory { rootURL in
            let fileURL = rootURL.appendingPathComponent("persistent.md")
            try write("persistent identity", to: fileURL)
            let workspace = WorkspaceDescriptor(rootURL: rootURL)
            let storeURL = rootURL.appendingPathComponent("identity-store.json")
            let firstStore = DocumentIdentityStore(storageURL: storeURL)
            let first = try await WorkspaceScanner(identityStore: firstStore).scan(
                workspace: workspace,
                policy: .default
            )
            let firstID = try XCTUnwrap(first.files.first?.documentID)

            let restoredStore = DocumentIdentityStore(storageURL: storeURL)
            let restored = try await WorkspaceScanner(identityStore: restoredStore).scan(
                workspace: workspace,
                policy: .default
            )
            XCTAssertEqual(restored.files.first?.documentID, firstID)

            let index = try SQLiteSearchIndex(
                databaseURL: rootURL.appendingPathComponent("rebuilt.sqlite3"),
                identityStore: restoredStore
            )
            try await index.rebuild(workspaces: [workspace], policy: .default)
            let result = try await finalBatch(
                from: await index.quickOpen(WorkspaceSearchQuery(text: "persistent"))
            )
            XCTAssertEqual(result.results.first?.documentID, firstID)
        }
    }

    func testRenamePreservesIdentityAndDeletionRecreationDoesNot() async throws {
        try await withTemporaryDirectory { rootURL in
            let sourceURL = rootURL.appendingPathComponent("source.md")
            let movedURL = rootURL.appendingPathComponent("moved.md")
            try write("first inode", to: sourceURL)
            let workspace = WorkspaceDescriptor(rootURL: rootURL)
            let store = DocumentIdentityStore(
                storageURL: rootURL.appendingPathComponent("identities.json")
            )
            let scanner = WorkspaceScanner(identityStore: store)
            let originalSnapshot = try await scanner.scan(
                workspace: workspace,
                policy: .default
            )
            let original = try XCTUnwrap(originalSnapshot.files.first)
            try FileManager.default.moveItem(at: sourceURL, to: movedURL)
            let destinationLocator = try DocumentLocator(
                workspaceID: workspace.id,
                relativePath: "moved.md"
            )
            _ = try store.migrate(
                from: original.locator,
                to: destinationLocator,
                physicalIdentity: .authorizedFile(at: movedURL)
            )
            let movedSnapshot = try await scanner.scan(
                workspace: workspace,
                policy: .default
            )
            let moved = try XCTUnwrap(movedSnapshot.files.first)
            XCTAssertEqual(moved.documentID, original.documentID)

            try store.tombstone(destinationLocator, documentID: moved.documentID)
            try FileManager.default.removeItem(at: movedURL)
            try write("new inode", to: movedURL)
            let recreatedSnapshot = try await scanner.scan(
                workspace: workspace,
                policy: .default
            )
            let recreated = try XCTUnwrap(recreatedSnapshot.files.first)
            XCTAssertNotEqual(recreated.documentID, moved.documentID)
        }
    }

    func testMissedRenameAndOldPathRecreationDoNotMergeDistinctInodes() async throws {
        try await withTemporaryDirectory { rootURL in
            let oldURL = rootURL.appendingPathComponent("a.md")
            let movedURL = rootURL.appendingPathComponent("z.md")
            try write("original", to: oldURL)
            let workspace = WorkspaceDescriptor(rootURL: rootURL)
            let store = DocumentIdentityStore(
                storageURL: rootURL.appendingPathComponent("identities.json")
            )
            let scanner = WorkspaceScanner(identityStore: store)
            let initial = try await scanner.scan(workspace: workspace, policy: .default)
            let originalID = try XCTUnwrap(initial.files.first?.documentID)

            try FileManager.default.moveItem(at: oldURL, to: movedURL)
            try write("recreated", to: oldURL)
            let rescanned = try await scanner.scan(workspace: workspace, policy: .default)
            let byPath = Dictionary(
                uniqueKeysWithValues: rescanned.files.map { ($0.relativePath, $0.documentID) }
            )
            XCTAssertEqual(byPath["z.md"], originalID)
            XCTAssertNotEqual(byPath["a.md"], originalID)
            XCTAssertNotEqual(byPath["a.md"], byPath["z.md"])
        }
    }

    func testOverlappingWorkspacesShareIdentityAndSearchRows() async throws {
        try await withTemporaryDirectory { rootURL in
            let nestedURL = rootURL.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
            try write("shared overlapping token", to: nestedURL.appendingPathComponent("note.md"))
            let parent = WorkspaceDescriptor(rootURL: rootURL)
            let nested = WorkspaceDescriptor(rootURL: nestedURL)
            let store = DocumentIdentityStore(
                storageURL: rootURL.appendingPathComponent("identities.json")
            )
            let scanner = WorkspaceScanner(identityStore: store)
            let parentSnapshot = try await scanner.scan(workspace: parent, policy: .default)
            let nestedSnapshot = try await scanner.scan(workspace: nested, policy: .default)
            let parentFile = try XCTUnwrap(parentSnapshot.files.first)
            let nestedFile = try XCTUnwrap(nestedSnapshot.files.first)
            XCTAssertEqual(parentFile.documentID, nestedFile.documentID)

            let index = try SQLiteSearchIndex(
                databaseURL: rootURL.appendingPathComponent("overlap.sqlite3"),
                identityStore: store
            )
            try await index.rebuild(workspaces: [parent, nested], policy: .default)
            let parentResult = try await finalBatch(
                from: await index.search(
                    WorkspaceSearchQuery(text: "overlapping", workspaceFilter: parent.id)
                )
            )
            let nestedResult = try await finalBatch(
                from: await index.search(
                    WorkspaceSearchQuery(text: "overlapping", workspaceFilter: nested.id)
                )
            )
            XCTAssertEqual(parentResult.results.first?.documentID, parentFile.documentID)
            XCTAssertEqual(nestedResult.results.first?.documentID, parentFile.documentID)
        }
    }

    func testLegacyIdentityCoupledIndexMigratesToLocatorRows() async throws {
        try await withTemporaryDirectory { rootURL in
            let databaseURL = rootURL.appendingPathComponent("legacy.sqlite3")
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
            let legacySchema = """
            CREATE TABLE documents (
                document_id TEXT PRIMARY KEY,
                workspace_id TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                content TEXT NOT NULL
            )
            """
            XCTAssertEqual(sqlite3_exec(database, legacySchema, nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
            database = nil

            let noteURL = rootURL.appendingPathComponent("migrated.md")
            try write("legacy migration token", to: noteURL)
            let workspace = WorkspaceDescriptor(rootURL: rootURL)
            let index = try SQLiteSearchIndex(
                databaseURL: databaseURL,
                identityStore: DocumentIdentityStore(storageURL: nil)
            )
            try await index.rebuild(workspaces: [workspace], policy: .default)
            let result = try await finalBatch(
                from: await index.search(WorkspaceSearchQuery(text: "migration token"))
            )
            XCTAssertEqual(result.results.first?.relativePath, "migrated.md")
        }
    }

    @MainActor
    func testFirstUntitledSaveBindsTheDocumentsExistingID() throws {
        try withTemporaryDirectory { rootURL in
            let store = DocumentIdentityStore(
                storageURL: rootURL.appendingPathComponent("identities.json")
            )
            let workspace = try Workspace(
                rootURL: rootURL,
                accessSecurityScopedResource: false
            )
            let registry = DocumentBufferRegistry(identityStore: store)
            let document = Document()
            registry.register(document, in: workspace)
            let autosaver = registry.autosaver(for: document, in: workspace)
            document.replaceText(with: "materialize me")
            autosaver.documentDidChange(document)

            let fileURL = try XCTUnwrap(document.fileURL)
            let locator = try workspace.locator(for: fileURL)
            XCTAssertEqual(store.storedDocumentID(for: locator), document.id)
            XCTAssertTrue(registry.document(at: fileURL, in: workspace) === document)
        }
    }

    @MainActor
    func testRegisterCannotReplaceCanonicalObjectForSameIDOrFile() throws {
        try withTemporaryDirectory { rootURL in
            let fileURL = rootURL.appendingPathComponent("one.md")
            try write("one", to: fileURL)
            let workspace = try Workspace(rootURL: rootURL, accessSecurityScopedResource: false)
            let registry = DocumentBufferRegistry(
                identityStore: DocumentIdentityStore(storageURL: nil)
            )
            let id = DocumentID()
            let canonical = try Document(contentsOf: fileURL, id: id)
            let duplicateID = try Document(contentsOf: fileURL, id: id)
            let duplicateFile = try Document(contentsOf: fileURL)
            registry.register(canonical, in: workspace)
            registry.register(duplicateID, in: workspace)
            registry.register(duplicateFile, in: workspace)

            XCTAssertTrue(registry.document(withID: id) === canonical)
            XCTAssertTrue(registry.document(at: fileURL, in: workspace) === canonical)
            XCTAssertEqual(registry.openDocuments.count, 1)
        }
    }

    func testUnrelatedPreferredIDCollisionAllocatesDistinctIdentity() throws {
        try withTemporaryDirectory { rootURL in
            let firstURL = rootURL.appendingPathComponent("first.md")
            let secondURL = rootURL.appendingPathComponent("second.md")
            try write("first", to: firstURL)
            try write("second", to: secondURL)
            let workspaceID = WorkspaceID()
            let preferredID = DocumentID()
            let store = DocumentIdentityStore(storageURL: nil)
            let first = try store.resolve(
                DocumentIdentityCandidate(
                    locator: try DocumentLocator(
                        workspaceID: workspaceID,
                        relativePath: "first.md"
                    ),
                    physicalIdentity: .authorizedFile(at: firstURL),
                    canonicalPath: firstURL.path,
                    preferredID: preferredID
                )
            )
            let second = try store.resolve(
                DocumentIdentityCandidate(
                    locator: try DocumentLocator(
                        workspaceID: workspaceID,
                        relativePath: "second.md"
                    ),
                    physicalIdentity: .authorizedFile(at: secondURL),
                    canonicalPath: secondURL.path,
                    preferredID: preferredID
                )
            )

            XCTAssertEqual(first, preferredID)
            XCTAssertNotEqual(second, preferredID)
            XCTAssertNotEqual(second, first)
        }
    }

    @MainActor
    func testLiveRegistryIdentityWinsAndRepairsPersistentMismatch() throws {
        try withTemporaryDirectory { rootURL in
            let fileURL = rootURL.appendingPathComponent("repair.md")
            try write("repair", to: fileURL)
            let workspace = try Workspace(rootURL: rootURL, accessSecurityScopedResource: false)
            let locator = try workspace.locator(for: fileURL)
            let physical = PhysicalFileIdentity.authorizedFile(at: fileURL)
            let store = DocumentIdentityStore(
                storageURL: rootURL.appendingPathComponent("identities.json")
            )
            let registry = DocumentBufferRegistry(identityStore: store)
            let liveID = DocumentID()
            registry.updateAliases(for: liveID, identity: physical, locator: locator)
            let staleID = DocumentID()
            try store.bind(
                staleID,
                locator: locator,
                physicalIdentity: physical,
                canonicalPath: fileURL.path
            )

            XCTAssertEqual(
                registry.documentID(
                    for: physical,
                    locator: locator,
                    preferredID: staleID,
                    canonicalPath: fileURL.path
                ),
                liveID
            )
            XCTAssertEqual(store.storedDocumentID(for: locator), liveID)
        }
    }
}

private extension DocumentIdentityIntegrationTests {
    func write(_ source: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(source.utf8).write(to: url, options: .atomic)
    }

    func finalBatch(
        from stream: AsyncThrowingStream<SearchBatch, Error>
    ) async throws -> SearchBatch {
        var final = SearchBatch(results: [], isFinal: true)
        for try await batch in stream { final = batch }
        return final
    }

    func withTemporaryDirectory<T>(_ operation: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try operation(directory)
    }

    func withTemporaryDirectory<T>(
        _ operation: (URL) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioIdentityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation(directory)
    }
}
