import AppKit
import XCTest
@testable import Clio

@MainActor
final class EditorBehaviourPreferencesTests: XCTestCase {
    private func makeTextView(_ configuration: EditorConfiguration) -> EditorTextView {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.applyEditorConfiguration(configuration)
        return view
    }

    func testDefaultsKeepSubstitutionsOff() {
        let view = makeTextView(EditorConfiguration())
        XCTAssertFalse(view.isGrammarCheckingEnabled)
        XCTAssertFalse(view.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(view.isAutomaticDashSubstitutionEnabled)
        XCTAssertEqual(view.caretStyle, .block)
        XCTAssertTrue(view.autoWrapsSelection)
    }

    func testPreferencesReachTheTextView() {
        var configuration = EditorConfiguration()
        configuration.isGrammarCheckingEnabled = true
        configuration.isSmartPunctuationEnabled = true
        configuration.caretStyle = .line
        configuration.autoWrapsSelection = false
        let view = makeTextView(configuration)
        XCTAssertTrue(view.isGrammarCheckingEnabled)
        XCTAssertTrue(view.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertTrue(view.isAutomaticDashSubstitutionEnabled)
        XCTAssertEqual(view.caretStyle, .line)
        XCTAssertFalse(view.autoWrapsSelection)
    }

    func testTypingAMarkerOverASelectionReplacesItWhenAutoWrapIsOff() {
        var configuration = EditorConfiguration()
        configuration.autoWrapsSelection = false
        let view = makeTextView(configuration)
        view.string = "word"
        var wrapped = false
        view.onMarkdownAction = { action in
            if case .wrap = action { wrapped = true; return true }
            return false
        }
        view.setSelectedRange(NSRange(location: 0, length: 4))
        view.insertText("*", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(wrapped)
        XCTAssertEqual(view.string, "*")
    }

    func testStatusLineTextHonoursToggles() {
        XCTAssertEqual(
            StatusLineText.statistics(wordCountLabel: "10 words", wordCount: 10, showsReadingTime: true, showsSpeakingTime: true),
            "10 words · Read \(WritingTime.label(words: 10, wordsPerMinute: 250)) · Speak \(WritingTime.label(words: 10, wordsPerMinute: 140))"
        )
        XCTAssertEqual(
            StatusLineText.statistics(wordCountLabel: "10 words", wordCount: 10, showsReadingTime: false, showsSpeakingTime: false),
            "10 words"
        )
        XCTAssertEqual(
            StatusLineText.statistics(wordCountLabel: "10 words", wordCount: 10, showsReadingTime: false, showsSpeakingTime: true),
            "10 words · Speak \(WritingTime.label(words: 10, wordsPerMinute: 140))"
        )
    }

    /// Ruling: `testSlashIsLiteralWithoutAHandler` from the brief only asserted
    /// `XCTAssertNotNil` on a view host and exercised nothing. `EditorCoordinator`
    /// already exposes a real seam for this decision: `textView(_:shouldChangeTextIn:replacementString:)`
    /// (the `NSTextViewDelegate` callback) is internal, and its slash branch is
    /// gated by `onSlashCommand != nil` before it ever consults
    /// `isInlineSlashTrigger`. Calling it directly with a nil handler exercises
    /// the exact decision the coordinator makes when typing "/", without needing
    /// a live window or key event simulation.
    func testSlashIsLiteralWithoutAHandler() {
        let view = makeTextView(EditorConfiguration())
        view.string = ""
        let coordinator = EditorCoordinator(
            configuration: EditorConfiguration(),
            onTextEdit: { _ in },
            onSlashCommand: nil
        )
        let allowsLiteralInsertion = coordinator.textView(
            view,
            shouldChangeTextIn: NSRange(location: 0, length: 0),
            replacementString: "/"
        )
        XCTAssertTrue(allowsLiteralInsertion, "with no handler, AppKit must be allowed to insert \"/\" itself")
    }
}
