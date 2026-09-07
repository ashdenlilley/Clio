import AppKit
import XCTest

class ClioDiagnosticTestCase: XCTestCase {
    private var capturedFailure = false

    override func setUp() {
        super.setUp()
        capturedFailure = false
        continueAfterFailure = false
    }

    override func record(_ issue: XCTIssue) {
        // Record once before teardown terminates Clio. Avoid querying the app's
        // AX tree here: it may be the service that's stalled during launch.
        if !capturedFailure {
            capturedFailure = true
            let processes = NSRunningApplication.runningApplications(withBundleIdentifier: "olympus.clio.mac")
            let summary = processes.map {
                "pid=\($0.processIdentifier) active=\($0.isActive) terminated=\($0.isTerminated) activationPolicy=\($0.activationPolicy.rawValue)"
            }.joined(separator: "\n")
            print("CLIO_LAUNCH_DIAGNOSTICS: \(summary.isEmpty ? "no Clio process" : summary)")
            let state = XCTAttachment(string: summary)
            state.name = "Clio process state at first failure"
            state.lifetime = .keepAlways
            add(state)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Cloud desktop at first failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        super.record(issue)
    }
}

final class ClioShutdownUITests: ClioDiagnosticTestCase {
    func testRepeatedKeyboardQuitSavesAndRelaunches() throws {
        try exerciseQuit(menu: false, closeWindow: false, fullscreen: false)
    }

    func testMenuQuitAfterLastWindowClosed() throws {
        try exerciseQuit(menu: true, closeWindow: true, fullscreen: false)
    }

    func testFullscreenMultiwindowQuitSavesAndRelaunches() throws {
        try exerciseQuit(menu: false, closeWindow: false, fullscreen: true)
    }

    private func exerciseQuit(menu: Bool, closeWindow: Bool, fullscreen: Bool) throws {
        let app = XCUIApplication()
        app.launchEnvironment["CLIO_UI_TESTING"] = "1"
        app.launchEnvironment["CLIO_UI_LAUNCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["CLIO_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["CLIO_UI_TEST_SCENARIO"] = "shutdown"
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        let reports = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        // A sandboxed Cloud runner cannot inspect the host's report directory.
        // Still exercise quit/persistence; record this coverage gap explicitly.
        let initialReports: Set<String>?
        do {
            initialReports = Set(try FileManager.default.contentsOfDirectory(atPath: reports.path))
        } catch {
            initialReports = nil
            let note = XCTAttachment(string: "Host crash reports unavailable to sandboxed runner. This test verifies quit completion and persistence only; review Cloud crash/sanitizer artifacts separately before release. Error code: \((error as NSError).code)")
            note.name = "Shutdown verification coverage limitation"
            note.lifetime = .keepAlways
            add(note)
        }
        var expected = "Alpha beta gamma\nSecond line\n"
        for iteration in 0..<3 {
            app.launch()
            XCTAssertEqual(app.state, .runningForeground)
            let editor = app.textViews["editor.text"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            XCTAssertEqual(editor.value as? String, expected, "Quit must preserve the last run's bytes")
            app.typeKey(.downArrow, modifierFlags: .command)
            let suffix = "Quit-cycle-\(iteration)\n"
            app.typeText(suffix)
            expected += suffix
            if fullscreen {
                app.typeKey("n", modifierFlags: [.command, .shift])
                XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 5))
                let window = app.windows.firstMatch
                let height = window.frame.height
                app.typeKey("f", modifierFlags: [.command, .control])
                let entered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in window.frame.height > height + 20 }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 10), .completed)
            }
            if closeWindow { app.typeKey("w", modifierFlags: .command) }
            // No Command-S or debounce wait: quit itself must flush the edit.
            if menu {
                app.menuBars.menuBarItems["Clio"].click()
                app.menuItems["Quit Clio"].click()
            } else { app.typeKey("q", modifierFlags: .command) }
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Quit must finish without force-termination")
            // Allow the OS reporter to publish an immediately generated report.
            let grace = Date().addingTimeInterval(3)
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= grace }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
            if let initialReports {
                let newReports = Set(try FileManager.default.contentsOfDirectory(atPath: reports.path)).subtracting(initialReports)
                XCTAssertTrue(newReports.filter { $0.hasPrefix("Clio-") && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }.isEmpty,
                              "A new Clio crash report appeared during intentional quit")
            }
        }
        app.launch()
        XCTAssertTrue(app.textViews["editor.text"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews["editor.text"].value as? String, expected)
    }
}

final class ClioLaunchUITests: ClioDiagnosticTestCase {
    func testLaunchReachesForegroundAndEditor() {
        let app = XCUIApplication()
        app.launchEnvironment["CLIO_UI_TESTING"] = "1"
        app.launchEnvironment["CLIO_UI_LAUNCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["CLIO_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["CLIO_UI_TEST_SCENARIO"] = "blank"
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.textViews["editor.text"].waitForExistence(timeout: 10))
    }
}
