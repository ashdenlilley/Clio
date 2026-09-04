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

        XCTAssertTrue(
            EditorCoordinator.isInlineSlashTrigger(
                in: "First line\n",
                range: NSRange(location: 11, length: 0),
                replacement: "/"
            )
        )
        window.presentInlineSlashPalette()

        XCTAssertTrue(window.isPalettePresented)
        XCTAssertEqual(window.paletteSource, .inlineSlash)
        XCTAssertEqual(window.paletteQuery, "/")
        XCTAssertEqual(window.activeTab?.draftText, "First line\n")
    }

    func testSlashInsideProseRemainsPlainText() {
        let window = EditorWindowSession(request: .newDocument())
        window.activeTab?.draftText = "path"

        XCTAssertFalse(
            EditorCoordinator.isInlineSlashTrigger(
                in: "path",
                range: NSRange(location: 4, length: 0),
                replacement: "/"
            )
        )
        window.noteEditorChange(
            to: "path/",
            edit: EditorTextEdit(
                replacedRange: UTF16Range(location: 4, length: 0),
                replacement: "/"
            )
        )

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

    func testSlashCommandParserPreservesExportArgumentsAndQuotedValues() throws {
        XCTAssertEqual(
            try ClioCommandParser.parse("/export pdf"),
            ClioCommandInvocation(command: .export, arguments: ["pdf"])
        )
        XCTAssertEqual(
            try ClioCommandParser.parse("  /search \"two words\" one\\ two  "),
            ClioCommandInvocation(
                command: .search,
                arguments: ["two words", "one two"]
            )
        )
        XCTAssertThrowsError(try ClioCommandParser.parse("/export docx")) {
            XCTAssertEqual($0 as? ClioCommandParseError, .invalidExportFormat("docx"))
        }
        XCTAssertThrowsError(try ClioCommandParser.parse("/search 'unfinished")) {
            XCTAssertEqual($0 as? ClioCommandParseError, .unterminatedQuote)
        }
    }

    func testPaletteArgumentsDoNotBreakFilteringAndSelectionIsClamped() throws {
        let window = EditorWindowSession(request: .newDocument())
        window.presentPalette(query: "/export html")

        XCTAssertEqual(window.filteredCommands.map(\.command), [.export])
        XCTAssertEqual(
            try window.invocation(for: .export),
            ClioCommandInvocation(command: .export, arguments: ["html"])
        )

        window.presentPalette()
        window.movePaletteSelection(by: 10_000)
        XCTAssertEqual(
            window.paletteSelectionIndex,
            ClioCommandDescriptor.all.count - 1
        )
        window.movePaletteSelection(by: -10_000)
        XCTAssertEqual(window.paletteSelectionIndex, 0)
    }

    func testSlashTriggerUsesOnlyTheEditedRangeAndIgnoresMarkedText() {
        XCTAssertTrue(
            EditorCoordinator.isInlineSlashTrigger(
                in: "🙂\n",
                range: NSRange(location: 3, length: 0),
                replacement: "/"
            )
        )
        XCTAssertFalse(
            EditorCoordinator.isInlineSlashTrigger(
                in: "🙂\n",
                range: NSRange(location: 3, length: 0),
                replacement: "/",
                hasMarkedText: true
            )
        )
        XCTAssertFalse(
            EditorCoordinator.isInlineSlashTrigger(
                in: "text",
                range: NSRange(location: 2, length: 0),
                replacement: "/"
            )
        )
    }

    func testIncrementalWordCountStaysExactAcrossLocalEdits() throws {
        try withTemporaryDirectory { folder in
            let workspace = try Workspace(
                rootURL: folder,
                accessSecurityScopedResource: false
            )
            let session = EditorSession(openingMode: .newDocument)
            session.activate(in: workspace, documentURLs: [])

            session.editorTextDidChange(
                "One two",
                edit: EditorTextEdit(
                    replacedRange: UTF16Range(location: 0, length: 0),
                    replacement: "One two"
                )
            )
            XCTAssertEqual(session.wordCount, 2)

            session.editorTextDidChange(
                "One two three",
                edit: EditorTextEdit(
                    replacedRange: UTF16Range(location: 7, length: 0),
                    replacement: " three"
                )
            )
            XCTAssertEqual(session.wordCount, 3)
        }
    }

    func testBackgroundWordCountPublishesOnlyTheLatestGeneration() async throws {
        try await withTemporaryDirectory { folder in
            let workspace = try Workspace(
                rootURL: folder,
                accessSecurityScopedResource: false
            )
            let session = EditorSession(openingMode: .newDocument)
            session.activate(in: workspace, documentURLs: [])
            let longWord = String(repeating: "a", count: 10_000)

            session.editorTextDidChange(
                longWord + " two",
                edit: EditorTextEdit(
                    replacedRange: UTF16Range(location: 0, length: 0),
                    replacement: longWord + " two"
                )
            )
            session.editorTextDidChange(
                longWord + " two three",
                edit: EditorTextEdit(
                    replacedRange: UTF16Range(
                        location: longWord.utf16.count + 4,
                        length: 0
                    ),
                    replacement: " three"
                )
            )

            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(session.wordCount, 3)
        }
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

    func testOpeningSearchResultAppliesMatchToExistingTabViewport() throws {
        try withTemporaryDirectory { folder in
            let fileURL = folder.appendingPathComponent("shared.md")
            try Data("before needle after".utf8).write(to: fileURL)
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
            let tab = try XCTUnwrap(window.activeTab)
            let match = UTF16Range(location: 7, length: 6)

            appState.openSearchResult(
                WorkspaceSearchResult(
                    documentID: tab.documentID,
                    workspaceID: descriptor.id,
                    relativePath: "shared.md",
                    documentMatchRange: match,
                    score: 1
                ),
                from: window
            )

            XCTAssertEqual(window.tabs.count, 1)
            XCTAssertEqual(tab.viewportState.selection, match)
            XCTAssertEqual(tab.viewportState.topVisibleUTF16Offset, match.location)
        }
    }

    func testEditorCoordinatorAppliesViewportNavigationAfterInitialRestore() {
        var text = "before needle after"
        var viewport = EditorViewportState.zero
        let textBinding = Binding(
            get: { text },
            set: { text = $0 }
        )
        let viewportBinding = Binding(
            get: { viewport },
            set: { viewport = $0 }
        )
        let coordinator = EditorCoordinator(
            text: textBinding,
            viewport: viewportBinding,
            configuration: EditorConfiguration()
        )
        let surface = EditorContainerView(
            textView: EditorTextView.makeTextKit2TextView()
        )
        coordinator.attach(to: surface)
        coordinator.update(
            text: textBinding,
            viewport: viewportBinding,
            configuration: EditorConfiguration()
        )

        viewport = EditorViewportState(
            selection: UTF16Range(location: 7, length: 6),
            topVisibleUTF16Offset: 7,
            fractionalYOffset: 0
        )
        coordinator.update(
            text: textBinding,
            viewport: viewportBinding,
            configuration: EditorConfiguration()
        )

        XCTAssertEqual(
            surface.textView.selectedRange(),
            NSRange(location: 7, length: 6)
        )
    }

    func testCatalogRejectsNonParentBeforePersistingGrant() throws {
        try withTemporaryDirectory { selectedFolder in
            try withTemporaryDirectory { otherFolder in
                let outsideDocument = otherFolder.appendingPathComponent("outside.md")
                try Data("outside".utf8).write(to: outsideDocument)
                let defaults = makeDefaults()
                let catalog = makeCatalog(defaults: defaults)

                XCTAssertThrowsError(
                    try catalog.addAuthorizedFolder(
                        selectedFolder,
                        containing: outsideDocument
                    )
                ) {
                    XCTAssertEqual(
                        $0 as? WorkspaceCatalog.CatalogError,
                        .selectedFolderDoesNotContainDocument(outsideDocument)
                    )
                }
                XCTAssertTrue(catalog.descriptors.isEmpty)
                XCTAssertTrue(makeCatalog(defaults: defaults).descriptors.isEmpty)
            }
        }
    }

    func testSidebarInteractionHooksPauseDeferredDismissal() {
        let window = EditorWindowSession(request: .newDocument())
        window.revealSidebarTemporarily()
        window.setSidebarHovered(true)

        XCTAssertTrue(window.isSidebarInteractionActive)
        XCTAssertTrue(window.isSidebarVisible)

        window.setSidebarHovered(false)
        window.setSidebarFocused(true)
        XCTAssertTrue(window.isSidebarInteractionActive)
        window.setSidebarFocused(false)
        XCTAssertFalse(window.isSidebarInteractionActive)
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

    func testExportCommandForwardsParsedArguments() async throws {
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
            var captured: [String]?
            let observer = NotificationCenter.default.addObserver(
                forName: .clioRequestedExport,
                object: nil,
                queue: .main
            ) { notification in
                captured = notification.userInfo?[ClioExportNotificationKey.arguments]
                    as? [String]
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            await appState.perform(
                ClioCommandInvocation(command: .export, arguments: ["pdf"]),
                context: ClioCommandContext(
                    windowID: window.id,
                    tabID: window.activeTabID,
                    source: .inlineSlash
                )
            )

            XCTAssertEqual(captured, ["pdf"])
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
