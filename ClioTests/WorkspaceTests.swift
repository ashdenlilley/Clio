import XCTest
@testable import Clio

@MainActor
final class WorkspaceTests: XCTestCase {
    func testPreferredDefaultURLIsDocumentsClioWithoutCreatingIt() {
        let physicalHomeURL = FileManager.default.homeDirectory(forUser: NSUserName())
            ?? FileManager.default.homeDirectoryForCurrentUser
        let expectedURL = physicalHomeURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Clio", isDirectory: true)
        let existedBefore = FileManager.default.fileExists(atPath: expectedURL.path)

        XCTAssertEqual(Workspace.preferredDefaultURL, expectedURL)
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: expectedURL.path),
            existedBefore
        )
    }

    func testBlankDocumentStaysInMemoryUntilItHasContent() throws {
        try withTemporaryDirectory { directoryURL in
            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let document = Document()
            let autosaver = Autosaver(workspace: workspace)

            autosaver.documentDidChange(document)
            XCTAssertNil(try autosaver.flush())
            XCTAssertEqual(document.filename, "untitled.md")
            XCTAssertNil(document.fileURL)
            XCTAssertTrue(try contentsOfDirectory(directoryURL).isEmpty)
        }
    }

    func testFirstNonEmptyEditMaterializesUntitledAtomicallyAsUTF8() throws {
        try withTemporaryDirectory { directoryURL in
            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let document = Document()
            let autosaver = Autosaver(workspace: workspace)

            document.replaceText(with: "Hello, Clio — こんにちは")
            autosaver.documentDidChange(document)

            let expectedURL = directoryURL.appendingPathComponent("untitled.md")
            XCTAssertEqual(document.fileURL, expectedURL)
            XCTAssertFalse(document.isDirty)
            XCTAssertEqual(
                try String(contentsOf: expectedURL, encoding: .utf8),
                "Hello, Clio — こんにちは"
            )
        }
    }

    func testUntitledCollisionUsesNumberedFilenameWithoutOverwriting() throws {
        try withTemporaryDirectory { directoryURL in
            let originalURL = directoryURL.appendingPathComponent("untitled.md")
            try Data("existing".utf8).write(to: originalURL)

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let document = Document()
            let autosaver = Autosaver(workspace: workspace)

            document.replaceText(with: "new draft")
            autosaver.documentDidChange(document)

            XCTAssertEqual(
                try String(contentsOf: originalURL, encoding: .utf8),
                "existing"
            )
            XCTAssertEqual(document.filename, "untitled (2).md")
            XCTAssertEqual(
                try String(contentsOf: document.fileURL!, encoding: .utf8),
                "new draft"
            )
            XCTAssertFalse(
                try contentsOfDirectory(directoryURL).contains {
                    $0.lastPathComponent.hasPrefix(".clio-save-")
                }
            )
        }
    }

    func testUnsafeSuggestedFilenameCannotEscapeWorkspace() throws {
        try withTemporaryDirectory { directoryURL in
            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let document = Document(preferredFilename: "../../outside")
            let autosaver = Autosaver(workspace: workspace)

            document.replaceText(with: "contained")
            autosaver.documentDidChange(document)

            let fileURL = try XCTUnwrap(document.fileURL)
            XCTAssertEqual(fileURL.deletingLastPathComponent(), directoryURL)
            XCTAssertEqual(fileURL.lastPathComponent, "outside.md")
        }
    }

    func testExistingDocumentSaveIsDebounced() async throws {
        try await withTemporaryDirectory { directoryURL in
            let fileURL = directoryURL.appendingPathComponent("draft.md")
            try Data("old".utf8).write(to: fileURL)

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: fileURL)
            let autosaver = Autosaver(
                workspace: workspace,
                delay: .milliseconds(80)
            )

            document.replaceText(with: "new")
            autosaver.documentDidChange(document)

            XCTAssertEqual(try String(contentsOf: fileURL), "old")
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(try String(contentsOf: fileURL), "old")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(try String(contentsOf: fileURL), "new")
            XCTAssertFalse(document.isDirty)
            XCTAssertFalse(autosaver.hasPendingSave)
        }
    }

    func testFlushWritesExistingDocumentWithoutWaitingForDebounce() throws {
        try withTemporaryDirectory { directoryURL in
            let fileURL = directoryURL.appendingPathComponent("draft.md")
            try Data("old".utf8).write(to: fileURL)

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: fileURL)
            let autosaver = Autosaver(workspace: workspace)

            document.replaceText(with: "flushed")
            autosaver.documentDidChange(document)
            XCTAssertEqual(try autosaver.flush(), fileURL)

            XCTAssertEqual(try String(contentsOf: fileURL), "flushed")
            XCTAssertFalse(autosaver.hasPendingSave)
        }
    }

    func testNestedFileOperationSuspensionsOnlyResumeAfterFinalOwner() throws {
        try withTemporaryDirectory { directoryURL in
            let fileURL = directoryURL.appendingPathComponent("draft.md")
            try Data("old".utf8).write(to: fileURL)

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let document = try workspace.loadDocument(at: fileURL)
            let autosaver = Autosaver(workspace: workspace)

            autosaver.suspendForFileOperation()
            autosaver.suspendForFileOperation()
            document.replaceText(with: "nested-safe")
            autosaver.documentDidChange(document)
            autosaver.resumeAfterFileOperation()

            XCTAssertThrowsError(try autosaver.flush(document)) { error in
                guard case Autosaver.SaveError.fileOperationInProgress = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(try String(contentsOf: fileURL), "old")

            autosaver.resumeAfterFileOperation()
            XCTAssertEqual(try autosaver.flush(document), fileURL)
            XCTAssertEqual(try String(contentsOf: fileURL), "nested-safe")
        }
    }

    func testInvalidUTF8IsRejected() throws {
        try withTemporaryDirectory { directoryURL in
            let fileURL = directoryURL.appendingPathComponent("invalid.md")
            try Data([0xC3, 0x28]).write(to: fileURL)

            XCTAssertThrowsError(try Document(contentsOf: fileURL)) { error in
                XCTAssertEqual(error as? Document.ReadError, .invalidUTF8(fileURL))
            }
        }
    }

    func testDocumentEnumerationUsesSupportedExtensionsAndSkipsExcludedTrees() throws {
        try withTemporaryDirectory { directoryURL in
            let nestedURL = directoryURL.appendingPathComponent("notes")
            let modulesURL = directoryURL.appendingPathComponent("node_modules")
            try FileManager.default.createDirectory(
                at: nestedURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: modulesURL,
                withIntermediateDirectories: true
            )
            try Data().write(to: directoryURL.appendingPathComponent("one.md"))
            try Data().write(to: nestedURL.appendingPathComponent("two.markdown"))
            try Data().write(to: nestedURL.appendingPathComponent("ignore.rtf"))
            try Data().write(to: modulesURL.appendingPathComponent("dependency.md"))

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )

            XCTAssertEqual(
                Set(try workspace.documentURLs().map(workspace.relativePath(for:))),
                Set(["notes/two.markdown", "one.md"])
            )
        }
    }

    func testDocumentEnumerationOrdersNewestFirstWithPathTieBreaker() throws {
        try withTemporaryDirectory { directoryURL in
            let newestURL = directoryURL.appendingPathComponent("newest.md")
            let tieBURL = directoryURL.appendingPathComponent("tie-b.md")
            let tieAURL = directoryURL.appendingPathComponent("tie-a.md")
            let oldestURL = directoryURL.appendingPathComponent("oldest.md")

            for fileURL in [oldestURL, tieBURL, newestURL, tieAURL] {
                try Data().write(to: fileURL)
            }

            let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
            try setModificationDate(referenceDate.addingTimeInterval(100), for: newestURL)
            try setModificationDate(referenceDate, for: tieBURL)
            try setModificationDate(referenceDate, for: tieAURL)
            try setModificationDate(referenceDate.addingTimeInterval(-100), for: oldestURL)

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )

            XCTAssertEqual(
                try workspace.documentURLs().map(workspace.relativePath(for:)),
                ["newest.md", "tie-a.md", "tie-b.md", "oldest.md"]
            )
        }
    }

    func testDefaultAutosaveDelayIsFourHundredMilliseconds() {
        XCTAssertEqual(Autosaver.defaultDelay, .milliseconds(400))
    }

    func testMostRecentEditorSessionOpensFirstCandidate() throws {
        try withTemporaryDirectory { directoryURL in
            let newestURL = directoryURL.appendingPathComponent("newest.md")
            let olderURL = directoryURL.appendingPathComponent("older.md")
            try Data("newest".utf8).write(to: newestURL)
            try Data("older".utf8).write(to: olderURL)

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let session = EditorSession(openingMode: .mostRecent)

            session.activate(
                in: workspace,
                documentURLs: [newestURL, olderURL]
            )

            XCTAssertEqual(session.fileURL, newestURL)
            XCTAssertEqual(session.draftText, "newest")
        }
    }

    func testNewDocumentWindowStartsWithLazyUnbackedCanvas() throws {
        try withTemporaryDirectory { directoryURL in
            let existingURL = directoryURL.appendingPathComponent("existing.md")
            try Data("existing".utf8).write(to: existingURL)

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let session = EditorSession(openingMode: .newDocument)

            session.activate(in: workspace, documentURLs: [existingURL])

            XCTAssertTrue(session.isReady)
            XCTAssertNil(session.fileURL)
            XCTAssertEqual(session.draftText, "")

            session.editorTextDidChange("first line")

            XCTAssertEqual(session.fileURL?.lastPathComponent, "untitled.md")
            XCTAssertEqual(
                try String(contentsOf: directoryURL.appendingPathComponent("untitled.md")),
                "first line"
            )
        }
    }

    func testEmptyMostRecentRequestResolvesToPersistentBlankIntent() throws {
        try withTemporaryDirectory { directoryURL in
            let laterURL = directoryURL.appendingPathComponent("later.md")
            try Data("later".utf8).write(to: laterURL)

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let session = EditorSession(openingMode: .mostRecent)

            session.activate(in: workspace, documentURLs: [])
            session.resolveAsNewDocument()
            session.activate(in: workspace, documentURLs: [laterURL])

            XCTAssertEqual(session.openingMode, .newDocument)
            XCTAssertNil(session.fileURL)
            XCTAssertEqual(session.draftText, "")
        }
    }

    func testRestoredWindowReopensItsExactRelativePath() async throws {
        try await withTemporaryDirectory { directoryURL in
            let recentURL = directoryURL.appendingPathComponent("recent.md")
            let restoredURL = directoryURL.appendingPathComponent("restored.md")
            try Data("recent".utf8).write(to: recentURL)
            try Data("restored".utf8).write(to: restoredURL)

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let session = EditorSession(
                openingMode: .newDocument,
                restoredLocator: try DocumentLocator(workspaceID: workspace.id, relativePath: "restored.md")
            )
            let state = AppState(
                defaults: UserDefaults(
                    suiteName: "ClioTests.\(UUID().uuidString)"
                )!,
                initialWorkspace: workspace
            )
            state.register(session)
            try await waitForActivation(session)

            XCTAssertEqual(session.fileURL, restoredURL)
            XCTAssertEqual(session.draftText, "restored")
        }
    }

    func testAdditionalWorkspaceWindowChoosesNextMostRecentUnopenedFile() async throws {
        try await withTemporaryDirectory { directoryURL in
            let newestURL = directoryURL.appendingPathComponent("newest.md")
            let nextURL = directoryURL.appendingPathComponent("next.md")
            try Data("newest".utf8).write(to: newestURL)
            try Data("next".utf8).write(to: nextURL)

            let now = Date()
            try setModificationDate(now, for: newestURL)
            try setModificationDate(now.addingTimeInterval(-60), for: nextURL)

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let defaults = UserDefaults(
                suiteName: "ClioTests.\(UUID().uuidString)"
            )!
            let state = AppState(
                defaults: defaults,
                initialWorkspace: workspace
            )
            let firstSession = EditorSession(openingMode: .mostRecent)
            let secondSession = EditorSession(openingMode: .mostRecent)

            state.register(firstSession)
            state.register(secondSession)
            try await waitForActivation(firstSession)
            try await waitForActivation(secondSession)

            XCTAssertEqual(firstSession.fileURL, newestURL)
            XCTAssertEqual(secondSession.fileURL, nextURL)
        }
    }

    func testUnregisterFlushesAWindowBeforeReleasingItsSession() async throws {
        try await withTemporaryDirectory { directoryURL in
            let fileURL = directoryURL.appendingPathComponent("draft.md")
            try Data("before".utf8).write(to: fileURL)

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let state = AppState(
                defaults: UserDefaults(
                    suiteName: "ClioTests.\(UUID().uuidString)"
                )!,
                initialWorkspace: workspace
            )
            let session = EditorSession(openingMode: .mostRecent)
            state.register(session)
            try await waitForActivation(session)
            session.editorTextDidChange("after")

            state.unregister(session)

            XCTAssertEqual(try String(contentsOf: fileURL), "after")
            XCTAssertFalse(session.isReady)
        }
    }

    func testFailedUnregisterFlushRetainsTheWindowSessionUntilRecovery() async throws {
        try await withTemporaryDirectory { directoryURL in
            let fileURL = directoryURL.appendingPathComponent("draft.md")
            try Data("before".utf8).write(to: fileURL)

            let workspace = try Workspace(
                rootURL: directoryURL,
                accessSecurityScopedResource: false
            )
            let state = AppState(
                defaults: UserDefaults(
                    suiteName: "ClioTests.\(UUID().uuidString)"
                )!,
                initialWorkspace: workspace
            )
            let session = EditorSession(openingMode: .mostRecent)
            state.register(session)
            try await waitForActivation(session)
            session.editorTextDidChange("after")

            try FileManager.default.removeItem(at: fileURL)
            try FileManager.default.createDirectory(
                at: fileURL,
                withIntermediateDirectories: false
            )

            state.unregister(session)

            XCTAssertTrue(session.isReady)
            XCTAssertEqual(session.draftText, "after")
            XCTAssertNotNil(session.errorMessage)

            try FileManager.default.removeItem(at: fileURL)
            try Data("external".utf8).write(to: fileURL)
            state.unregister(session)

            XCTAssertTrue(session.isReady)
            XCTAssertEqual(session.draftText, "after")
            XCTAssertNotNil(session.activeConflict)
            XCTAssertEqual(try String(contentsOf: fileURL), "external")
        }
    }
}

private extension WorkspaceTests {
    func waitForActivation(_ session: EditorSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !session.isReady && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(session.isReady)
    }

    func withTemporaryDirectory<T>(
        _ operation: (URL) throws -> T
    ) throws -> T {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        return try operation(directoryURL)
    }

    func withTemporaryDirectory<T>(
        _ operation: (URL) async throws -> T
    ) async throws -> T {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioWorkspaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        return try await operation(directoryURL)
    }

    func contentsOfDirectory(_ directoryURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
    }

    func setModificationDate(_ date: Date, for fileURL: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: fileURL.path
        )
    }
}
