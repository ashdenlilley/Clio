import Foundation
import XCTest
@testable import Clio

@MainActor
final class DataSafetyAuditTests: XCTestCase {
    func testCleanExternalEditAndRenameAdoptsBytesAtNewPath() throws {
        try withDirectories { sourceRoot, _, _ in
            let oldURL = sourceRoot.appendingPathComponent("draft.md")
            let newURL = sourceRoot.appendingPathComponent("renamed.md")
            try Data("base".utf8).write(to: oldURL)
            let workspace = try Workspace(
                rootURL: sourceRoot,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: oldURL)

            try Data("outside edit".utf8).write(to: oldURL)
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            try workspace.reconcileExternalMove(
                for: document,
                from: oldURL,
                to: newURL
            )

            XCTAssertEqual(document.fileURL, newURL)
            XCTAssertEqual(document.text, "outside edit")
            XCTAssertFalse(document.isDirty)
            XCTAssertNil(document.conflict)
        }
    }

    func testDirtyExternalEditAndRenameConflictsWithoutOverwriting() throws {
        try withDirectories { sourceRoot, _, _ in
            let oldURL = sourceRoot.appendingPathComponent("draft.md")
            let newURL = sourceRoot.appendingPathComponent("renamed.md")
            try Data("base".utf8).write(to: oldURL)
            let workspace = try Workspace(
                rootURL: sourceRoot,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: oldURL)
            document.replaceText(with: "local edit")

            try Data("outside edit".utf8).write(to: oldURL)
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            try workspace.reconcileExternalMove(
                for: document,
                from: oldURL,
                to: newURL
            )

            XCTAssertEqual(document.fileURL, newURL)
            XCTAssertEqual(document.text, "local edit")
            XCTAssertEqual(document.conflict?.external.source, "outside edit")
            XCTAssertThrowsError(try workspace.save(document))
            XCTAssertEqual(try String(contentsOf: newURL), "outside edit")
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        }
    }

    func testWatcherCancelsPendingDebounceBeforeDeletedPathCanReappear() async throws {
        try await withDirectories { sourceRoot, _, recoveryRoot in
            let fileURL = sourceRoot.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: sourceRoot,
                accessSecurityScopedResource: false
            )
            let state = isolatedAppState(
                defaults: isolatedDefaults(),
                initialWorkspace: workspace,
                recoveryStore: RecoveryStore(rootURL: recoveryRoot)
            )
            let session = EditorSession()
            state.register(session)
            try await Task.sleep(for: .milliseconds(120))

            session.editorTextDidChange("pending local")
            try FileManager.default.removeItem(at: fileURL)
            try await waitUntil { session.fileURL == nil }
            try await Task.sleep(for: .milliseconds(500))

            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            XCTAssertEqual(session.draftText, "pending local")
            XCTAssertTrue(session.document?.requiresExplicitRestore == true)
            XCTAssertFalse(session.flushForLifecycleEvent())
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

            session.saveNow()
            XCTAssertEqual(try String(contentsOf: fileURL), "pending local")
            XCTAssertFalse(session.document?.requiresExplicitRestore == true)
        }
    }

    func testCleanDeletionThenLifecycleFlushDoesNotRestoreFile() async throws {
        try await withDirectories { sourceRoot, _, recoveryRoot in
            let fileURL = sourceRoot.appendingPathComponent("draft.md")
            try Data("clean".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: sourceRoot,
                accessSecurityScopedResource: false
            )
            let state = isolatedAppState(
                defaults: isolatedDefaults(),
                initialWorkspace: workspace,
                recoveryStore: RecoveryStore(rootURL: recoveryRoot)
            )
            let session = EditorSession()
            state.register(session)
            try await Task.sleep(for: .milliseconds(120))

            try FileManager.default.removeItem(at: fileURL)
            try await waitUntil { session.fileURL == nil }

            XCTAssertFalse(session.flushForLifecycleEvent())
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            XCTAssertEqual(session.document?.previousLocator?.relativePath, "draft.md")
        }
    }

    func testTrashThenFlushCannotRecreateOldPath() throws {
        try withDirectories { sourceRoot, _, recoveryRoot in
            let fileURL = sourceRoot.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: sourceRoot,
                accessSecurityScopedResource: false
            )
            let registry = DocumentBufferRegistry(identityStore: DocumentIdentityStore(storageURL: nil))
            let document = try registry.open(fileURL, in: workspace)
            let autosaver = registry.autosaver(for: document, in: workspace)
            let mover = DocumentMover(
                recoveryStore: RecoveryStore(rootURL: recoveryRoot),
                trashOperation: { url in
                    try FileManager.default.removeItem(at: url)
                    return nil
                }
            )

            try mover.moveToTrash(document, workspace: workspace, registry: registry)

            XCTAssertThrowsError(try autosaver.flush(document))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            XCTAssertTrue(document.requiresExplicitRestore)
        }
    }

    func testExplicitRestoreKeepsBothIfOutsideFileReappeared() throws {
        try withDirectories { sourceRoot, _, _ in
            let fileURL = sourceRoot.appendingPathComponent("draft.md")
            try Data("recoverable".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: sourceRoot,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: fileURL)
            try FileManager.default.removeItem(at: fileURL)
            try workspace.reconcileExternalChange(for: document)
            try Data("new outside".utf8).write(to: fileURL)

            let restoredURL = try XCTUnwrap(
                workspace.save(document, allowingDetachedRestore: true)
            )

            XCTAssertEqual(restoredURL.lastPathComponent, "draft (2).md")
            XCTAssertEqual(try String(contentsOf: fileURL), "new outside")
            XCTAssertEqual(try String(contentsOf: restoredURL), "recoverable")
        }
    }
}

