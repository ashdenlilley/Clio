import XCTest
import SwiftUI
@testable import Clio

@MainActor
final class NavigationSessionTests: XCTestCase {
    func testNewDocumentAddsAnInAppTabAndKeepsOneTabWhenClosed() {
        let window = EditorWindowSession(request: .newDocument())
        let originalID = window.activeTabID

        let second = window.newDocument()

        XCTAssertEqual(window.tabs.count, 2)
        XCTAssertEqual(window.activeTabID, second.id)
        XCTAssertNotEqual(originalID, second.id)

        window.close(tabID: second.id)
        XCTAssertEqual(window.tabs.count, 1)
        XCTAssertEqual(window.activeTabID, originalID)

        window.close(tabID: try! XCTUnwrap(originalID))
        XCTAssertEqual(window.tabs.count, 1)
        XCTAssertNotNil(window.activeTabID)
    }

    func testWindowRestorationRetainsTabsActiveViewportAndSidebarState() throws {
        let workspaceID = WorkspaceID()
        let firstID = UUID()
        let secondID = UUID()
        let firstViewport = EditorViewportState(
            selection: UTF16Range(location: 11, length: 3),
            topVisibleUTF16Offset: 7,
            fractionalYOffset: 0.4
        )
        let state = EditorWindowRestorationState(
            id: UUID(),
            tabs: [
                EditorTabRestorationState(
                    id: firstID,
                    documentID: DocumentID(),
                    locator: try DocumentLocator(
                        workspaceID: workspaceID,
                        relativePath: "drafts/one.md"
                    ),
                    preferredFilename: "one.md",
                    viewport: firstViewport
                ),
                EditorTabRestorationState(
                    id: secondID,
                    documentID: DocumentID(),
                    locator: nil,
                    preferredFilename: "untitled.md",
                    viewport: .zero
                ),
            ],
            activeTabID: secondID,
            isSidebarVisible: false,
            isSidebarPinned: true,
            isFullScreen: true
        )
        var request = EditorWindowRequest.mostRecent()
        request.restoration = state

        let restored = EditorWindowSession(request: request)
        let emitted = restored.restorationState

        XCTAssertEqual(restored.tabs.map(\.id), [firstID, secondID])
        XCTAssertEqual(emitted.tabs[0].locator, state.tabs[0].locator)
        XCTAssertEqual(emitted.tabs[0].documentID, state.tabs[0].documentID)
        XCTAssertEqual(emitted.tabs[0].preferredFilename, "one.md")
        XCTAssertEqual(emitted.tabs[0].viewport, firstViewport)
        XCTAssertEqual(emitted.activeTabID, secondID)
        XCTAssertFalse(emitted.isSidebarVisible)
        XCTAssertTrue(emitted.isSidebarPinned)
        XCTAssertTrue(emitted.isFullScreen)

        let roundTrip = try JSONDecoder().decode(
            EditorWindowRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(roundTrip.restoration, state)
    }

    func testInlineSlashAtLineStartOpensPaletteWithoutChangingDraft() {
        let window = EditorWindowSession(request: .newDocument())
        window.activeTab?.draftText = "First line\n"

        window.noteEditorChange(
            from: "First line\n",
            to: "First line\n/"
        )

        XCTAssertTrue(window.isPalettePresented)
        XCTAssertEqual(window.paletteSource, .inlineSlash)
        XCTAssertEqual(window.paletteQuery, "/")
        XCTAssertEqual(window.activeTab?.draftText, "First line\n")
    }

    func testSlashInsideProseRemainsPlainText() {
        let window = EditorWindowSession(request: .newDocument())
        window.activeTab?.draftText = "path"

        window.noteEditorChange(from: "path", to: "path/")

        XCTAssertFalse(window.isPalettePresented)
    }

    func testCommandPaletteExposesEveryContractCommand() {
        XCTAssertEqual(
            Set(ClioCommandDescriptor.all.map(\.command)),
            Set(ClioCommandID.allCases)
        )
        XCTAssertEqual(
            ClioCommandDescriptor.all.map { $0.command.slashName },
            [
                "/new", "/open", "/search", "/rename", "/delete",
                "/reveal", "/folder", "/export", "/focus",
                "/typewriter", "/sidebar", "/settings",
            ]
        )
    }

    func testHorizontalGestureRevealsAndReverseGestureHidesUnpinnedSidebar() {
        let window = EditorWindowSession(request: .newDocument())
        window.hideSidebar()
        XCTAssertFalse(window.isSidebarVisible)

        window.handleHorizontalGesture(deltaX: 50, phaseEnded: false)
        XCTAssertTrue(window.isSidebarVisible)

        window.handleHorizontalGesture(deltaX: -50, phaseEnded: true)
        XCTAssertFalse(window.isSidebarVisible)

        window.revealSidebarTemporarily()
        window.setSidebarPinned(true)
        window.handleHorizontalGesture(deltaX: -60, phaseEnded: true)
        XCTAssertFalse(window.isSidebarVisible)
        window.revealSidebarTemporarily()
        XCTAssertTrue(window.isSidebarVisible)
        XCTAssertEqual(EditorWindowSession.writingCollapseDelay, .seconds(5))
    }

    func testColdLaunchAndAdditionalWindowChooseNewestDistinctDocumentsGlobally() throws {
        try withTemporaryDirectory { firstFolder in
            try withTemporaryDirectory { secondFolder in
                let older = firstFolder.appendingPathComponent("older.md")
                let newest = secondFolder.appendingPathComponent("newest.md")
                try Data("older".utf8).write(to: older)
                try Data("newest".utf8).write(to: newest)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSinceNow: -60)],
                    ofItemAtPath: older.path
                )
                try FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: newest.path
                )

