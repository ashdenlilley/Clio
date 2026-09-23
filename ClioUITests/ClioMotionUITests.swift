import XCTest

final class ClioMotionUITests: ClioDiagnosticTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        // Never restore or save AppKit window state (fullscreen tests leave it).
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["CLIO_UI_TESTING"] = "1"
        app.launchEnvironment["CLIO_UI_LAUNCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["CLIO_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["CLIO_UI_TEST_SCENARIO"] = "restoration"
        if ProcessInfo.processInfo.environment["CLIO_RUN_MOTION_TRACE"] == "1" {
            app.launchEnvironment["CLIO_UI_TEST_MOTION_TRACE"] = "1"
            print("MOTION_METRICS_IDENTIFIER=\(app.launchEnvironment["CLIO_UI_TEST_ID"]!)")
        }
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        app = nil
    }

    func testNativeToggleKeepsEditorFrameAndCaretAcrossRepeatedReversals() {
        if ProcessInfo.processInfo.environment["CLIO_RUN_MOTION_TRACE"] == "1" {
            // The app drives a bounded reversal sequence. Deliberately avoid
            // accessibility/screenshot requests throughout the trace window.
            Thread.sleep(forTimeInterval: 14)
            return
        }
        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let frame = editor.frame
        let toggle = app.buttons["sidebar.toggle"]
        XCTAssertEqual(app.buttons.matching(identifier: "sidebar.toggle").count, 1)
        for index in 0..<20 {
            toggle.click()
            XCTAssertEqual(editor.frame, frame)
            if index == 0 {
                Thread.sleep(forTimeInterval: 0.3)
                attachWindow("Pure black writing canvas with sole native toggle")
            }
        }
        app.typeText("X")
        XCTAssertEqual(editor.value as? String, "AlphaX beta gamma\nSecond line\n")
        attachWindow("Revealed overlay sidebar and fixed editor canvas")
    }

    func testPaletteRapidReopenRestoresExactInsertionPoint() {
        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            app.typeKey("k", modifierFlags: .command)
            XCTAssertTrue(app.textFields["palette.query"].waitForExistence(timeout: 3))
            attachWindow("Command palette")
            app.typeKey(.escape, modifierFlags: [])
        }
        app.typeText("X")
        XCTAssertEqual(editor.value as? String, "AlphaX beta gamma\nSecond line\n")
    }

    func testSlashDismissalResumesTypingAtOriginalCharacter() {
        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        // Fixture restores the insertion point immediately after "Alpha".
        app.typeText("/")
        XCTAssertTrue(app.textFields["palette.query"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        app.typeText("🙂X")
        XCTAssertEqual(editor.value as? String, "Alpha/🙂X beta gamma\nSecond line\n")
        app.typeText("/")
        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        query.typeText("  ")
        app.typeText("Y")
        XCTAssertEqual(editor.value as? String, "Alpha/🙂X/Y beta gamma\nSecond line\n")
    }

    func testSettingsUsesCurrentWindowAndRestoresEditorFocus() {
        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let windowCount = app.windows.count
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.windows.count, windowCount)
        attachWindow("In-window settings")
        app.typeKey(.escape, modifierFlags: [])
        app.typeText("X")
        XCTAssertEqual(editor.value as? String, "AlphaX beta gamma\nSecond line\n")
    }

    private func attachWindow(_ name: String) {
        let snapshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        snapshot.name = name
        snapshot.lifetime = .keepAlways
        add(snapshot)
    }
}
