import XCTest
@testable import Clio

@MainActor
final class EditorPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ClioTests.preferences.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Assigning any preference must return. This is the regression guard for a
    /// `didSet` that fed itself: a shared clamping helper taking the property
    /// as `inout` wrote back through `@Observable`'s `modify` accessor on every
    /// return, re-entering `didSet` unconditionally until the stack overflowed.
    /// Every assignment crashed, including in-range ones, so an ordinary
    /// preference change took the whole app down.
    func testAssigningAPreferenceTerminates() {
        let preferences = EditorPreferences(defaults: defaults)

        preferences.fontSize = 18
        preferences.measure = 84
        preferences.lineHeight = 1.5
        preferences.typewriterAnchor = 0.5
        preferences.focusDimmingOpacity = 0.3
        preferences.editorFontName = "Helvetica"
        preferences.accent = .cyan
        preferences.isFocusModeEnabled = false

        XCTAssertEqual(preferences.fontSize, 18)
        XCTAssertEqual(preferences.measure, 84)
        XCTAssertEqual(preferences.lineHeight, 1.5)
        XCTAssertEqual(preferences.typewriterAnchor, 0.5)
        XCTAssertEqual(preferences.focusDimmingOpacity, 0.3)
        XCTAssertEqual(preferences.editorFontName, "Helvetica")
        XCTAssertEqual(preferences.accent, .cyan)
        XCTAssertFalse(preferences.isFocusModeEnabled)
    }

    /// Setting the same value repeatedly must also terminate, since that is the
    /// path where a clamp changes nothing and the guard does the work.
    func testReassigningTheSameValueTerminates() {
        let preferences = EditorPreferences(defaults: defaults)
        for _ in 0..<50 { preferences.fontSize = 16 }
        XCTAssertEqual(preferences.fontSize, 16)
    }

    func testOutOfRangeValuesAreClampedOnAssignment() {
        let preferences = EditorPreferences(defaults: defaults)

        preferences.fontSize = 999
        XCTAssertEqual(preferences.fontSize, EditorPreferences.Limits.fontSize.upperBound)
        preferences.fontSize = -5
        XCTAssertEqual(preferences.fontSize, EditorPreferences.Limits.fontSize.lowerBound)

        preferences.measure = 5_000
        XCTAssertEqual(preferences.measure, EditorPreferences.Limits.measure.upperBound)

        preferences.lineHeight = 0
        XCTAssertEqual(preferences.lineHeight, EditorPreferences.Limits.lineHeight.lowerBound)

        preferences.typewriterAnchor = 9
        XCTAssertEqual(preferences.typewriterAnchor, EditorPreferences.Limits.typewriterAnchor.upperBound)

        preferences.focusDimmingOpacity = -1
        XCTAssertEqual(
            preferences.focusDimmingOpacity,
            EditorPreferences.Limits.focusDimmingOpacity.lowerBound
        )
    }

    /// A clamped assignment must persist the clamped value, not the value that
    /// was asked for, or the next launch would load something out of range.
    func testAClampedValueIsWhatGetsPersisted() {
        let preferences = EditorPreferences(defaults: defaults)
        preferences.fontSize = 999

        let reloaded = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.fontSize, EditorPreferences.Limits.fontSize.upperBound)
    }

    func testValuesRoundTripThroughDefaults() {
        let preferences = EditorPreferences(defaults: defaults)
        preferences.fontSize = 17
        preferences.measure = 80
        preferences.lineHeight = 1.4
        preferences.typewriterAnchor = 0.55
        preferences.focusDimmingOpacity = 0.4
        preferences.editorFontName = "Menlo"
        preferences.accent = .green
        preferences.isSpellCheckingEnabled = false
        preferences.isTypewriterModeEnabled = false
        preferences.isFocusModeEnabled = false
        preferences.isChromeFadeEnabled = false

        let reloaded = EditorPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.fontSize, 17)
        XCTAssertEqual(reloaded.measure, 80)
        XCTAssertEqual(reloaded.lineHeight, 1.4)
        XCTAssertEqual(reloaded.typewriterAnchor, 0.55)
        XCTAssertEqual(reloaded.focusDimmingOpacity, 0.4)
        XCTAssertEqual(reloaded.editorFontName, "Menlo")
        XCTAssertEqual(reloaded.accent, .green)
        XCTAssertFalse(reloaded.isSpellCheckingEnabled)
        XCTAssertFalse(reloaded.isTypewriterModeEnabled)
        XCTAssertFalse(reloaded.isFocusModeEnabled)
        XCTAssertFalse(reloaded.isChromeFadeEnabled)
    }

    /// A value already out of range in `UserDefaults` - written by an older
    /// build, a defaults import, or `defaults write` - must not reach the editor.
    func testStoredOutOfRangeValuesAreClampedOnLoad() {
        defaults.set(400.0, forKey: EditorPreferences.Keys.fontSize)
        defaults.set(-10, forKey: EditorPreferences.Keys.measure)

        let preferences = EditorPreferences(defaults: defaults)
        XCTAssertEqual(preferences.fontSize, EditorPreferences.Limits.fontSize.upperBound)
        XCTAssertEqual(preferences.measure, EditorPreferences.Limits.measure.lowerBound)
    }

    func testAnUnreadableAccentFallsBackRatherThanFailing() {
        defaults.set("not-a-real-accent", forKey: EditorPreferences.Keys.accent)
        XCTAssertEqual(EditorPreferences(defaults: defaults).accent, .clio)
    }

    func testAnEmptyFontNameFallsBackToTheDefault() {
        let preferences = EditorPreferences(defaults: defaults)
        preferences.editorFontName = "   "
        XCTAssertEqual(preferences.editorFontName, EditorPreferences.Defaults.editorFontName)
    }

    func testAdjustingFontSizeStaysWithinLimits() {
        let preferences = EditorPreferences(defaults: defaults)
        for _ in 0..<40 { preferences.adjustFontSize(by: 1) }
        XCTAssertEqual(preferences.fontSize, EditorPreferences.Limits.fontSize.upperBound)

        for _ in 0..<40 { preferences.adjustFontSize(by: -1) }
        XCTAssertEqual(preferences.fontSize, EditorPreferences.Limits.fontSize.lowerBound)

        preferences.resetFontSize()
        XCTAssertEqual(preferences.fontSize, EditorPreferences.Defaults.fontSize)
    }

    /// The forwarding properties on `AppState` must reach the same storage, so
    /// existing call sites and `$appState` bindings keep working.
    func testAppStateForwardsToTheSameStorage() {
        let state = isolatedAppState(defaults: defaults)
        state.fontSize = 19
        XCTAssertEqual(state.preferences.fontSize, 19)

        state.preferences.accent = .amber
        XCTAssertEqual(state.accent, .amber)

        state.adjustFontSize(by: 100)
        XCTAssertEqual(state.fontSize, EditorPreferences.Limits.fontSize.upperBound)
    }

    func testNewEditorPreferencesDefaultToCurrentBehaviour() {
        let p = EditorPreferences(defaults: defaults)
        XCTAssertEqual(p.caretStyle, .block)
        XCTAssertTrue(p.showsMinimap)
        XCTAssertTrue(p.showsStatusLine)
        XCTAssertTrue(p.showsReadingTime)
        XCTAssertTrue(p.showsSpeakingTime)
        XCTAssertTrue(p.hidesPointerWhileTyping)
        XCTAssertFalse(p.isGrammarCheckingEnabled)
        XCTAssertFalse(p.isSmartPunctuationEnabled)
        XCTAssertTrue(p.isSlashCommandEnabled)
        XCTAssertTrue(p.autoWrapsSelection)
    }

    func testNewEditorPreferencesRoundTrip() {
        let p = EditorPreferences(defaults: defaults)
        p.caretStyle = .line
        p.showsMinimap = false
        p.showsStatusLine = false
        p.showsReadingTime = false
        p.showsSpeakingTime = false
        p.hidesPointerWhileTyping = false
        p.isGrammarCheckingEnabled = true
        p.isSmartPunctuationEnabled = true
        p.isSlashCommandEnabled = false
        p.autoWrapsSelection = false
        let r = EditorPreferences(defaults: defaults)
        XCTAssertEqual(r.caretStyle, .line)
        XCTAssertFalse(r.showsMinimap)
        XCTAssertFalse(r.showsStatusLine)
        XCTAssertFalse(r.showsReadingTime)
        XCTAssertFalse(r.showsSpeakingTime)
        XCTAssertFalse(r.hidesPointerWhileTyping)
        XCTAssertTrue(r.isGrammarCheckingEnabled)
        XCTAssertTrue(r.isSmartPunctuationEnabled)
        XCTAssertFalse(r.isSlashCommandEnabled)
        XCTAssertFalse(r.autoWrapsSelection)
    }

    func testUnknownCaretStyleFallsBackToBlock() {
        defaults.set("bar", forKey: EditorPreferences.Keys.caretStyle)
        XCTAssertEqual(EditorPreferences(defaults: defaults).caretStyle, .block)
    }

    func testAmberAndOrangeAreDistinctColours() {
        let amber = EditorPreferences.AccentPreset.amber.nsColor.usingColorSpace(.sRGB)!
        let orange = EditorPreferences.AccentPreset.orange.nsColor.usingColorSpace(.sRGB)!
        XCTAssertNotEqual(amber, orange)
    }
}
