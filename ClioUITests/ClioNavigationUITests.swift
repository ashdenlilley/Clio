import XCTest

final class ClioNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
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

    private func launch(scenario: String) {
        app = XCUIApplication()
        app.launchEnvironment["CLIO_UI_TESTING"] = "1"
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