extension DataSafetyAuditTests {
    func testInvalidUTF8OutsideVersionIsRecoveredByteForByte() async throws {
        try await withDirectories { sourceRoot, _, recoveryRoot in
            let fileURL = sourceRoot.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: sourceRoot,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: fileURL)
            document.replaceText(with: "local")
            let invalidBytes = Data([0xff, 0xfe, 0x00, 0x80])
            try invalidBytes.write(to: fileURL, options: .atomic)
            XCTAssertThrowsError(try workspace.save(document))

            let resolver = ConflictResolver(
                recoveryStore: RecoveryStore(rootURL: recoveryRoot)
            )
            _ = try await resolver.resolve(
                .keepClio,
                document: document,
                workspace: workspace
            )

            XCTAssertEqual(try Data(contentsOf: fileURL), Data("local".utf8))
            let recoveries = try recoveryContents(at: recoveryRoot)
            XCTAssertEqual(recoveries, [invalidBytes])
        }
    }

    func testDoubleInterleaveRetainsCrashArtifactUntilBothOutsideVersionsRecover() async throws {
        try await withDirectories { sourceRoot, _, recoveryRoot in
            let fileURL = sourceRoot.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let gate = OneShotInterleaving()
            var writer = AtomicFileWriter()
            writer.beforeSwap = {
                guard gate.takeBefore() else { return }
                try Data("outside before".utf8).write(to: fileURL, options: .atomic)
            }
            writer.afterSwap = {
                guard gate.takeAfter() else { return }
                try Data("outside after".utf8).write(to: fileURL, options: .atomic)
            }
            let workspace = try Workspace(
                rootURL: sourceRoot,
                accessSecurityScopedResource: false,
                atomicWriter: writer
            )
            let document = try workspace.loadDocument(at: fileURL)
            document.replaceText(with: "local")

            XCTAssertThrowsError(try workspace.save(document))
            let retainedURL = try XCTUnwrap(
                document.conflict?.additionalExternalVersions?.first?.retainedURLs.first
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
            XCTAssertEqual(try Data(contentsOf: retainedURL), Data("outside before".utf8))

            let resolver = ConflictResolver(
                recoveryStore: RecoveryStore(rootURL: recoveryRoot)
            )
            _ = try await resolver.resolve(
                .keepClio,
                document: document,
                workspace: workspace
            )

            XCTAssertFalse(FileManager.default.fileExists(atPath: retainedURL.path))
            XCTAssertEqual(
                Set(try recoveryContents(at: recoveryRoot)),
                Set([Data("outside before".utf8), Data("outside after".utf8)])
            )
        }
    }

    func testPostSwapFailureLeavesDisplacedOutsideBytesOnDisk() throws {
        try withDirectories { sourceRoot, _, _ in
            let fileURL = sourceRoot.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let expected = try DocumentRevisionReader.revision(at: fileURL)
            var writer = AtomicFileWriter()
            writer.beforeSwap = {
                try Data("outside".utf8).write(to: fileURL, options: .atomic)
            }
            writer.afterSwap = {
                try FileManager.default.removeItem(at: fileURL)
            }

            XCTAssertThrowsError(
                try writer.replace(
                    contents: Data("local".utf8),
                    at: fileURL,
                    onlyIf: expected
                )
            )

            let artifacts = try FileManager.default.contentsOfDirectory(
                at: sourceRoot,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix(".clio-save-") }
            XCTAssertEqual(artifacts.count, 1)
            XCTAssertEqual(try Data(contentsOf: artifacts[0]), Data("outside".utf8))
        }
    }

    func testConflictAccumulatesThreeOutsideVersionsAndRecoversBeforeDeletionDetach() async throws {
        try await withDirectories { sourceRoot, _, recoveryRoot in
            let fileURL = sourceRoot.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: sourceRoot,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: fileURL)
            document.replaceText(with: "local")

            for value in ["v1", "v2", "v3", "v3"] {
                try Data(value.utf8).write(to: fileURL, options: .atomic)
                try workspace.reconcileExternalChange(for: document)
            }

            XCTAssertEqual(document.conflict?.external.source, "v3")
            XCTAssertEqual(document.conflict?.additionalExternalVersions?.count, 2)
            try FileManager.default.removeItem(at: fileURL)
            let registry = DocumentBufferRegistry(identityStore: DocumentIdentityStore(storageURL: nil))
            registry.register(document, in: workspace)
            let resolver = ConflictResolver(
                recoveryStore: RecoveryStore(rootURL: recoveryRoot)
            )
            try await resolver.detachAfterExternalDeletion(
                document,
                workspace: workspace,
                registry: registry
            )

            XCTAssertNil(document.conflict)
            XCTAssertNil(document.fileURL)
            XCTAssertEqual(document.previousLocator?.relativePath, "draft.md")
            XCTAssertEqual(
                Set(try recoveryContents(at: recoveryRoot)),
                Set([Data("v1".utf8), Data("v2".utf8), Data("v3".utf8)])
            )
        }
    }

    func testRecoveryUsesCreationClockAndPrunesDuringCreate() async throws {
        try await withDirectories { _, _, recoveryRoot in
            let finalNow = Date(timeIntervalSince1970: 2_100_000_000)
            let clock = MutableClock(
                finalNow.addingTimeInterval(-RecoveryStore.retention - 10)
            )
            let store = RecoveryStore(rootURL: recoveryRoot, now: { clock.value })
            let old = try await store.preserve(
                documentID: DocumentID(),
                filename: "old.md",
                data: Data("old".utf8),
                sourceModificationDate: Date(timeIntervalSince1970: 100)
            )
            clock.value = finalNow
            let recent = try await store.preserve(
                documentID: DocumentID(),
                filename: "recent.md",
                data: Data("recent".utf8),
                sourceModificationDate: Date(timeIntervalSince1970: 200)
            )

            XCTAssertFalse(FileManager.default.fileExists(atPath: old.recoveryURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: recent.recoveryURL.path))
            XCTAssertEqual(recent.createdAt, finalNow)
            XCTAssertEqual(recent.sourceModificationDate, Date(timeIntervalSince1970: 200))
            let values = try recent.recoveryURL.resourceValues(forKeys: [.contentModificationDateKey])
            XCTAssertEqual(
                try XCTUnwrap(values.contentModificationDate).timeIntervalSince1970,
                finalNow.timeIntervalSince1970,
                accuracy: 1
            )
        }
    }
}

