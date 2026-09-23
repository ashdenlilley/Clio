import XCTest

/// Covers the surfaces the TypeSafe integration adds, at the level a writer
/// meets them: the Settings opt-in and the command palette's fallback.
///
/// The privacy contract is the thing being tested. Assisted commands are off on
/// a fresh launch, the key field only appears behind the opt-in, and a palette
/// query that matches nothing still shows nothing when the feature is off.
final class ClioIntelligenceUITests: ClioDiagnosticTestCase {
    private var app: XCUIApplication!

    override func tearDown() {
        app?.terminate()
        app = nil
        super.tearDown()
    }

    func testAssistedCommandsAreOffOnAFreshLaunchAndHideTheKeyField() {
        launch(scenario: "restoration")
        openSettings()

        let toggle = app.switches["settings.intelligence.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(
            toggle.value as? Int, 0,
            "A fresh install must not have assisted commands switched on"
        )
        XCTAssertFalse(
            app.secureTextFields["settings.intelligence.key"].exists,
            "The key field belongs behind the opt-in"
        )
        XCTAssertFalse(app.switches["settings.intelligence.formatPastes"].exists)
    }

    func testOptingInRevealsKeyEntryAndReportsNoKeyStored() {
        launch(scenario: "restoration")
        openSettings()

        let toggle = app.switches["settings.intelligence.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()

        let key = app.secureTextFields["settings.intelligence.key"]
        XCTAssertTrue(key.waitForExistence(timeout: 3), "Opting in must offer key entry")
        XCTAssertTrue(app.switches["settings.intelligence.formatPastes"].waitForExistence(timeout: 3))

        // With no key stored, the state line says so and offers no Check or
        // Remove, since there is nothing to check or remove.
        let state = app.descendants(matching: .any)["settings.intelligence.keyState"]
        XCTAssertTrue(state.waitForExistence(timeout: 3), "The stored-key state must be visible")
        // Identifiers, not titles: the Workspace section has a Remove of its own.
        XCTAssertFalse(
            app.buttons["settings.intelligence.checkKey"].exists,
            "Nothing to check without a stored key"
        )
        XCTAssertFalse(
            app.buttons["settings.intelligence.removeKey"].exists,
            "Nothing to remove without a stored key"
        )
    }

    func testPasteFormattingCanBeTurnedOffWithoutLeavingTheFeature() {
        launch(scenario: "restoration")
        openSettings()

        let toggle = app.switches["settings.intelligence.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()

        let pastes = app.switches["settings.intelligence.formatPastes"]
        XCTAssertTrue(pastes.waitForExistence(timeout: 3))
        XCTAssertEqual(pastes.value as? Int, 1, "Paste formatting defaults on behind the opt-in")
        pastes.click()
        XCTAssertEqual(pastes.value as? Int, 0)
        XCTAssertEqual(
            toggle.value as? Int, 1,
            "Turning off paste formatting must not turn off assisted commands"
        )
    }

    /// With the feature off, a request that matches no command name must still
    /// report no match, exactly as it did before assisted commands existed.
    func testUnmatchedPaletteQueryShowsNoMatchWhileTheFeatureIsOff() {
        launch(scenario: "restoration")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.typeKey("k", modifierFlags: .command)

        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        query.typeText("send this to my editor in Word")

        XCTAssertTrue(
            app.staticTexts["No matching command"].waitForExistence(timeout: 3),
            "Offline behaviour must be unchanged while the feature is off"
        )
        XCTAssertFalse(
            app.staticTexts["palette.intentHint"].exists,
            "No assisted match may be offered without the opt-in"
        )
    }

    func testTypingACommandNameStillFiltersLocally() {
        launch(scenario: "restoration")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.typeKey("k", modifierFlags: .command)

        let query = app.textFields["palette.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 3))
        query.typeText("export")

        XCTAssertTrue(
            app.buttons["palette.command.export"].waitForExistence(timeout: 3),
            "A literal match must still list the command it names"
        )
        XCTAssertFalse(
            app.staticTexts["palette.intentHint"].exists,
            "A literal match must never reach the network path"
        )
    }

    private func openSettings() {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.typeKey(",", modifierFlags: .command)
    }

    private func launch(scenario: String) {
        app = XCUIApplication()
        app.launchEnvironment["CLIO_UI_TESTING"] = "1"
        app.launchEnvironment["CLIO_UI_LAUNCH_DIAGNOSTICS"] = "1"
        app.launchEnvironment["CLIO_UI_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["CLIO_UI_TEST_SCENARIO"] = scenario
        app.launch()
        app.windows.firstMatch.hover()
    }
}
