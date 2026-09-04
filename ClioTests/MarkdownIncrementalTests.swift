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
        let incremental = try await engine.update(edit: edit)
        let full = try await SourcePreservingMarkdownParser.parse(source: newSource)

        XCTAssertLessThan(incremental.parsedUTF16Length, (newSource as NSString).length)
        XCTAssertEqual(incremental.spans, full.spans)
    }

    func testStructuralInsertionsAndDeletionsImmediatelyMatchFullParse() async throws {
        let pairs: [(plain: String, structural: String)] = [
            ("alpha\nbeta\n", "alpha\n\nbeta\n"),
            ("code\nbody\n", "```\ncode\n```\nbody\n"),
            ("A B\nrule\n1 2\n", "| A | B |\n| --- | --- |\n| 1 | 2 |\n"),
            ("item\nnext\n", "- item\n- next\n"),
            ("Title\nbody\n", "Title\n=====\nbody\n"),
            ("title: Clio\n\nbody\n", "---\ntitle: Clio\n---\n\nbody\n"),
        ]

        for pair in pairs {
            for (before, after) in [(pair.plain, pair.structural), (pair.structural, pair.plain)] {
                let engine = IncrementalMarkdownHighlighter()
                _ = try await engine.update(source: before)
                let edit = contiguousEdit(from: before, to: after)
                let update = try await engine.update(source: after, edit: edit)
                let full = try await SourcePreservingMarkdownParser.parse(source: after)

                XCTAssertEqual(update.spans, full.spans, "Diverged for \(before) → \(after)")
                XCTAssertEqual(update.invalidatedRange, UTF16Range(
                    location: 0,
                    length: (after as NSString).length
                ))
            }
        }
    }

    func testDiscontinuousEditFallsBackWithoutWholeSourceReconstruction() async throws {
        let source = "First *one*.\n\nSecond **two**.\n"
        let engine = IncrementalMarkdownHighlighter()
        _ = try await engine.update(source: source)
        let lie = MarkdownTextEdit(
            replacedRange: (source as NSString).range(of: "one").utf16,
            replacement: "six"
        )
        let unrelated = source.replacingOccurrences(of: "two", with: "ten")
        let update = try await engine.update(source: unrelated, edit: lie)
        let full = try await SourcePreservingMarkdownParser.parse(source: unrelated)

        XCTAssertEqual(update.invalidatedRange.length, (unrelated as NSString).length)
        XCTAssertEqual(update.spans, full.spans)
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

    @MainActor
    func testTextKitResetsExactlyInvalidatedUnion() async throws {
        let source = "Before plain.\n\nMiddle *one*.\n\nAfter plain.\n"
        let engine = IncrementalMarkdownHighlighter()
        _ = try await engine.update(source: source)
        let oldRange = (source as NSString).range(of: "one")
        let changed = NSMutableString(string: source)
        changed.replaceCharacters(in: oldRange, with: "longer")
        let newSource = changed as String
        let update = try await engine.update(
            source: newSource,
            edit: MarkdownTextEdit(replacedRange: oldRange.utf16, replacement: "longer")
        )
        let textView = EditorTextView.makeTextKit2TextView()
        textView.string = newSource
        textView.textStorage?.addAttribute(
            .foregroundColor,
            value: NSColor.systemGreen,
            range: NSRange(location: 0, length: (newSource as NSString).length)
        )

        MarkdownTextKitHighlighter().apply(
            update,
            to: textView,
            configuration: EditorConfiguration()
        )

        let before = (newSource as NSString).range(of: "Before").location
        XCTAssertFalse(update.invalidatedRange.contains(before))
        XCTAssertEqual(
            textView.textStorage?.attribute(.foregroundColor, at: before, effectiveRange: nil) as? NSColor,
            .systemGreen
        )
        XCTAssertNotEqual(
            textView.textStorage?.attribute(.foregroundColor, at: oldRange.location, effectiveRange: nil) as? NSColor,
            .systemGreen
        )
    }

    private func contiguousEdit(from oldValue: String, to newValue: String) -> MarkdownTextEdit {
        let old = oldValue as NSString
        let new = newValue as NSString
        var prefix = 0
        while prefix < old.length, prefix < new.length,
              old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.length - prefix, suffix < new.length - prefix,
              old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) {
            suffix += 1
        }
        return MarkdownTextEdit(
            replacedRange: UTF16Range(location: prefix, length: old.length - prefix - suffix),
            replacement: new.substring(with: NSRange(
                location: prefix,
                length: new.length - prefix - suffix
            ))
        )
    }
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }
}

private extension UTF16Range {
    var nsRange: NSRange { NSRange(location: location, length: length) }

    func contains(_ offset: Int) -> Bool {
        offset >= location && offset < upperBound
    }
}
