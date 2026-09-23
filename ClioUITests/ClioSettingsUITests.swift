import XCTest

/// Covers the categorised Settings panel introduced with Liquid Glass: every
/// category surfaces a representative control, the status-line toggle hides
/// the statistics capsule it controls, the writer's slash-command opt-out
/// leaves a literal `/` in the document, and the panel still fits (and the
/// Done button stays reachable) at the window's minimum size.
final class ClioSettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["CLIO_UI_TESTING"] = "1"
        app.launchEnvironment["CLIO_UI_TEST_ID"] = UUID().uuidString
        app.launch()
        app.windows.firstMatch.hover()
        XCTAssertTrue(app.textViews["editor.text"].waitForExistence(timeout: 5))
    }

    override func tearDown() { app.terminate() }

    private func openSettings(_ category: String) {
        app.typeKey(",", modifierFlags: .command)
        let button = app.buttons["settings.category.\(category)"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.click()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testEveryCategoryShowsARepresentativeControl() {
        let expectations: [(String, String)] = [
            ("general", "settings.general.launch"),
            ("editor", "settings.editor.minimap"),
            ("writing", "settings.writing.slash"),
            ("workspaces", "settings.workspaces.recoveryFolder"),
            ("export", "settings.export.defaultFormat"),
            ("assisted", "settings.intelligence.enabled"),
            ("localMCP", "settings.mcp.authorize"),
        ]
        app.typeKey(",", modifierFlags: .command)
        for (category, control) in expectations {
            let button = app.buttons["settings.category.\(category)"]
            XCTAssertTrue(button.waitForExistence(timeout: 3), category)
            button.click()
            XCTAssertTrue(app.descendants(matching: .any)[control].waitForExistence(timeout: 3), control)
            attach("Settings – \(category)")
        }
    }

    func testStatusLineToggleHidesStatistics() {
        XCTAssertTrue(app.descendants(matching: .any)["editor.statistics"].exists)
        openSettings("editor")
        app.switches["settings.editor.statusLine"].click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.descendants(matching: .any)["editor.statistics"].waitForExistence(timeout: 1))
    }

    func testSlashCommandsOffInsertsLiteralSlash() {
        openSettings("writing")
        app.switches["settings.writing.slash"].click()
        app.typeKey(.escape, modifierFlags: [])
        let editor = app.textViews["editor.text"]
        editor.click()
        app.typeKey(.leftArrow, modifierFlags: .command)
        app.typeKey(.upArrow, modifierFlags: .command)
        app.typeText("/")
        XCTAssertFalse(app.textFields["palette.query"].waitForExistence(timeout: 1))
        XCTAssertTrue((editor.value as? String)?.hasPrefix("/Alpha") == true)
    }

    func testSettingsFitsTheMinimumWindow() {
        let window = app.windows.firstMatch
        // Drag the bottom-right corner inward; the window's minimum size stops it at 480×400.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: .zero))
        openSettings("editor")
        XCTAssertTrue(app.buttons["Done"].isHittable)
        XCTAssertTrue(app.switches["settings.editor.minimap"].waitForExistence(timeout: 3))
        attach("Settings at minimum window")
    }
}
