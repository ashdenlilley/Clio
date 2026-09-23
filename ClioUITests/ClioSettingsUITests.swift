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
        // Never restore or save AppKit window state (fullscreen tests leave it).
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
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

    /// Terminates the shared `app` and relaunches it with the given extra
    /// launch environment, on top of the standard UI-testing environment.
    private func relaunch(extraEnvironment: [String: String]) {
        app.terminate()
        app = XCUIApplication()
        // Never restore or save AppKit window state (fullscreen tests leave it).
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["CLIO_UI_TESTING"] = "1"
        app.launchEnvironment["CLIO_UI_TEST_ID"] = UUID().uuidString
        for (key, value) in extraEnvironment { app.launchEnvironment[key] = value }
        app.launch()
        app.windows.firstMatch.hover()
        XCTAssertTrue(app.textViews["editor.text"].waitForExistence(timeout: 5))
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

    func testMinimapToggleHidesOverlay() {
        XCTAssertTrue(app.descendants(matching: .any)["editor.minimap"].waitForExistence(timeout: 3))
        openSettings("editor")
        app.switches["settings.editor.minimap"].click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.descendants(matching: .any)["editor.minimap"].waitForExistence(timeout: 1))
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
        // Baseline at the shared setUp's default (wide) window: the category
        // list is not compact, so capture the row width to compare against
        // the compact layout below.
        openSettings("editor")
        XCTAssertTrue(app.buttons["Done"].isHittable)
        XCTAssertTrue(app.switches["settings.editor.minimap"].waitForExistence(timeout: 3))
        let expandedWidth = app.buttons["settings.category.workspaces"].frame.width
        app.typeKey(.escape, modifierFlags: [])

        // Simulating a corner-drag resize is unreliable across hosts, and a
        // UI test must not drive the app through the Accessibility API or
        // System Events. Instead, relaunch pinned to the window's 480×400
        // minimum via the UI-test-only CLIO_UI_TEST_WINDOW_SIZE launch hook
        // (see ClioUITestWindowSize / WindowProbeView.configureWindowIfNeeded
        // in ContentView.swift), which is only ever honoured when
        // CLIO_UI_TESTING == "1".
        relaunch(extraEnvironment: ["CLIO_UI_TEST_WINDOW_SIZE": "480x400"])
        let window = app.windows.firstMatch
        XCTAssertTrue(
            waitUntil(timeout: 3, condition: { window.frame.width <= 500 && window.frame.height <= 440 }),
            "CLIO_UI_TEST_WINDOW_SIZE=480x400 must pin the window to its 480×400 minimum (was \(window.frame))"
        )

        openSettings("editor")
        XCTAssertTrue(app.buttons["Done"].isHittable)
        XCTAssertTrue(app.switches["settings.editor.minimap"].waitForExistence(timeout: 3))

        // Below 600pt the category list collapses to icon-only: the
        // unselected category's button and identifier remain, but its row
        // narrows from the full 176pt list to the 52pt icon-only list.
        let compactButton = app.buttons["settings.category.workspaces"]
        XCTAssertTrue(compactButton.exists)
        XCTAssertTrue(compactButton.isHittable)
        let compactWidth = compactButton.frame.width
        XCTAssertLessThan(
            compactWidth, expandedWidth * 0.6,
            "Compact mode must narrow the category row, not just shrink the panel (expanded \(expandedWidth), compact \(compactWidth))"
        )
        attach("Settings at minimum window")
    }
}