                let defaults = makeDefaults()
                let catalog = makeCatalog(defaults: defaults)
                _ = try catalog.addAuthorizedFolder(firstFolder)
                _ = try catalog.addAuthorizedFolder(secondFolder)
                let appState = AppState(
                    defaults: defaults,
                    workspaceCatalog: catalog,
                    searchIndex: nil
                )
                let firstWindow = EditorWindowSession(request: .mostRecent())
                let secondWindow = EditorWindowSession(request: .mostRecent())

                firstWindow.connect(to: appState)
                secondWindow.connect(to: appState)

                XCTAssertEqual(firstWindow.activeTab?.fileURL, newest)
                XCTAssertEqual(secondWindow.activeTab?.fileURL, older)
            }
        }
    }

    func testOpeningAlreadyOpenWorkspaceFileFocusesExistingTab() throws {
        try withTemporaryDirectory { folder in
            let fileURL = folder.appendingPathComponent("shared.md")
            try Data("shared".utf8).write(to: fileURL)
            let defaults = makeDefaults()
            let catalog = makeCatalog(defaults: defaults)
            let descriptor = try catalog.addAuthorizedFolder(folder)
            let appState = AppState(
                defaults: defaults,
                workspaceCatalog: catalog,
                searchIndex: nil
            )
            let window = EditorWindowSession(request: .mostRecent())
            window.connect(to: appState)
            let originalTabID = window.activeTabID

            appState.openWorkspaceFile(
                workspaceID: descriptor.id,
                relativePath: "shared.md",
                from: window
            )

            XCTAssertEqual(window.tabs.count, 1)
            XCTAssertEqual(window.activeTabID, originalTabID)
        }
    }

    func testPowerboxFileCanSaveDirectlyWhileParentIndexGrantIsPending() throws {
        try withTemporaryDirectory { folder in
            let fileURL = folder.appendingPathComponent("outside.md")
            try Data("before".utf8).write(to: fileURL)
            let session = EditorSession(openingMode: .newDocument)

            try session.activateExternal(documentURL: fileURL)
            session.editorTextDidChange("after")
            try session.flush()

            XCTAssertEqual(try String(contentsOf: fileURL), "after")
            XCTAssertNil(session.locator)
            XCTAssertTrue(session.isReady)
        }
    }

    func testSearchDefaultsGlobalAndPassesOptionalFolderFilter() async throws {
        let index = RecordingSearchIndex()
        let defaults = makeDefaults()
        let appState = AppState(
            defaults: defaults,
            workspaceCatalog: makeCatalog(defaults: defaults),
            searchIndex: index
        )
        let filter = WorkspaceID()

        for try await _ in await appState.search("needle", workspaceFilter: nil) {}
        for try await _ in await appState.search("scoped", workspaceFilter: filter) {}

        let queries = await index.recordedQueries()
        XCTAssertEqual(queries.map(\.text), ["needle", "scoped"])
        XCTAssertNil(queries[0].workspaceFilter)
        XCTAssertEqual(queries[1].workspaceFilter, filter)
    }

    func testSidebarMoveChangesPhysicalLocationAndRetargetsOpenTab() throws {
        try withTemporaryDirectory { sourceFolder in
            try withTemporaryDirectory { destinationFolder in
                let sourceURL = sourceFolder.appendingPathComponent("move-me.md")
                try Data("move".utf8).write(to: sourceURL)
                let defaults = makeDefaults()
                let catalog = makeCatalog(defaults: defaults)
                let sourceWorkspace = try catalog.addAuthorizedFolder(sourceFolder)
                let destinationWorkspace = try catalog.addAuthorizedFolder(destinationFolder)
                let appState = AppState(
                    defaults: defaults,
                    workspaceCatalog: catalog,
                    searchIndex: nil
                )
                let window = EditorWindowSession(request: .mostRecent())
                window.connect(to: appState)
                let originalDocumentID = window.activeTab?.documentID
                let payload = try XCTUnwrap(
                    appState.dragPayload(
                        workspaceID: sourceWorkspace.id,
                        relativePath: "move-me.md"
                    )
                )

                XCTAssertTrue(
                    appState.moveDocument(
                        dragPayload: payload,
                        toWorkspaceID: destinationWorkspace.id,
                        parentRelativePath: "drafts"
                    )
                )

                let destinationURL = destinationFolder
                    .appendingPathComponent("drafts/move-me.md")
                XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
                XCTAssertEqual(window.activeTab?.fileURL, destinationURL)
                XCTAssertEqual(window.activeTab?.documentID, originalDocumentID)
            }
        }
    }

    func testCommandDispatcherTargetsTheCurrentWindowAndWritingModes() async throws {
        try await withTemporaryDirectory { folder in
            let defaults = makeDefaults()
            let workspace = try Workspace(
                rootURL: folder,
                accessSecurityScopedResource: false
            )
            let appState = AppState(
                defaults: defaults,
                initialWorkspace: workspace,
                searchIndex: nil
            )
            let window = EditorWindowSession(request: .newDocument())
            window.connect(to: appState)
            let context = ClioCommandContext(
                windowID: window.id,
                tabID: window.activeTabID,
                source: .keyboardShortcut
            )
            let originalFocus = appState.isFocusModeEnabled
            let originalTypewriter = appState.isTypewriterModeEnabled
            let originalSidebar = window.isSidebarVisible

            await appState.perform(
                ClioCommandInvocation(command: .new, arguments: []),
                context: context
            )
            await appState.perform(
                ClioCommandInvocation(command: .focus, arguments: []),
                context: context
            )
            await appState.perform(
                ClioCommandInvocation(command: .typewriter, arguments: []),
                context: context
            )
            await appState.perform(
                ClioCommandInvocation(command: .sidebar, arguments: []),
                context: context
            )
            await appState.perform(
                ClioCommandInvocation(command: .search, arguments: []),
                context: context
            )

            XCTAssertEqual(window.tabs.count, 2)
            XCTAssertEqual(appState.isFocusModeEnabled, !originalFocus)
            XCTAssertEqual(appState.isTypewriterModeEnabled, !originalTypewriter)
            XCTAssertEqual(window.isSidebarVisible, !originalSidebar)
            XCTAssertTrue(window.isPalettePresented)
            XCTAssertEqual(window.paletteMode, .search)
        }
    }

    func testContentViewRendersSidebarEditorAndCommandPalette() throws {
        try withTemporaryDirectory { folder in
            try Data("# Render smoke test".utf8).write(
                to: folder.appendingPathComponent("render.md")
            )
            let defaults = makeDefaults()
            let workspace = try Workspace(
                rootURL: folder,
                accessSecurityScopedResource: false
            )
            let appState = AppState(
                defaults: defaults,
                initialWorkspace: workspace,
                searchIndex: RecordingSearchIndex()
            )
            let window = EditorWindowSession(request: .mostRecent())
            window.connect(to: appState)
            window.presentPalette(source: .keyboardShortcut)

            let hosting = NSHostingView(
                rootView: ContentView()
                    .environment(appState)
                    .environment(window)
            )
            hosting.frame = NSRect(x: 0, y: 0, width: 960, height: 720)
            hosting.layoutSubtreeIfNeeded()

            XCTAssertFalse(hosting.subviews.isEmpty)
            XCTAssertTrue(window.isSidebarVisible)
            XCTAssertTrue(window.isPalettePresented)
            XCTAssertEqual(window.activeTab?.draftText, "# Render smoke test")
        }
    }
}

