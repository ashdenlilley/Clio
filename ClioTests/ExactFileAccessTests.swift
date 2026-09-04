import XCTest
@testable import Clio

private final class AccessCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    func append(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return calls }
}

final class ExactFileAccessTests: XCTestCase {
    @MainActor
    func testDeclinedParentRetainsGrantReloadsConflictsAndDetachesDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("selected.md")
        try Data("initial".utf8).write(to: file)
        let calls = AccessCalls()
        let state = AppState(
            defaults: UserDefaults(suiteName: "ExactFileAccess.\(UUID())")!,
            recoveryStore: RecoveryStore(rootURL: root.appendingPathComponent("Recovery")),
            externalFileAccessController: .init(
                bookmarkMaker: { Data($0.path.utf8) },
                startAccess: { _ in calls.append("start"); return true },
                stopAccess: { _ in calls.append("stop") }),
            parentFolderSelection: { _ in nil }
        )
        let window = EditorWindowSession(request: .newDocument())
        window.connect(to: state)
        await state.openExternalDocumentURLNow(file, from: window)
        let session = try XCTUnwrap(window.activeTab)
        defer { session.deactivate() }
        XCTAssertTrue(session.hasRetainedExternalFileAccess)
        XCTAssertNotNil(session.restorationState().externalFileBookmark)
        XCTAssertEqual(calls.values, [])
        let tabCount = window.tabs.count
        await state.openExternalDocumentURLNow(file, from: window)
        XCTAssertEqual(window.tabs.count, tabCount)
        XCTAssertTrue(window.activeTab === session)
        XCTAssertEqual(calls.values, ["stop"], "Duplicate incoming grant is released")
        try Data("external clean".utf8).write(to: file, options: .atomic)
        try await waitUntil { session.draftText == "external clean" }
        session.editorTextDidChange("local edit")
        try Data("external conflict".utf8).write(to: file, options: .atomic)
        try await waitUntil { session.activeConflict != nil }
        XCTAssertEqual(session.draftText, "local edit")
        XCTAssertEqual(try String(contentsOf: file), "external conflict")
        try FileManager.default.removeItem(at: file)
        try await waitUntil { session.fileURL == nil }
        XCTAssertEqual(session.draftText, "local edit")
        session.deactivate()
        XCTAssertEqual(calls.values, ["stop", "stop"])
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "External change must reconcile within one second")
    }

    func testSelectedGrantDoesNotStartAgainAndReleaseIsIdempotent() throws {
        let calls = AccessCalls()
        let controller = SecurityScopedFileAccessController(
            bookmarkMaker: { _ in calls.append("bookmark"); return Data([1]) },
            startAccess: { _ in calls.append("start"); return true },
            stopAccess: { _ in calls.append("stop") }
        )
        var lease: SecurityScopedFileLease? = try controller.acquireSelectedFile(
            at: URL(fileURLWithPath: "/selected.md"))
        XCTAssertEqual(calls.values, ["bookmark"])
        lease?.release()
        lease?.release()
        lease = nil
        XCTAssertEqual(calls.values, ["bookmark", "stop"])
    }

    func testStaleRestorationStartsBeforeRefreshingAndBalancesRefreshFailure() throws {
        enum Failure: Error { case denied }
        let calls = AccessCalls()
        let controller = SecurityScopedFileAccessController(
            bookmarkMaker: { _ in calls.append("refresh"); throw Failure.denied },
            bookmarkResolver: { _ in .init(url: URL(fileURLWithPath: "/restored.md"), isStale: true) },
            startAccess: { _ in calls.append("start"); return true },
            stopAccess: { _ in calls.append("stop") }
        )
        XCTAssertThrowsError(try controller.acquireRestoredFile(from: Data([1])))
        XCTAssertEqual(calls.values, ["start", "refresh", "stop"])
    }

    func testRevokedRestorationDoesNotRefreshOrStopUnacquiredScope() {
        let calls = AccessCalls()
        let controller = SecurityScopedFileAccessController(
            bookmarkMaker: { _ in calls.append("refresh"); return Data() },
            bookmarkResolver: { _ in .init(url: URL(fileURLWithPath: "/revoked.md"), isStale: true) },
            startAccess: { _ in calls.append("start"); return false },
            stopAccess: { _ in calls.append("stop") }
        )
        XCTAssertThrowsError(try controller.acquireRestoredFile(from: Data([1])))
        XCTAssertEqual(calls.values, ["start"])
    }

    func testStaleRestorationPersistsRefreshedBookmarkAndReleasesOnCancellation() throws {
        let calls = AccessCalls()
        let controller = SecurityScopedFileAccessController(
            bookmarkMaker: { _ in calls.append("refresh"); return Data([2]) },
            bookmarkResolver: { _ in .init(url: URL(fileURLWithPath: "/restored.md"), isStale: true) },
            startAccess: { _ in calls.append("start"); return true },
            stopAccess: { _ in calls.append("stop") }
        )
        var lease: SecurityScopedFileLease? = try controller.acquireRestoredFile(from: Data([1]))
        XCTAssertEqual(lease?.bookmark, Data([2]))
        lease = nil
        XCTAssertEqual(calls.values, ["start", "refresh", "stop"])
    }

    func testWatcherReportsAtomicReplacementThenRejectsSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("selected.md")
        let target = root.appendingPathComponent("private.md")
        try Data("initial".utf8).write(to: file)
        try Data("private".utf8).write(to: target)
        let watcher = ExactFileWatcher(fileURL: file)
        defer { watcher.cancel() }
        var iterator = watcher.events().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, .changed)
        let replaced = expectation(description: "atomic replacement under one second")
        let observed = AccessCalls()
        let replacedTask = Task {
            let event = await iterator.next()
            XCTAssertEqual(event, .changed)
            observed.append("replacement")
            replaced.fulfill()
        }
        try Data("replacement".utf8).write(to: file, options: .atomic)
        await fulfillment(of: [replaced], timeout: 1)
        guard observed.values.contains("replacement") else { return }
        await replacedTask.value
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let rejected = expectation(description: "symlink rejected under one second")
        let rejectedTask = Task {
            let event = await iterator.next()
            XCTAssertEqual(event, .accessLost)
            observed.append("rejection")
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 1)
        guard observed.values.contains("rejection") else { return }
        await rejectedTask.value
        XCTAssertEqual(try String(contentsOf: target), "private")
    }
}
