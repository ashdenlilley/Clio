import XCTest

/// Screenshot-only pass over every Liquid Glass surface, for a human (or
/// agent) to review against docs/ui-glass-audit.md. It asserts almost nothing
/// and never runs in the normal gate: pass `TEST_RUNNER_CLIO_VISUAL_AUDIT=1`
/// to xcodebuild to expose `CLIO_VISUAL_AUDIT=1` to the runner.
///
/// Screenshots may contain local paths; keep them out of the repository.
final class ClioVisualAuditUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CLIO_VISUAL_AUDIT"] == "1",
            "Visual audit runs only with TEST_RUNNER_CLIO_VISUAL_AUDIT=1"
        )
    }

    override func tearDown() {
        if app != nil { exitFullScreenIfNeeded() }
        app?.terminate()
        app = nil
    }

    private func launch(scenario: String? = nil, windowSize: String? = nil) {
        app = XCUIApplication()
        // Neither restore nor save window state: the audit enters full
        // screen, which must not leak into later launches of the app.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["CLIO_UI_TESTING"] = "1"
        app.launchEnvironment["CLIO_UI_TEST_ID"] = UUID().uuidString
        if let scenario { app.launchEnvironment["CLIO_UI_TEST_SCENARIO"] = scenario }
        if let windowSize { app.launchEnvironment["CLIO_UI_TEST_WINDOW_SIZE"] = windowSize }
        app.launch()
        app.windows.firstMatch.hover()
        pause(1)
        exitFullScreenIfNeeded()
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    private var isFullScreen: Bool {
        let state = app.staticTexts["diagnostics.window.fullscreen"].firstMatch
        return state.exists && (state.value as? String) == "fullscreen"
    }

    /// Leaves full screen before termination: SwiftUI restores the window's
    /// full-screen state on the next launch, which would skew later runs.
    /// The menu bar is hidden in full screen, so try each route and verify.
    private func exitFullScreenIfNeeded() {
        let routes: [(String, () -> Void)] = [
            ("shortcut", { self.app.typeKey("f", modifierFlags: [.command, .control]) }),
            ("zoom button", {
                self.app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0)).hover()
                self.pause(1.5)
                let button = self.app.windows.firstMatch.buttons[XCUIIdentifierFullScreenWindow]
                if button.exists { button.click() }
            }),
            ("menu", {
                self.app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).hover()
                self.pause(1.5)
                let exit = self.app.menuBars.menuItems["Exit Full Screen"]
                if exit.exists, exit.isEnabled { exit.click() }
            })
        ]
        for (name, route) in routes where isFullScreen {
            route()
            pause(3)
            if !isFullScreen { print("visual-audit: left full screen via \(name)") }
        }
    }

    /// Uses the menu item: the Control-Command-F shortcut is not reliably
    /// delivered by XCUITest on macOS 26.
    private func enterFullScreen() {
        let enter = app.menuBars.menuItems["Enter Full Screen"]
        if enter.exists, enter.isEnabled {
            enter.click()
        } else {
            app.windows.firstMatch.typeKey("f", modifierFlags: [.command, .control])
        }
        pause(3)
    }

    func testCaptureEverySurface() {
        launch()
        XCTAssertTrue(app.textViews["editor.text"].waitForExistence(timeout: 5))
        pause(1)
        shot("01 editor idle")
        app.typeKey("s", modifierFlags: [.control, .command]); pause(1); shot("02 sidebar hidden")
        app.typeKey("s", modifierFlags: [.control, .command]); pause(1); shot("03 sidebar shown")
        app.typeKey("k", modifierFlags: .command); pause(1); shot("04 palette centred")
        app.typeKey(.escape, modifierFlags: []); pause(0.5)
        app.textViews["editor.text"].click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText("\n/"); pause(1); shot("05 palette inline slash")
        app.typeKey(.escape, modifierFlags: []); pause(0.5)
        app.typeKey("f", modifierFlags: [.command, .shift]); pause(1); shot("06 workspace search")
        app.typeKey(.escape, modifierFlags: []); pause(0.5)
        app.typeKey(",", modifierFlags: .command)
        for category in ["general", "editor", "writing", "workspaces", "export", "assisted", "localMCP"] {
            let button = app.buttons["settings.category.\(category)"]
            if button.waitForExistence(timeout: 3) { button.click() }
            pause(0.5)
            shot("07 settings \(category)")
        }
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.click() } else { app.typeKey(.escape, modifierFlags: []) }
        pause(1)
        app.typeKey("e", modifierFlags: [.command, .shift]); pause(1.5); shot("08 export sheet")
        app.typeKey(.escape, modifierFlags: []); pause(1)
        app.textViews["editor.text"].click()
        app.typeText("typing burst typing burst typing burst")
        pause(6); shot("09 chrome faded")
        enterFullScreen(); shot("10 full screen")
        app.typeKey("k", modifierFlags: .command); pause(1); shot("10b full screen palette")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Frames taken while the context chrome and sidebar fade, to catch flat
    /// grey remnants of glass that fades by opacity alone.
    func testCaptureFadeFrames() {
        launch()
        XCTAssertTrue(app.textViews["editor.text"].waitForExistence(timeout: 5))
        pause(1)
        app.textViews["editor.text"].click()
        app.typeKey(.downArrow, modifierFlags: .command)
        app.typeText(" fading chrome check")
        for index in 0..<8 {
            shot("11 fade out \(index)")
        }
        pause(6)
        app.windows.firstMatch.hover()
        for index in 0..<6 {
            shot("12 fade in \(index)")
        }
        app.typeKey("s", modifierFlags: [.control, .command])
        for index in 0..<4 { shot("13 sidebar toggle \(index)") }
        app.typeKey("k", modifierFlags: .command)
        for index in 0..<4 { shot("14 palette appear \(index)") }
        app.typeKey(.escape, modifierFlags: [])
        for index in 0..<4 { shot("15 palette dismiss \(index)") }
    }

    /// Banner and sheet surfaces that need seeded state.
    func testCaptureBanners() {
        launch(scenario: "missing-restore")
        pause(3)
        shot("16 detached banner")
        app.typeKey("s", modifierFlags: [.control, .command]); pause(1)
        shot("16b detached banner sidebar toggled")
        app.typeKey("s", modifierFlags: [.control, .command]); pause(1)
        enterFullScreen()
        shot("16c detached banner full screen")
    }

    func testCaptureBannersAtMinimumWindow() {
        launch(scenario: "missing-restore", windowSize: "480x400")
        pause(3)
        shot("17 detached banner minimum window")
        app.typeKey("s", modifierFlags: [.control, .command]); pause(1)
        shot("17b detached banner minimum window sidebar hidden")
    }

    func testCaptureMinimumWindow() {
        launch(windowSize: "480x400")
        XCTAssertTrue(app.textViews["editor.text"].waitForExistence(timeout: 5))
        pause(1)
        shot("18 minimum window")
        app.typeKey(",", modifierFlags: .command); pause(1)
        shot("18b minimum window settings")
        app.typeKey(.escape, modifierFlags: []); pause(1)
        app.typeKey("k", modifierFlags: .command); pause(1)
        shot("18c minimum window palette")
    }
}
