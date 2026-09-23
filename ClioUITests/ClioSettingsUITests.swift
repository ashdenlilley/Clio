import AppKit
import ApplicationServices
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

    /// Sets the frontmost Clio window's size through the public Accessibility
    /// API rather than simulating a corner-drag gesture, as a fallback for
    /// hosts where the coordinate drag doesn't take. AppKit still clamps the
    /// request to the window's real `minSize`, so this exercises the same
    /// 480×400 floor a user hits by dragging the corner — it does not bypass
    /// any product behaviour. It is a safe no-op (returns `false`) on a host
    /// that hasn't granted the calling process Accessibility access.
    @discardableResult
    private func setFrontmostWindowSize(_ size: CGSize) -> Bool {
        // A stale instance from an earlier test run can still be present
        // (terminated but not yet reaped, or hidden), so try every running
        // match rather than just the first, and skip any with no windows.
        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "olympus.clio.mac"
        }
        for runningApp in candidates {
            let axApp = AXUIElementCreateApplication(runningApp.processIdentifier)
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let axWindows = windowsValue as? [AXUIElement],
                  !axWindows.isEmpty
            else { continue }
            var mutableSize = size
            guard let axSize = AXValueCreate(.cgSize, &mutableSize) else { continue }
            var didResize = false
            for axWindow in axWindows {
                if AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, axSize) == .success {
                    didResize = true
                }
            }
            if didResize { return true }
        }
        return false
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

        // Baseline at the window's default (wide) size: the category list is
        // not compact, so an unselected category's title renders as visible
        // text alongside its icon.
        openSettings("editor")
        XCTAssertTrue(app.buttons["Done"].isHittable)
        XCTAssertTrue(app.switches["settings.editor.minimap"].waitForExistence(timeout: 3))
        let workspacesButton = app.buttons["settings.category.workspaces"]
        XCTAssertTrue(workspacesButton.waitForExistence(timeout: 3))
        let expandedWidth = workspacesButton.frame.width
        app.typeKey(.escape, modifierFlags: [])

        // Drag the bottom-right corner inward; the window's minimum size stops it at 480×400.
        func windowIsAtMinimum() -> Bool {
            // Allow slack above the content minimum (480×400) for the
            // titlebar and any backing-scale rounding.
            let f = app.windows.firstMatch.frame
            return f.width <= 500 && f.height <= 440
        }
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: .zero))
        if !waitUntil(timeout: 3, condition: windowIsAtMinimum) {
            // The corner drag doesn't take on every host (some CI/sandbox
            // configurations don't deliver a resize-tracking drag through
            // synthetic coordinate events); fall back to the Accessibility
            // API, which is a no-op if the host hasn't granted it.
            setFrontmostWindowSize(CGSize(width: 100, height: 100))
        }
        XCTAssertTrue(
            waitUntil(timeout: 3, condition: windowIsAtMinimum),
            "The window must shrink to its 480×400 minimum (was \(app.windows.firstMatch.frame)); "
                + "on this host neither the corner-drag gesture nor AXUIElementSetAttributeValue could "
                + "resize the window (AXIsProcessTrusted=\(AXIsProcessTrusted())) — grant Accessibility "
                + "access to the UI-test host process to run this assertion"
        )

        openSettings("editor")
        XCTAssertTrue(app.buttons["Done"].isHittable)
        XCTAssertTrue(app.switches["settings.editor.minimap"].waitForExistence(timeout: 3))

        // Below 600pt the category list collapses to icon-only: the
        // unselected category's button and identifier remain, but its row
        // narrows from the full 176pt list to the 52pt icon-only list.
        XCTAssertTrue(workspacesButton.exists)
        XCTAssertTrue(workspacesButton.isHittable)
        let compactWidth = workspacesButton.frame.width
        XCTAssertLessThan(
            compactWidth, expandedWidth * 0.6,
            "Compact mode must narrow the category row, not just shrink the panel (expanded \(expandedWidth), compact \(compactWidth))"
        )
        attach("Settings at minimum window")
    }
}
