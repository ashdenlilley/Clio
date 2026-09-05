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
