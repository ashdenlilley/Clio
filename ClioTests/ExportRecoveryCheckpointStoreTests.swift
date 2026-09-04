import Foundation
import XCTest
@testable import Clio

@MainActor
final class ExportRecoveryCheckpointStoreTests: XCTestCase {
    func testCheckpointSurvivesRelaunchAndEntersSevenDayRecoveryFlow() async throws {
        try await withTemporaryRoots { destinationRoot, storeRoot, journalRoot in
            let snapshot = makeSnapshot(source: "# Recoverable export\n\nBody")
            let parsed = try await SourcePreservingMarkdownParser().parse(snapshot)
            let destination = destinationRoot.appendingPathComponent("Draft.html")
            let staged = try await HTMLDocumentExporter().prepare(
                parsed: parsed,
                request: makeRequest(
                    .html,
                    snapshot: snapshot,
                    destination: destination,
                    strategy: .appContainerCheckpoint
                ),
                collisionResolution: nil
            )
            defer { staged.discard() }
            let expected = try Data(contentsOf: staged.temporaryURL)
            let store = ExportRecoveryCheckpointStore(rootURL: storeRoot)
            let checkpoint = try await store.checkpoint(staged)
            XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.manifestURL.path))
            XCTAssertEqual(try Data(contentsOf: checkpoint.candidateURL), expected)

            let relaunched = ExportRecoveryCheckpointStore(rootURL: storeRoot)
            let journal = CrashRecoveryJournal(rootURL: journalRoot)
            let recovered = try await relaunched.recoverInterruptedCheckpoints(
                journal: journal
            )
            XCTAssertEqual(recovered, 1)
            let record = try XCTUnwrap(journal.validRecords().first)
            XCTAssertEqual(record.data, expected)
            XCTAssertEqual(record.targetURL, destination)
            XCTAssertEqual(record.filename, "Draft.html")
            XCTAssertEqual(record.reason, .atomicCandidate)
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.manifestURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.candidateURL.path))
        }
    }

    func testOversizedCheckpointIsRejectedBeforeCopying() async throws {
        try await withTemporaryRoots { destinationRoot, storeRoot, _ in
            let source = destinationRoot.appendingPathComponent("staged.html")
            try Data("small".utf8).write(to: source)
            let destination = destinationRoot.appendingPathComponent("large.html")
            let staged = StagedDocumentExport(
                format: .html,
                temporaryURL: source,
                reservation: ExportDestinationReservation(
                    url: destination,
                    commit: .create
                ),
                byteCount: AtomicWriteTransactions.maximumRecoverableByteCount + 1,
                documentID: DocumentID(),
                generation: BufferGeneration(),
                sourceFingerprint: "oversized"
            )
            do {
                _ = try await ExportRecoveryCheckpointStore(rootURL: storeRoot)
                    .checkpoint(staged)
                XCTFail("An unrecoverable artifact must not enter the install phase")
            } catch DocumentExportError.artifactTooLarge(
                let foundURL,
                let byteCount,
                let maximumByteCount
            ) {
                XCTAssertEqual(foundURL, destination)
                XCTAssertEqual(byteCount, AtomicWriteTransactions.maximumRecoverableByteCount + 1)
                XCTAssertEqual(maximumByteCount, AtomicWriteTransactions.maximumRecoverableByteCount)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: storeRoot.path))
        }
    }

    func testFallbackCoordinatorCleansCheckpointAfterSuccessfulSafeSave() async throws {
        try await withTemporaryRoots { destinationRoot, storeRoot, _ in
            let snapshot = makeSnapshot(source: "# File grant")
            let destination = destinationRoot.appendingPathComponent("Grant.html")
            let coordinator = DocumentExportCoordinator(
                recoveryCheckpointStore: ExportRecoveryCheckpointStore(rootURL: storeRoot),
                fileGrantWriter: ExportFileGrantWriter()
            )
            let receipt = try await coordinator.export(makeRequest(
                .html,
                snapshot: snapshot,
                destination: destination,
                strategy: .appContainerCheckpoint
            ))
            XCTAssertEqual(receipt.destinationURL, destination)
            XCTAssertTrue(try String(contentsOf: destination).contains("<h1>File grant</h1>"))
            try await waitUntil {
                (try? FileManager.default.contentsOfDirectory(
                    at: storeRoot,
                    includingPropertiesForKeys: nil
                ).isEmpty) == true
            }
        }
    }

    func testFallbackENOSPCKeepsDestinationAndCleansNormalFailureCheckpoint() async throws {
        try await withTemporaryRoots { destinationRoot, storeRoot, _ in
            let snapshot = makeSnapshot(source: "candidate")
            let destination = destinationRoot.appendingPathComponent("Full.html")
            try Data("outside".utf8).write(to: destination)
            let collision = try XCTUnwrap(ExportDestination.collision(at: destination))
            let coordinator = DocumentExportCoordinator(
                recoveryCheckpointStore: ExportRecoveryCheckpointStore(rootURL: storeRoot),
                fileGrantWriter: ENOSPCExportWriter()
            )
            do {
                _ = try await coordinator.export(
                    makeRequest(
                        .html,
                        snapshot: snapshot,
                        destination: destination,
                        strategy: .appContainerCheckpoint
                    ),
                    collisionResolution: ExportCollisionResolution(
                        collision: collision,
                        choice: .replace
                    )
                )
                XCTFail("Injected full volume must fail")
            } catch let error as NSError {
                XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
                XCTAssertEqual(error.code, Int(ENOSPC))
            }
            XCTAssertEqual(try String(contentsOf: destination), "outside")
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    at: storeRoot,
                    includingPropertiesForKeys: nil
                ).isEmpty
            )
        }
    }

    func testFinalInstallDoesNotBlockMainActor() async throws {
        try await withTemporaryRoots { destinationRoot, _, _ in
            let destination = destinationRoot.appendingPathComponent("Off-main.html")
            let writer = BlockingExportWriter(delay: 0.35)
            let coordinator = DocumentExportCoordinator(directoryWriter: writer)
            let snapshot = makeSnapshot(source: "off-main install")
            let operation = Task {
                try await coordinator.export(makeRequest(
                    .html,
                    snapshot: snapshot,
                    destination: destination,
                    strategy: .directoryTransaction
                ))
            }

            try await waitUntil { writer.hasStarted }
            // If installation were still MainActor-isolated, this assertion
            // could not execute until the blocking writer had returned.
            XCTAssertFalse(writer.hasFinished)
            _ = try await operation.value
            XCTAssertTrue(writer.hasFinished)
        }
    }

    func testFileGrantWriterHonorsCollisionRevisionAndCreateExclusivity() throws {
        try withTemporaryRootsSync { destinationRoot in
            let destination = destinationRoot.appendingPathComponent("Grant.html")
            try Data("approved".utf8).write(to: destination)
            let approved = try DocumentRevisionReader.revision(at: destination)
            try Data("changed outside".utf8).write(to: destination, options: .atomic)
            let writer = ExportFileGrantWriter()

            XCTAssertEqual(
                try writer.replace(
                    contents: Data("candidate".utf8),
                    at: destination,
                    onlyIf: approved
                ),
                .revisionMismatch(retainedURL: nil)
            )
            XCTAssertEqual(try String(contentsOf: destination), "changed outside")
            XCTAssertFalse(
                try writer.create(contents: Data("new".utf8), at: destination)
            )

            let fresh = destinationRoot.appendingPathComponent("Fresh.html")
            XCTAssertTrue(
                try writer.create(contents: Data("new".utf8), at: fresh)
            )
            XCTAssertEqual(try String(contentsOf: fresh), "new")
        }
    }
}