private actor RecordingSearchIndex: SearchIndexing {
    private var queries: [WorkspaceSearchQuery] = []

    func rebuild(
        workspaces _: [WorkspaceDescriptor],
        policy _: DiscoveryPolicy
    ) async throws {}

    func apply(_: [WorkspaceEvent]) async throws {}

    func quickOpen(
        _ query: WorkspaceSearchQuery
    ) async -> AsyncThrowingStream<SearchBatch, Error> {
        queries.append(query)
        return stream()
    }

    func search(
        _ query: WorkspaceSearchQuery
    ) async -> AsyncThrowingStream<SearchBatch, Error> {
        queries.append(query)
        return stream()
    }

    func recordedQueries() -> [WorkspaceSearchQuery] {
        queries
    }

    private func stream() -> AsyncThrowingStream<SearchBatch, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(SearchBatch(results: [], isFinal: true))
            continuation.finish()
        }
    }
}

@MainActor
private extension NavigationSessionTests {
    func makeDefaults() -> UserDefaults {
        let name = "ClioNavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func makeCatalog(defaults: UserDefaults) -> WorkspaceCatalog {
        WorkspaceCatalog(
            defaults: defaults,
            bookmarkMaker: { Data($0.path.utf8) },
            bookmarkResolver: { data in
                let path = String(decoding: data, as: UTF8.self)
                return Workspace.BookmarkResolution(
                    url: URL(fileURLWithPath: path),
                    isStale: false
                )
            },
            workspaceFactory: {
                try Workspace(
                    rootURL: $0,
                    accessSecurityScopedResource: false
                )
            }
        )
    }

    func withTemporaryDirectory<T>(
        _ body: (URL) throws -> T
    ) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioNavigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    func withTemporaryDirectory<T>(
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClioNavigation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }
}
