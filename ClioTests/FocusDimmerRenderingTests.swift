import AppKit
import XCTest
@testable import Clio

@MainActor
final class FocusDimmerRenderingTests: XCTestCase {
    private func makeTextView(_ text: String) -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        textView.string = text
        return textView
    }

    /// Foreground colour TextKit 2 will render at `offset`, or nil if no
    /// rendering attribute overrides the text storage's own colour.
    private func renderedForeground(at offset: Int, in textView: NSTextView) -> NSColor? {
        let layoutManager = textView.textLayoutManager!
        let contentStorage = textView.textContentStorage!
        let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: offset)!
        let end = contentStorage.location(start, offsetBy: 1)!
        var color: NSColor?
        layoutManager.enumerateRenderingAttributes(
            from: start, reverse: false
        ) { _, attributes, range in
            if range.location.compare(end) != .orderedAscending { return false }
            color = attributes[.foregroundColor] as? NSColor
            return false
        }
        return color
    }

    func testFocusedParagraphIsNotDimmedAfterCaretMoves() {
        let text = "first paragraph\n\nsecond paragraph\n\nthird paragraph"
        let source = text as NSString
        let textView = makeTextView(text)
        let dimmer = FocusDimmer()
        let configuration = EditorConfiguration()

        textView.setSelectedRange(NSRange(location: source.range(of: "second").location, length: 0))
        dimmer.apply(to: textView, configuration: configuration)
        XCTAssertNotNil(renderedForeground(at: source.range(of: "first").location, in: textView))
        XCTAssertNil(renderedForeground(at: source.range(of: "second").location, in: textView))

        textView.setSelectedRange(NSRange(location: source.range(of: "first").location, length: 0))
        dimmer.apply(to: textView, configuration: configuration)
        XCTAssertNil(
            renderedForeground(at: source.range(of: "first").location, in: textView),
            "the focused paragraph must not keep a dimming attribute"
        )
        XCTAssertNotNil(renderedForeground(at: source.range(of: "second").location, in: textView))
    }

    func testSuppressedFocusRemovesEveryDimmingAttribute() {
        let text = "first paragraph\n\nsecond paragraph"
        let source = text as NSString
        let textView = makeTextView(text)
        let dimmer = FocusDimmer()
        let configuration = EditorConfiguration()

        textView.setSelectedRange(NSRange(location: source.range(of: "second").location, length: 0))
        dimmer.apply(to: textView, configuration: configuration)
        XCTAssertNotNil(renderedForeground(at: 0, in: textView))

        textView.setSelectedRange(NSRange(location: 0, length: source.length))
        dimmer.apply(to: textView, configuration: configuration)
        XCTAssertNil(renderedForeground(at: 0, in: textView))
    }

    func testFocusedParagraphStaysBrightAfterTypingInIt() {
        let text = "# Title\n\nfirst paragraph\n\nsecond paragraph"
        let source = text as NSString
        let textView = makeTextView(text)
        let dimmer = FocusDimmer()
        let configuration = EditorConfiguration()

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        dimmer.apply(to: textView, configuration: configuration)
        XCTAssertNil(renderedForeground(at: 0, in: textView))
        XCTAssertNotNil(renderedForeground(at: source.range(of: "first").location, in: textView))

        // Mirror EditorCoordinator: clear before the edit, apply after.
        dimmer.clear(in: textView)
        textView.textStorage!.replaceCharacters(in: NSRange(location: 7, length: 0), with: "s")
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        dimmer.apply(to: textView, configuration: configuration)

        XCTAssertNil(renderedForeground(at: 0, in: textView), "typed-in heading is dimmed")
        XCTAssertNil(renderedForeground(at: 7, in: textView), "typed character is dimmed")
        let updated = textView.string as NSString
        XCTAssertNotNil(renderedForeground(at: updated.range(of: "first").location, in: textView))
    }

    func testFocusedParagraphStaysBrightAfterHighlighterRewritesAttributes() {
        let text = "# Title\n\nfirst paragraph\n\nsecond paragraph"
        let source = text as NSString
        let textView = makeTextView(text)
        let dimmer = FocusDimmer()
        let configuration = EditorConfiguration()

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        dimmer.apply(to: textView, configuration: configuration)

        // Mirror the async highlighter pass: attribute-only edits over the document.
        let storage = textView.textStorage!
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: source.length))
        storage.addAttribute(.foregroundColor, value: NSColor.gray, range: NSRange(location: 0, length: 1))
        storage.endEditing()
        dimmer.apply(to: textView, configuration: configuration)

        XCTAssertNil(renderedForeground(at: 0, in: textView), "focused heading is dimmed")
        XCTAssertNotNil(renderedForeground(at: source.range(of: "first").location, in: textView))
        XCTAssertNotNil(renderedForeground(at: source.range(of: "second").location, in: textView))
    }

    /// Full editor stack: real text view, window, coordinator and async highlighter.
    func testFocusedParagraphIsNotDimmedInTheRealEditor() async throws {
        let text = "# Title\n\nfirst **bold** paragraph\n\nsecond paragraph\n\nthird paragraph"
        let textView = EditorTextView.makeTextKit2TextView()
        let surface = EditorContainerView(textView: textView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        let configuration = EditorConfiguration()
        let coordinator = EditorCoordinator(configuration: configuration, onTextEdit: { _ in })
        coordinator.attach(to: surface)
        coordinator.update(text: text, contentGeneration: BufferGeneration(),
                           configuration: configuration, onTextEdit: { _ in })
        window.makeFirstResponder(textView)

        let source = text as NSString
        textView.setSelectedRange(NSRange(location: source.range(of: "first").location, length: 0))
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertNil(renderedForeground(at: source.range(of: "first").location, in: textView),
                     "focused paragraph dimmed after highlight settled")
        XCTAssertNotNil(renderedForeground(at: source.range(of: "second").location, in: textView))

        textView.insertText("X", replacementRange: NSRange(location: source.range(of: "first").location, length: 0))
        try await Task.sleep(nanoseconds: 800_000_000)
        let typed = textView.string as NSString
        XCTAssertNil(renderedForeground(at: typed.range(of: "Xfirst").location, in: textView),
                     "typed paragraph dimmed")
        XCTAssertNil(renderedForeground(at: typed.range(of: "bold").location, in: textView),
                     "later part of typed paragraph dimmed")
        XCTAssertNotNil(renderedForeground(at: typed.range(of: "second").location, in: textView))
        withExtendedLifetime(coordinator) {}
    }

    /// A document that opens with a blank line puts the caret on that blank
    /// line. The focus unit there is empty, so every real paragraph used to be
    /// dimmed and nothing on screen was bright.
    func testCaretOnBlankLineLeavesTheDocumentUndimmed() {
        let text = "\n# Title\n\nfirst paragraph\n\nsecond paragraph"
        let source = text as NSString
        let textView = makeTextView(text)
        let dimmer = FocusDimmer()
        let configuration = EditorConfiguration()

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        dimmer.apply(to: textView, configuration: configuration)
        for needle in ["Title", "first", "second"] {
            XCTAssertNil(renderedForeground(at: source.range(of: needle).location, in: textView), needle)
        }

        // Starting a paragraph on a blank line between two others.
        textView.setSelectedRange(NSRange(location: source.range(of: "first").location, length: 0))
        dimmer.apply(to: textView, configuration: configuration)
        XCTAssertNotNil(renderedForeground(at: source.range(of: "second").location, in: textView))
        let blank = source.range(of: "first paragraph\n\n").upperBound - 1
        textView.setSelectedRange(NSRange(location: blank, length: 0))
        dimmer.apply(to: textView, configuration: configuration)
        XCTAssertNil(renderedForeground(at: source.range(of: "second").location, in: textView))
    }
}