private struct ENOSPCExportWriter: AtomicFileWriting {
    func replace(
        contents _: Data,
        at destinationURL: URL,
        onlyIf _: DiskRevision?
    ) throws -> AtomicReplaceOutcome {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOSPC),
            userInfo: [NSFilePathErrorKey: destinationURL.path]
        )
    }

    func create(contents _: Data, at destinationURL: URL) throws -> Bool {
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOSPC),
            userInfo: [NSFilePathErrorKey: destinationURL.path]
        )
    }
}

private final class BlockingExportWriter: AtomicFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var started = false
    private var finished = false

    init(delay: TimeInterval) {
        self.delay = delay
    }

    var hasStarted: Bool {
        lock.withLock { started }
    }

    var hasFinished: Bool {
        lock.withLock { finished }
    }

    func replace(
        contents _: Data,
        at _: URL,
        onlyIf _: DiskRevision?
    ) throws -> AtomicReplaceOutcome {
        block()
        return .replaced
    }

    func create(contents data: Data, at destinationURL: URL) throws -> Bool {
        lock.withLock { started = true }
        Thread.sleep(forTimeInterval: delay)
        try data.write(to: destinationURL, options: .withoutOverwriting)
        lock.withLock { finished = true }
        return true
    }

    private func block() {
        lock.withLock { started = true }
        Thread.sleep(forTimeInterval: delay)
        lock.withLock { finished = true }
    }
}

@MainActor
private extension ExportRecoveryCheckpointStoreTests {
    func makeSnapshot(source: String) -> DocumentTextSnapshot {
        DocumentTextSnapshot(
            documentID: DocumentID(),
            generation: BufferGeneration(),
            filename: "Draft.md",
            source: source,
            sourceFingerprint: StableSourceFingerprint.make(source)
        )
    }

    func makeRequest(
        _ format: ExportFormat,
        snapshot: DocumentTextSnapshot,
        destination: URL,
        strategy: ExportRecoveryStrategy
    ) -> ExportRequest {
        ExportRequest(
            format: format,
            snapshot: snapshot,
            destinationURL: destination,
            pdfSettings: nil,
            recoveryStrategy: strategy
        )
    }

    func waitUntil(
        timeout: Duration = .seconds(3),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for checkpoint cleanup")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func withTemporaryRoots<T>(
        _ operation: (URL, URL, URL) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClioExportCheckpoint-\(UUID().uuidString)",
            isDirectory: true
        )
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        let store = root.appendingPathComponent("Store", isDirectory: true)
        let journal = root.appendingPathComponent("Journal", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        return try await operation(destination, store, journal)
    }

    func withTemporaryRootsSync(
        _ operation: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClioExportFileGrant-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root)
    }
}
