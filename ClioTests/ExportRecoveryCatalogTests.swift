import Darwin
import Foundation
import XCTest
@testable import Clio

final class ExportRecoveryCatalogTests: XCTestCase {
    func testCatalogPersistsGrantAndExposesOnlySelectedDirectory() async throws {
        try await withTemporaryRootsAsync { destination, catalogRoot, _ in
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
            let recoveries = try await relaunched.interruptedExports()
            let item = try XCTUnwrap(recoveries.first)
            XCTAssertEqual(recoveries.count, 1)
            XCTAssertEqual(item.kind, .renderedCandidate)
            XCTAssertEqual(item.candidateURL, direct.manifest.temporaryURL)
            XCTAssertEqual(item.intendedDestinationURL, destination.appendingPathComponent("Draft.html"))
            XCTAssertEqual(try Data(contentsOf: item.candidateURL), Data("complete export".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: direct.manifestURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: direct.manifest.temporaryURL.path))

            // Export recovery never recursively scans an arbitrary selected
            // folder. The nested transaction belongs to a different grant.
            XCTAssertTrue(FileManager.default.fileExists(atPath: nested.manifestURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: nested.manifest.temporaryURL.path))

            try await relaunched.discard(item)
            XCTAssertFalse(FileManager.default.fileExists(atPath: direct.manifestURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: direct.manifest.temporaryURL.path))
        }
    }

    func testRevokedGrantRemainsAvailableForLaterRecovery() async throws {
        try await withTemporaryRootsAsync { destination, catalogRoot, _ in
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
            let revokedRecoveries = try await revoked.interruptedExports()
            XCTAssertEqual(revokedRecoveries.count, 0)

            // A temporary permission failure must not discard the catalog
            // entry; recovery can resume after access is restored.
            let restoredRecoveries = try await makeCatalog(rootURL: catalogRoot)
                .interruptedExports()
            XCTAssertEqual(restoredRecoveries.count, 1)
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

    func testCatalogLoadsPreviousGenerationAfterInterruptedPrimarySwap() async throws {
        try await withTemporaryRootsAsync { destination, catalogRoot, _ in
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

            let recoveries = try await makeCatalog(rootURL: catalogRoot)
                .interruptedExports()
            XCTAssertEqual(recoveries.count, 2)
            XCTAssertEqual(
                Set(try recoveries.map { try Data(contentsOf: $0.candidateURL) }),
                [Data("first".utf8), Data("second".utf8)]
            )
        }
    }

    func testDuplicateBookmarksResolvingToSameMovedDirectoryAreScannedOnce() async throws {
        try await withTemporaryRootsAsync { destination, catalogRoot, _ in
            _ = try interruptedCreate(
                in: destination,
                filename: "Draft.html",
                contents: Data("one recovery".utf8)
            )
            let formerLocation = destination.deletingLastPathComponent()
                .appendingPathComponent("Former Location", isDirectory: true)
            try FileManager.default.createDirectory(
                at: formerLocation,
                withIntermediateDirectories: true
            )

            let writer = makeCatalog(rootURL: catalogRoot)
            try writer.remember(destinationDirectory: destination)
            try writer.remember(destinationDirectory: formerLocation)

            let movedCatalog = ExportRecoveryCatalog(
                rootURL: catalogRoot,
                bookmarkMaker: Self.bookmark,
                bookmarkResolver: { _ in
                    Workspace.BookmarkResolution(
                        url: destination,
                        isStale: false
                    )
                }
            )
            let recoveries = try await movedCatalog.interruptedExports()
            XCTAssertEqual(recoveries.count, 1)
        }
    }

    func testDiscardRejectsSameNamedArtifactOutsideResolvedDirectory() async throws {
        try await withTemporaryRootsAsync { destination, catalogRoot, _ in
            let transaction = try interruptedCreate(
                in: destination,
                filename: "Draft.html",
                contents: Data("protected recovery".utf8)
            )
            let catalog = makeCatalog(rootURL: catalogRoot)
            try catalog.remember(destinationDirectory: destination)
            let recoveries = try await catalog.interruptedExports()
            let item = try XCTUnwrap(recoveries.first)
            let forgedRoot = destination.deletingLastPathComponent()
                .appendingPathComponent("Forged", isDirectory: true)
            try FileManager.default.createDirectory(
                at: forgedRoot,
                withIntermediateDirectories: true
            )
            let forged = ExportRecoveryItem(
                id: item.id,
                kind: item.kind,
                format: item.format,
                candidateURL: forgedRoot.appendingPathComponent(
                    item.candidateURL.lastPathComponent
                ),
                intendedDestinationURL: item.intendedDestinationURL,
                byteCount: item.byteCount,
                contentDigest: item.contentDigest,
                documentID: item.documentID,
                generation: item.generation,
                sourceFingerprint: item.sourceFingerprint,
                createdAt: item.createdAt,
                storage: item.storage
            )

            do {
                try await catalog.discard(forged)
                XCTFail("A same-named file outside the remembered directory was accepted")
            } catch {
                // Expected: action-time validation includes the complete path.
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: transaction.manifestURL.path)
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: transaction.manifest.temporaryURL.path
                )
            )
        }
    }

