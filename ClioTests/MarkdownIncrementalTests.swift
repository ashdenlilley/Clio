import AppKit
import XCTest
@testable import Clio

final class MarkdownIncrementalTests: XCTestCase {
    func testInvalidationExpandsToBlockBoundariesInUTF16() {
        let source = "first\nline\n\nsecond 👩🏽‍💻 line\nmore\n\nthird\n"
        let range = (source as NSString).range(of: "👩🏽‍💻")
        let invalidation = MarkdownInvalidationPlanner.ranges(
            for: MarkdownTextEdit(replacedRange: range.utf16, replacement: "Clio"),
            in: source
        )
        let oldText = (source as NSString).substring(with: invalidation.oldRange.nsRange)

        XCTAssertTrue(oldText.contains("second"))
        XCTAssertTrue(oldText.contains("more"))
        XCTAssertLessThan(invalidation.oldRange.length, (source as NSString).length)
    }

    func testIncrementalEditReparsesOnlyBlockIslandAndMatchesFullSpans() async throws {
        let source = "# First\n\nAlpha *one*.\nSecond line.\n\nBeta **two**.\n\nEnd [link](https://a.co).\n"
        let engine = IncrementalMarkdownHighlighter()
        let initial = try await engine.update(source: source)
        XCTAssertEqual(initial.parsedUTF16Length, (source as NSString).length)

        let oldRange = (source as NSString).range(of: "one")
        let edit = MarkdownTextEdit(replacedRange: oldRange.utf16, replacement: "world")
        let changed = NSMutableString(string: source)
        changed.replaceCharacters(in: oldRange, with: "world")
        let newSource = changed as String
        let incremental = try await engine.update(source: newSource, edit: edit)
        let full = try await SourcePreservingMarkdownParser.parse(source: newSource)

        XCTAssertLessThan(incremental.parsedUTF16Length, (newSource as NSString).length)
        XCTAssertEqual(Set(incremental.spans), Set(full.spans))
    }

    func testInsertionShiftsUnaffectedSpanRanges() async throws {
        let source = "*one*\n\n**two**\n"
        let engine = IncrementalMarkdownHighlighter()
        _ = try await engine.update(source: source)
        let edit = MarkdownTextEdit(
            replacedRange: UTF16Range(location: 0, length: 0),
            replacement: "Prefix\n\n"
        )
        let newSource = "Prefix\n\n" + source
        let update = try await engine.update(source: newSource, edit: edit)
        let strong = try XCTUnwrap(update.spans.first { $0.kind == .strong && $0.role == .content })
        XCTAssertEqual((newSource as NSString).substring(with: strong.range.nsRange), "two")
    }

    @MainActor
    func testTextKitHighlightingChangesAttributesButNeverCharacters() async throws {
        let source = "# **Clio**"
        let update = try await IncrementalMarkdownHighlighter().update(source: source)
        let textView = EditorTextView.makeTextKit2TextView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        textView.applyEditorConfiguration(EditorConfiguration())
        textView.string = source
        textView.undoManager?.removeAllActions()
        let highlighter = MarkdownTextKitHighlighter()

        highlighter.apply(update, to: textView, configuration: EditorConfiguration())

        XCTAssertEqual(textView.string, source)
        let hashRange = (source as NSString).range(of: "#")
        XCTAssertEqual(
            textView.textStorage?.attribute(.foregroundColor, at: hashRange.location, effectiveRange: nil) as? NSColor,
            Palette.marker
        )
        XCTAssertFalse(textView.undoManager?.canUndo == true)
    }
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }
}

private extension UTF16Range {
    var nsRange: NSRange { NSRange(location: location, length: length) }
}
