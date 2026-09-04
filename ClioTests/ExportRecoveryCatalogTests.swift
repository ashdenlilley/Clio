import Foundation
import XCTest
@testable import Clio

final class ExportRecoveryCatalogTests: XCTestCase {
    func testCatalogPersistsGrantAndRecoversOnlySelectedDirectory() throws {
        try withTemporaryRoots { destination, catalogRoot, journalRoot in
            let direct = try interruptedCreate(
                in: destination,
                filename: "Draft.html",
                contents: Data("complete export".utf8)
            )
            let nestedDirectory = destination.appendingPathComponent(
                "Nested",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: nestedDirectory,
                withIntermediateDirectories: true
            )
            let nested = try interruptedCreate(
                in: nestedDirectory,
                filename: "Nested.html",
                contents: Data("nested export".utf8)
            )

            let catalog = makeCatalog(rootURL: catalogRoot)
            try catalog.remember(destinationDirectory: destination)

            // A new instance proves the directory grant was durable rather
            // than retained only in process memory.
            let relaunched = makeCatalog(rootURL: catalogRoot)
            let journal = CrashRecoveryJournal(rootURL: journalRoot)
            XCTAssertEqual(
                try relaunched.recoverInterruptedExports(journal: journal),
                1
            )

            let records = try journal.validRecords()
            XCTAssertEqual(records.map(\.data), [Data("complete export".utf8)])
            XCTAssertEqual(records.map(\.targetURL), [
                destination.appendingPathComponent("Draft.html")
            ])
            XCTAssertFalse(FileManager.default.fileExists(atPath: direct.manifestURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: direct.manifest.temporaryURL.path))

            // Export recovery never recursively scans an arbitrary selected
            // folder. The nested transaction belongs to a different grant.
            XCTAssertTrue(FileManager.default.fileExists(atPath: nested.manifestURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: nested.manifest.temporaryURL.path))
        }
    }

    func testRevokedGrantRemainsAvailableForLaterRecovery() throws {
        try withTemporaryRoots { destination, catalogRoot, journalRoot in
            _ = try interruptedCreate(
                in: destination,
                filename: "Draft.pdf",
                contents: Data("pdf candidate".utf8)
            )
            try makeCatalog(rootURL: catalogRoot).remember(
                destinationDirectory: destination
            )

            let revoked = ExportRecoveryCatalog(
                rootURL: catalogRoot,
                bookmarkMaker: Self.bookmark,
                bookmarkResolver: { _ in
                    throw Workspace.WorkspaceError.securityScopedAccessDenied(destination)
                }
            )
            let journal = CrashRecoveryJournal(rootURL: journalRoot)
            XCTAssertEqual(
                try revoked.recoverInterruptedExports(journal: journal),
                0
            )

            // A temporary permission failure must not discard the catalog
            // entry; recovery can resume after access is restored.
            XCTAssertEqual(
                try makeCatalog(rootURL: catalogRoot)
                    .recoverInterruptedExports(journal: journal),
                1
            )
            XCTAssertEqual(
                try journal.validRecords().map(\.data),
                [Data("pdf candidate".utf8)]
            )
        }
    }

    func testRememberRejectsAFileAsDestinationDirectory() throws {
        try withTemporaryRoots { destination, catalogRoot, _ in
            let file = destination.appendingPathComponent("not-a-folder")
            try Data().write(to: file)
            XCTAssertThrowsError(
                try makeCatalog(rootURL: catalogRoot).remember(
                    destinationDirectory: file
                )
            ) { error in
                XCTAssertEqual(
                    error as? DocumentExportError,
                    .unsupportedDestination(file)
                )
            }
        }
    }

    func testUnpersistableParentSelectsAppContainerFallback() async throws {
        try await withTemporaryRootsAsync { destination, catalogRoot, _ in
            let catalog = ExportRecoveryCatalog(
                rootURL: catalogRoot,
                bookmarkMaker: { _ in throw CocoaError(.fileWriteNoPermission) },
                bookmarkResolver: Self.resolve
            )
            let strategy = await catalog.recoveryStrategy(
                for: destination.appendingPathComponent("Draft.pdf")
            )
            XCTAssertEqual(strategy, .appContainerCheckpoint)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: catalogRoot.appendingPathComponent("roots.plist").path
                )
            )
        }
    }

    func testCatalogLoadsPreviousGenerationAfterInterruptedPrimarySwap() throws {
        try withTemporaryRoots { destination, catalogRoot, journalRoot in
            let secondDirectory = destination.deletingLastPathComponent()
                .appendingPathComponent("Second", isDirectory: true)
            try FileManager.default.createDirectory(
                at: secondDirectory,
                withIntermediateDirectories: true
            )
            _ = try interruptedCreate(
                in: destination,
                filename: "First.html",
                contents: Data("first".utf8)
            )
            _ = try interruptedCreate(
                in: secondDirectory,
                filename: "Second.html",
                contents: Data("second".utf8)
            )

            let catalog = makeCatalog(rootURL: catalogRoot)
            try catalog.remember(destinationDirectory: destination)
            try catalog.remember(destinationDirectory: secondDirectory)

            let primary = catalogRoot.appendingPathComponent("roots.plist")
            let previous = catalogRoot.appendingPathComponent("roots.previous.plist")
            // This is the exact durable state after the old primary has been
            // archived but before the new primary rename completes.
            try? FileManager.default.removeItem(at: previous)
            try FileManager.default.moveItem(at: primary, to: previous)

            let journal = CrashRecoveryJournal(rootURL: journalRoot)
            XCTAssertEqual(
                try makeCatalog(rootURL: catalogRoot)
                    .recoverInterruptedExports(journal: journal),
                2
            )
            XCTAssertEqual(Set(try journal.validRecords().map(\.data)), [
                Data("first".utf8),
                Data("second".utf8),
            ])
        }
    }
}

private extension ExportRecoveryCatalogTests {
    static let bookmark: ExportRecoveryCatalog.BookmarkMaker = { url in
        Data(url.standardizedFileURL.path.utf8)
    }

    static let resolve: ExportRecoveryCatalog.BookmarkResolver = { data in
        Workspace.BookmarkResolution(
            url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }

    func makeCatalog(rootURL: URL) -> ExportRecoveryCatalog {
        ExportRecoveryCatalog(
            rootURL: rootURL,
            bookmarkMaker: Self.bookmark,
            bookmarkResolver: Self.resolve
        )
    }

    func interruptedCreate(
        in directory: URL,
        filename: String,
        contents: Data
    ) throws -> AtomicWriteTransactionContext {
        let transaction = try AtomicWriteTransactions.begin(
            contents: contents,
            destinationURL: directory.appendingPathComponent(filename),
            operation: .create,
            expectedRevision: nil
        )
        try contents.write(
            to: transaction.manifest.temporaryURL,
            options: .withoutOverwriting
        )
        return transaction
    }

    func withTemporaryRoots(
        _ operation: (URL, URL, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClioExportRecoveryCatalog-\(UUID().uuidString)",
            isDirectory: true
        )
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let journal = root.appendingPathComponent("Journal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(destination, catalog, journal)
    }

    func withTemporaryRootsAsync(
        _ operation: (URL, URL, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClioExportRecoveryCatalog-\(UUID().uuidString)",
            isDirectory: true
        )
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        let catalog = root.appendingPathComponent("Catalog", isDirectory: true)
        let journal = root.appendingPathComponent("Journal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(destination, catalog, journal)
    }
}