    func testDirectoryTransactionBeyondJournalLimitStaysFileBacked() async throws {
        try await withTemporaryRootsAsync { destination, catalogRoot, journalRoot in
            let byteCount = CrashRecoveryJournal.maximumRecordByteCount + 1
            let transaction = try interruptedSparseCreate(
                in: destination,
                filename: "Large.pdf",
                byteCount: byteCount
            )
            let catalog = makeCatalog(rootURL: catalogRoot)
            try catalog.remember(destinationDirectory: destination)

            let relaunched = makeCatalog(rootURL: catalogRoot)
            let recoveries = try await relaunched.interruptedExports()
            let item = try XCTUnwrap(recoveries.first)
            XCTAssertEqual(item.byteCount, byteCount)
            XCTAssertEqual(item.kind, .renderedCandidate)
            XCTAssertEqual(item.candidateURL, transaction.manifest.temporaryURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.candidateURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.manifestURL.path))
            XCTAssertTrue(try CrashRecoveryJournal(rootURL: journalRoot).validRecords().isEmpty)
        }
    }

    func testCancelledDirectoryRecoveryScanLeavesCandidateAndManifest() async throws {
        try await withTemporaryRootsAsync { destination, catalogRoot, _ in
            let transaction = try interruptedSparseCreate(
                in: destination,
                filename: "Cancel.pdf",
                byteCount: AtomicWriteTransactions.maximumRecoverableByteCount - 1
            )
            let catalog = makeCatalog(rootURL: catalogRoot)
            try catalog.remember(destinationDirectory: destination)

            let task = Task { try await catalog.interruptedExports() }
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("A cancelled recovery scan must not publish a partial result")
            } catch is CancellationError {
                // Expected.
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.manifestURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.manifest.temporaryURL.path))
        }
    }

    func testExpiredRenderedCandidateRemovesOnlyTransactionFiles() async throws {
        try await assertExpiredRecovery(kind: .renderedCandidate)
    }

    func testExpiredDisplacedDestinationRemovesPriorVersionButKeepsExport() async throws {
        try await assertExpiredRecovery(kind: .displacedDestination)
    }

    func testExpiredCompletedDestinationRemovesMetadataButKeepsExport() async throws {
        try await assertExpiredRecovery(kind: .completedDestination)
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

    func makeCatalog(
        rootURL: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ExportRecoveryCatalog {
        ExportRecoveryCatalog(
            rootURL: rootURL,
            bookmarkMaker: Self.bookmark,
            bookmarkResolver: Self.resolve,
            now: now
        )
    }

    func assertExpiredRecovery(
        kind: ExportRecoveryKind
    ) async throws {
        try await withTemporaryRootsAsync { destination, catalogRoot, _ in
            let createdAt = Date(timeIntervalSince1970: 1_000)
            let transaction = try interruptedTransaction(
                kind: kind,
                in: destination,
                filename: "Expired.html",
                candidate: Data("rendered export".utf8),
                displaced: Data("pre-export version".utf8),
                createdAt: createdAt
            )
            let catalog = makeCatalog(
                rootURL: catalogRoot,
                now: { createdAt.addingTimeInterval(RecoveryStore.retention + 1) }
            )
            try catalog.remember(destinationDirectory: destination)

            let recoveries = try await catalog.interruptedExports()
            XCTAssertTrue(recoveries.isEmpty)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: transaction.manifestURL.path)
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: transaction.manifest.temporaryURL.path
                )
            )
            let destinationURL = transaction.manifest.destinationURL
            switch kind {
            case .renderedCandidate:
                XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
            case .displacedDestination, .completedDestination:
                XCTAssertEqual(
                    try Data(contentsOf: destinationURL),
                    Data("rendered export".utf8)
                )
            }
        }
    }

    func interruptedTransaction(
        kind: ExportRecoveryKind,
        in directory: URL,
        filename: String,
        candidate: Data,
        displaced: Data,
        createdAt: Date
    ) throws -> AtomicWriteTransactionContext {
        let destinationURL = directory.appendingPathComponent(filename)
        let operation: AtomicWriteOperation
        let expectedRevision: DiskRevision?
        if kind == .displacedDestination {
            try displaced.write(to: destinationURL, options: .withoutOverwriting)
            operation = .replace
            expectedRevision = try DocumentRevisionReader.revision(at: destinationURL)
        } else {
            operation = .create
            expectedRevision = nil
        }
        let initial = try AtomicWriteTransactions.begin(
            contents: candidate,
            destinationURL: destinationURL,
            operation: operation,
            expectedRevision: expectedRevision
        )
        try candidate.write(
            to: initial.manifest.temporaryURL,
            options: .withoutOverwriting
        )
        let manifest = AtomicWriteTransactionManifest(
            schemaVersion: initial.manifest.schemaVersion,
            id: initial.manifest.id,
            operation: initial.manifest.operation,
            destinationURL: initial.manifest.destinationURL,
            temporaryURL: initial.manifest.temporaryURL,
            candidateByteCount: initial.manifest.candidateByteCount,
            candidateDigest: initial.manifest.candidateDigest,
            expectedRevision: initial.manifest.expectedRevision,
            createdAt: createdAt
        )
        try FileManager.default.removeItem(at: initial.manifestURL)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(manifest).write(
            to: initial.manifestURL,
            options: .withoutOverwriting
        )
        let transaction = AtomicWriteTransactionContext(
            manifest: manifest,
            manifestURL: initial.manifestURL
        )
        switch kind {
        case .renderedCandidate:
            break
        case .completedDestination:
            let result = renamex_np(
                transaction.manifest.temporaryURL.path,
                transaction.manifest.destinationURL.path,
                UInt32(RENAME_EXCL)
            )
            XCTAssertEqual(result, 0)
        case .displacedDestination:
            let result = renamex_np(
                transaction.manifest.temporaryURL.path,
                transaction.manifest.destinationURL.path,
                UInt32(RENAME_SWAP)
            )
            XCTAssertEqual(result, 0)
        }
        return transaction
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

    func interruptedSparseCreate(
        in directory: URL,
        filename: String,
        byteCount: Int64
    ) throws -> AtomicWriteTransactionContext {
        let id = UUID()
        let destinationURL = directory.appendingPathComponent(filename)
        let temporaryURL = directory.appendingPathComponent(
            AtomicWriteTransactions.temporaryPrefix + id.uuidString.lowercased()
        )
        XCTAssertTrue(
            FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        )
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
        let revision = try DocumentRevisionReader.revision(
            at: temporaryURL,
            maximumByteCount: AtomicWriteTransactions.maximumRecoverableByteCount
        )
        let manifest = AtomicWriteTransactionManifest(
            schemaVersion: AtomicWriteTransactionManifest.schemaVersion,
            id: id,
            operation: .create,
            destinationURL: destinationURL,
            temporaryURL: temporaryURL,
            candidateByteCount: revision.byteCount,
            candidateDigest: revision.contentDigest,
            expectedRevision: nil,
            createdAt: Date()
        )
        let manifestURL = directory.appendingPathComponent(
            AtomicWriteTransactions.manifestPrefix
                + id.uuidString.lowercased()
                + AtomicWriteTransactions.manifestSuffix
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(manifest).write(
            to: manifestURL,
            options: .withoutOverwriting
        )
        return AtomicWriteTransactionContext(
            manifest: manifest,
            manifestURL: manifestURL
        )
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