private extension DataSafetyAuditTests {
    struct Timeout: Error {}

    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ClioAuditTests.\(UUID().uuidString)")!
    }

    func withDirectories<T>(
        _ operation: (URL, URL, URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioAudit-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try operation(source, destination, recovery)
    }

    func withDirectories<T>(
        _ operation: (URL, URL, URL) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioAudit-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await operation(source, destination, recovery)
    }

    func recoveryContents(at rootURL: URL) throws -> [Data] {
        try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ).map { try Data(contentsOf: $0) }
    }

    func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitUntilAsync(
        timeout: Duration = .seconds(3),
        condition: () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class MutableClock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

private final class OneShotInterleaving: @unchecked Sendable {
    private var before = true
    private var after = true

    func takeBefore() -> Bool {
        defer { before = false }
        return before
    }

    func takeAfter() -> Bool {
        defer { after = false }
        return after
    }
}

private actor SuspendedRecoveryStore: RecoveryPersisting {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func preserve(
        documentID: DocumentID,
        filename _: String,
        data _: Data,
        sourceModificationDate: Date?
    ) async throws -> RecoveryReceipt {
        await withCheckedContinuation { continuation = $0 }
        return RecoveryReceipt(
            documentID: documentID,
            recoveryURL: URL(fileURLWithPath: "/tmp/suspended-recovery"),
            createdAt: Date(),
            sourceModificationDate: sourceModificationDate
        )
    }

    func prune(olderThan _: Date) async throws {}

    func resume() {
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }
}

private actor FailingRecoveryStore: RecoveryPersisting {
    struct Failure: Error {}

    func preserve(
        documentID _: DocumentID,
        filename _: String,
        data _: Data,
        sourceModificationDate _: Date?
    ) async throws -> RecoveryReceipt {
        throw Failure()
    }

    func prune(olderThan _: Date) async throws {}
}

extension DataSafetyAuditTests {
    func testLoadExternalRevalidatesAfterSuspendedRecovery() async throws {
        try await withDirectories { sourceRoot, _, _ in
            let fileURL = sourceRoot.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: sourceRoot,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: fileURL)
            document.replaceText(with: "local")
            try Data("v1".utf8).write(to: fileURL, options: .atomic)
            XCTAssertThrowsError(try workspace.save(document))
            let suspended = SuspendedRecoveryStore()
            let resolver = ConflictResolver(recoveryStore: suspended)

            let resolution = Task { @MainActor in
                try await resolver.resolve(
                    .loadExternal,
                    document: document,
                    workspace: workspace
                )
            }
            try await waitUntilAsync { await suspended.isWaiting }
            try Data("v2".utf8).write(to: fileURL, options: .atomic)
            await suspended.resume()

            do {
                _ = try await resolution.value
                XCTFail("Expected the post-recovery disk validation to fail")
            } catch ConflictResolver.ResolutionError.conflictChanged {
                XCTAssertEqual(document.text, "local")
                XCTAssertEqual(document.conflict?.external.source, "v2")
                XCTAssertEqual(try String(contentsOf: fileURL), "v2")
            }
        }
    }

    func testConflictDeletionDoesNotDetachWhenRecoveryFails() async throws {
        try await withDirectories { sourceRoot, _, _ in
            let fileURL = sourceRoot.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: fileURL)
            let workspace = try Workspace(
                rootURL: sourceRoot,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: fileURL)
            document.replaceText(with: "local")
            try Data("outside".utf8).write(to: fileURL, options: .atomic)
            XCTAssertThrowsError(try workspace.save(document))
            try FileManager.default.removeItem(at: fileURL)
            let resolver = ConflictResolver(recoveryStore: FailingRecoveryStore())

            do {
                try await resolver.detachAfterExternalDeletion(
                    document,
                    workspace: workspace,
                    registry: nil
                )
                XCTFail("Expected recovery failure")
            } catch {
                XCTAssertNotNil(document.conflict)
                XCTAssertEqual(document.fileURL, fileURL)
                XCTAssertEqual(document.text, "local")
            }
        }
    }

    func testCrossWorkspaceMoveRetargetsOneControllerAndEverySession() async throws {
        try await withDirectories { sourceRoot, destinationRoot, recoveryRoot in
            let sourceURL = sourceRoot.appendingPathComponent("draft.md")
            let destinationURL = destinationRoot.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: sourceURL)
            let source = try Workspace(
                rootURL: sourceRoot,
                accessSecurityScopedResource: false
            )
            let destination = try Workspace(
                rootURL: destinationRoot,
                accessSecurityScopedResource: false
            )
            let registry = DocumentBufferRegistry(identityStore: DocumentIdentityStore(storageURL: nil))
            let recovery = RecoveryStore(rootURL: recoveryRoot)
            let resolver = ConflictResolver(recoveryStore: recovery)
            let mover = DocumentMover(recoveryStore: recovery)
            let first = EditorSession()
            let second = EditorSession()
            for session in [first, second] {
                session.activate(
                    in: source,
                    documentURLs: [sourceURL],
                    registry: registry,
                    conflictResolver: resolver,
                    documentMover: mover
                )
            }
            let document = try XCTUnwrap(first.document)

            _ = try await mover.move(
                document,
                from: source,
                to: destination,
                registry: registry
            )
            first.editorTextDidChange("after move")
            second.saveNow()

            XCTAssertTrue(first.document === second.document)
            XCTAssertEqual(first.fileURL, destinationURL)
            XCTAssertEqual(second.fileURL, destinationURL)
            XCTAssertNil(second.errorMessage)
            XCTAssertEqual(try String(contentsOf: destinationURL), "after move")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        }
    }

    func testEditDuringCrossWorkspaceMoveResumesOnDestinationController() async throws {
        try await withDirectories { sourceRoot, destinationRoot, _ in
            let sourceURL = sourceRoot.appendingPathComponent("draft.md")
            let destinationURL = destinationRoot.appendingPathComponent("draft.md")
            try Data("base".utf8).write(to: sourceURL)
            try Data("occupied".utf8).write(to: destinationURL)
            let source = try Workspace(rootURL: sourceRoot, accessSecurityScopedResource: false)
            let destination = try Workspace(rootURL: destinationRoot, accessSecurityScopedResource: false)
            let registry = DocumentBufferRegistry(identityStore: DocumentIdentityStore(storageURL: nil))
            let suspended = SuspendedRecoveryStore()
            let mover = DocumentMover(recoveryStore: suspended)
            let resolver = ConflictResolver(recoveryStore: suspended)
            let first = EditorSession()
            let second = EditorSession()
            for session in [first, second] {
                session.activate(
                    in: source,
                    documentURLs: [sourceURL],
                    registry: registry,
                    conflictResolver: resolver,
                    documentMover: mover
                )
            }
            let document = try XCTUnwrap(first.document)
            let proposal = try await mover.move(
                document,
                from: source,
                to: destination,
                registry: registry
            )
            guard case .collision(let approvedCollision) = proposal else {
                return XCTFail("Expected collision approval")
            }
            let moving = Task { @MainActor in
                try await mover.move(
                    document,
                    from: source,
                    to: destination,
                    collisionChoice: .replace,
                    approvedCollision: approvedCollision,
                    registry: registry
                )
            }
            try await waitUntilAsync { await suspended.isWaiting }

            second.editorTextDidChange("edited during move")
            await suspended.resume()
            _ = try await moving.value

            XCTAssertEqual(first.draftText, "edited during move")
            XCTAssertEqual(second.fileURL, destinationURL)
            XCTAssertEqual(try String(contentsOf: destinationURL), "edited during move")
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        }
    }
}
