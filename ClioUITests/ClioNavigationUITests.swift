import XCTest

final class ClioNavigationUITests: ClioDiagnosticTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testSidebarNewDocumentCancellationDoesNotAddATab() {
        launch(scenario: "restoration")
        let create = app.buttons["sidebar.newDocument"]
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        let originalCount = app.buttons.matching(identifier: "sidebar.tab").count
        create.click()
        // NSSavePanel mirrors Cancel/Create into the Touch Bar on Macs that
        // have one, so an app-wide "Cancel" query can resolve to an
        // unclickable Touch Bar button. Scope to the panel's own button.
        let panel = app.dialogs["save-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let cancel = panel.buttons["CancelButton"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.click()
        XCTAssertTrue(waitUntil { !panel.exists }, "Cancel must dismiss the New Document panel")
        XCTAssertEqual(app.buttons.matching(identifier: "sidebar.tab").count, originalCount)
    }

    func testSidebarInlineRenameSupportsDoubleClickEscapeAndContextMenu() {
        launch(scenario: "restoration")
        let tab = app.buttons["sidebar.tab"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 3))
        tab.doubleClick()
        let field = app.textFields["sidebar.rename"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Cancelled.md")
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { !field.exists })
        XCTAssertTrue(tab.label.contains("seed.md"))
        tab.rightClick()
        app.menuItems["Rename"].click()
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Renamed.md")
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { !field.exists && tab.label.contains("Renamed.md") })
        XCTAssertEqual(app.textViews["editor.text"].value as? String, "Alpha beta gamma\nSecond line\n")
    }

    func testCommandPaletteKeyboardSelectionAndReturn() {
        launch(scenario: "blank")

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["command.palette"].waitForExistence(timeout: 3))
        let openCommand = app.buttons["palette.command.open"]
        XCTAssertTrue(openCommand.exists)

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertEqual(openCommand.value as? String, "Selected")

        let query = app.textFields["palette.query"]
        query.typeText("sidebar")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { !self.app.descendants(matching: .any)["sidebar"].exists })
    }

    func testInlineSlashPaletteIsFullyKeyboardNavigable() {
        launch(scenario: "blank")

        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.typeText("/")
        XCTAssertTrue(app.descendants(matching: .any)["command.palette"].waitForExistence(timeout: 3))

        app.textFields["palette.query"].typeText("sidebar")
        app.typeKey(.pageDown, modifierFlags: [])
        app.typeKey(.pageUp, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { !self.app.descendants(matching: .any)["sidebar"].exists })
    }

    func testDoubleSpaceDismissesSlashPaletteAndLeavesLiteralSlash() {
        launch(scenario: "blank")
        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.typeText("/")
        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        query.typeText(" ")
        XCTAssertTrue(query.exists)
        query.typeText(" ")
        XCTAssertTrue(waitUntil { !self.app.descendants(matching: .any)["command.palette"].exists })
        XCTAssertEqual(editor.value as? String, "/")
        app.typeText("next")
        XCTAssertEqual(editor.value as? String, "/next")
    }

    func testSlashInsideProseUsesCenteredPaletteAndEscapePreservesText() {
        launch(scenario: "blank")
        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.typeText("Some text/")
        let palette = app.descendants(matching: .any)["command.palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil { abs(palette.frame.midX - self.app.windows.firstMatch.frame.midX) < 10 })
        app.textFields["palette.query"].typeText("literal")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { editor.value as? String == "Some text/literal" })
        app.typeText("!")
        XCTAssertEqual(editor.value as? String, "Some text/literal!")
    }

    func testEmptyLineSlashUsesCompactAnchoredPalette() {
        launch(scenario: "blank")
        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        let editorFrame = editor.frame
        editor.typeText("/")
        let palette = app.descendants(matching: .any)["command.palette"]
        XCTAssertTrue(palette.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil { palette.frame.width <= 421 })
        XCTAssertGreaterThan(palette.frame.minY, editorFrame.minY)
        XCTAssertLessThanOrEqual(palette.frame.maxY, app.windows.firstMatch.frame.maxY)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Caret-anchored slash palette"
        capture.lifetime = .keepAlways
        add(capture)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil { editor.value as? String == "/" })
    }

    func testNewDocumentAndNewWindowFollowNativeShortcuts() {
        launch(scenario: "blank")

        XCTAssertTrue(app.buttons["sidebar.tab"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons.matching(identifier: "sidebar.tab").count, 1)

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitUntil {
            self.app.buttons.matching(identifier: "sidebar.tab").count == 2
        })

        let originalWindowCount = app.windows.count
        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitUntil { self.app.windows.count == originalWindowCount + 1 })
    }

    func testSidebarToggleAndEditorSurfaceHaveDeterministicAccessibility() {
        launch(scenario: "blank")

        XCTAssertTrue(
            app.descendants(matching: .any)["editor.surface.no-focus-ring"]
                .waitForExistence(timeout: 3)
        )
        let toggle = app.buttons["sidebar.toggle"].firstMatch
        XCTAssertTrue(toggle.exists)
        toggle.click()
        XCTAssertTrue(waitUntil { !self.app.descendants(matching: .any)["sidebar"].exists })
        XCTAssertTrue(app.buttons["sidebar.toggle"].waitForExistence(timeout: 2))
    }

    func testRestoredCaretReceivesTypingAtSavedUTF16Offset() {
        launch(scenario: "restoration")

        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.typeText("X")
        XCTAssertEqual(
            editor.value as? String,
            "AlphaX beta gamma\nSecond line\n"
        )
    }

    func testMinimapStartsTopRightAndNavigationKeepsTypingPosition() {
        launch(scenario: "blank")
        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        let minimap = app.descendants(matching: .any)["editor.minimap"]
        XCTAssertFalse(minimap.exists)
        editor.typeText("One\nSecond line\nThird line")
        XCTAssertTrue(minimap.waitForExistence(timeout: 3))
        XCTAssertLessThan(minimap.frame.height, 60)
        XCTAssertLessThan(abs(minimap.frame.maxX - app.windows.firstMatch.frame.maxX), 24)
        minimap.click()
        app.typeText("!")
        XCTAssertEqual(editor.value as? String, "One\nSecond line\nThird line!")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Top-right line minimap"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testMinimapFadesWithWritingChromeAndPointerRestoresIt() {
        launch(scenario: "blank")
        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.typeText("A line of writing")
        let minimap = app.descendants(matching: .any)["editor.minimap"]
        XCTAssertTrue(minimap.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil(timeout: 8) { !minimap.exists })
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.1)).hover()
        XCTAssertTrue(minimap.waitForExistence(timeout: 3))
    }

    func testFullscreenMouseSelectionContextMenuAndReturnToWindow() {
        launch(scenario: "blank")
        let editorWindows = app.windows.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "diagnostics.editor-window.")
        )
        XCTAssertTrue(editorWindows.element.waitForExistence(timeout: 5))
        XCTAssertEqual(editorWindows.count, 1, "This fixture must launch one identifiable editor window")
        // Retain a query by stable session identity, not front-to-back order.
        let window = app.windows[editorWindows.element.identifier]
        let editor = window.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText("Alpha beta gamma\nSecond line")
        // Hide sidebar without moving the caret; test the writing canvas itself.
        window.buttons["sidebar.toggle"].click()
        assertFullscreenState(false, for: window, timeout: 3)
        assertTypingLineSupportsMouseSelection(editor)
        toggleFullScreen(in: app)
        assertFullscreenState(true, for: window)
        assertTypingLineSupportsMouseSelection(editor)
        // A coordinate drag exercises hit testing, not accessibility select-all.
        // Use the macOS mouse API: press(forDuration:thenDragTo:) is a touch
        // gesture that testmanagerd replays through a virtual HID service,
        // which WindowServer can refuse, delivering no events to the app.
        // The current typing line is at the configured 45% vertical anchor.
        let viewport = app.descendants(matching: .any)["editor.surface.no-focus-ring"]
        let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.36))
        start.click(forDuration: 0.1, thenDragTo: end)
        editor.rightClick()
        assertEditorCopyContextMenu(editor)
        app.typeKey(.escape, modifierFlags: [])
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Fullscreen block caret and native selection"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        settleTypewriterAnchor(editor)
        toggleFullScreen(in: app)
        assertFullscreenState(false, for: window)
        assertTypingLineSupportsMouseSelection(editor)
        editor.click()
        editor.rightClick()
        assertEditorCopyContextMenu(editor, requiringSelection: false)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(editor.value as? String, "Alpha beta gamma\nSecond line")
    }

    private func assertTypingLineSupportsMouseSelection(_ editor: XCUIElement) {
        let original = editor.value as? String
        let viewport = app.descendants(matching: .any)["editor.surface.no-focus-ring"]
        let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.36))
        start.click()
        start.click(forDuration: 0.1, thenDragTo: end)
        editor.rightClick()
        assertEditorCopyContextMenu(editor)
        app.typeKey(.escape, modifierFlags: [])
        app.typeText("REPLACED")
        XCTAssertTrue(waitUntil { (editor.value as? String)?.contains("REPLACED") == true })
        XCTAssertLessThan((editor.value as? String)?.count ?? Int.max, (original?.count ?? 0) + "REPLACED".count,
                          "Mouse drag must select text, not merely leave an insertion point")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { editor.value as? String == original })
        settleTypewriterAnchor(editor)
    }

    /// A mouse press suspends typewriter scrolling until the writer types
    /// again, so the typing line stays wherever the click left it. Return to
    /// the end with an edit (then undo it) so the next phase starts with the
    /// typing line back at the anchor.
    private func settleTypewriterAnchor(_ editor: XCUIElement) {
        let original = editor.value as? String
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" ")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitUntil { editor.value as? String == original })
        // The edit starts the typewriter's eased return scroll. The text view's
        // AX frame tracks the scroll offset, so wait until it stops moving
        // between predicate polls (about one second apart).
        var lastFrame = CGRect.null
        XCTAssertTrue(waitUntil(timeout: 6) {
            let frame = editor.frame
            defer { lastFrame = frame }
            return frame == lastFrame
        }, "The typewriter scroll must settle before the next phase")
    }

    private func assertEditorCopyContextMenu(
        _ editor: XCUIElement,
        requiringSelection: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // The app's Edit menu also contains Copy. Only the native text view's
        // context menu proves this right-click exercised editor hit testing.
        let copyItems = editor.menus.menuItems.matching(identifier: "Copy")
        XCTAssertTrue(copyItems.element.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertEqual(copyItems.count, 1, "The editor context menu must contain exactly one Copy command",
                       file: file, line: line)
        if requiringSelection {
            XCTAssertTrue(copyItems.element.isEnabled, "The coordinate drag must create a copyable selection",
                          file: file, line: line)
        }
    }

    private func launch(scenario: String) {
        app = XCUIApplication()
        // Fullscreen tests leave AppKit restorable window state for this
        // bundle; never restore (or save) it, or the next launch reopens a
        // fullscreen window with no titlebar controls.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["CLIO_UI_TESTING"] = "1"
        app.launchEnvironment["CLIO_UI_LAUNCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["CLIO_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["CLIO_UI_TEST_SCENARIO"] = scenario
        app.launch()
        // The pointer survives termination/relaunch. On macOS 15 it can rest
        // on the newly positioned green window button and open the system
        // arrangement menu, which intercepts otherwise correctly focused typing.
        // Hover only: do not click, acquire editor focus, or move its saved caret.
        app.windows.firstMatch.hover()
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping () -> Bool
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
