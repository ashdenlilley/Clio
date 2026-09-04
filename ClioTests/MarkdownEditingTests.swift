import AppKit
import XCTest
@testable import Clio

final class MarkdownEditingTests: XCTestCase {
    func testListContinuationIncrementsOrderedMarker() throws {
        let source = "9) ninth"
        let edit = try XCTUnwrap(MarkdownEditEngine.newline(
            in: source,
            selection: UTF16Range(location: (source as NSString).length, length: 0)
        ))
        XCTAssertEqual(edit.replacement, "\n10) ")
        XCTAssertEqual(apply(edit, to: source), "9) ninth\n10) ")
    }

    func testTaskContinuationResetsCheckboxAndRetainsQuotePrefix() throws {
        let source = "> - [x] shipped"
        let edit = try XCTUnwrap(MarkdownEditEngine.newline(
            in: source,
            selection: UTF16Range(location: (source as NSString).length, length: 0)
        ))
        XCTAssertEqual(edit.replacement, "\n> - [ ] ")
    }

    func testReturnOnEmptyItemEndsList() throws {
        let source = "- "
        let edit = try XCTUnwrap(MarkdownEditEngine.newline(
            in: source,
            selection: UTF16Range(location: 2, length: 0)
        ))
        XCTAssertEqual(apply(edit, to: source), "")
        XCTAssertEqual(edit.actionName, "End List")
    }

    func testNestedListContinuationAndEmptyItemOutdentOneLevel() throws {
        let populated = "    - nested"
        let continuation = try XCTUnwrap(MarkdownEditEngine.newline(
            in: populated,
            selection: UTF16Range(location: (populated as NSString).length, length: 0)
        ))
        XCTAssertEqual(continuation.replacement, "\n    - ")

        let empty = "        - "
        let outdent = try XCTUnwrap(MarkdownEditEngine.newline(
            in: empty,
            selection: UTF16Range(location: (empty as NSString).length, length: 0)
        ))
        XCTAssertEqual(apply(outdent, to: empty), "    ")
    }

    func testWrapPreservesUnicodeSelectionOffsets() {
        let source = "Write 世界 now"
        let selected = (source as NSString).range(of: "世界")
        let edit = MarkdownEditEngine.wrap(.strong, in: source, selection: selected.utf16)

        XCTAssertEqual(apply(edit, to: source), "Write **世界** now")
        XCTAssertEqual(edit.selectionAfter.length, selected.length)
        XCTAssertEqual(edit.selectionAfter.location, selected.location + 2)
    }

    func testSmartURLPasteLinksSelectionAndRejectsUnsafeSchemes() throws {
        let source = "Clio website"
        let selection = (source as NSString).range(of: "website").utf16
        let safe = try XCTUnwrap(MarkdownEditEngine.smartPaste(
            "https://example.com/path?q=1",
            in: source,
            selection: selection
        ))
        XCTAssertEqual(apply(safe, to: source), "Clio [website](https://example.com/path?q=1)")
        XCTAssertNil(MarkdownEditEngine.smartPaste(
            "javascript:alert(1)",
            in: source,
            selection: selection
        ))
    }

    func testIndentAndOutdentAreInverseForSelectedLines() throws {
        let source = "- one\n- two\n"
        let selection = UTF16Range(location: 0, length: (source as NSString).length)
        let indented = try XCTUnwrap(MarkdownEditEngine.indent(
            .indent,
            in: source,
            selection: selection
        ))
        let indentedSource = apply(indented, to: source)
        XCTAssertEqual(indentedSource, "    - one\n    - two\n")
        let outdented = try XCTUnwrap(MarkdownEditEngine.indent(
            .outdent,
            in: indentedSource,
            selection: UTF16Range(location: 0, length: (indentedSource as NSString).length)
        ))
        XCTAssertEqual(apply(outdented, to: indentedSource), source)
    }

    func testTabOutsideListInsertsSpacesAtCaret() throws {
        let source = "plain"
        let edit = try XCTUnwrap(MarkdownEditEngine.indent(
            .indent,
            in: source,
            selection: UTF16Range(location: 2, length: 0)
        ))
        XCTAssertEqual(apply(edit, to: source), "pl    ain")
    }

    func testListIndentKeepsCaretCollapsed() throws {
        let source = "- item"
        let edit = try XCTUnwrap(MarkdownEditEngine.indent(
            .indent,
            in: source,
            selection: UTF16Range(location: 4, length: 0)
        ))
        XCTAssertEqual(apply(edit, to: source), "    - item")
        XCTAssertEqual(edit.selectionAfter, UTF16Range(location: 8, length: 0))
    }

    @MainActor
    func testTypingMarkerWrapsSelectionInsteadOfReplacingIt() {
        let textView = EditorTextView.makeTextKit2TextView()
        textView.applyEditorConfiguration(EditorConfiguration())
        textView.string = "draft"
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        let controller = MarkdownEditingController()
        textView.onMarkdownAction = { action in
            controller.perform(action, in: textView)
        }

        textView.insertText("_", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(textView.string, "_draft_")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 5))
    }

    @MainActor
    func testEditingControllerCreatesOneCoherentUndoAction() {
        let textView = EditorTextView.makeTextKit2TextView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView
        textView.applyEditorConfiguration(EditorConfiguration())
        textView.string = "draft"
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        let controller = MarkdownEditingController()

        XCTAssertTrue(controller.perform(.wrap(.strong), in: textView))
        XCTAssertEqual(textView.string, "**draft**")
        XCTAssertTrue(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "draft")
    }

    private func apply(_ edit: MarkdownEditTransaction, to source: String) -> String {
        let value = NSMutableString(string: source)
        value.replaceCharacters(in: edit.replacementRange.nsRange, with: edit.replacement)
        return value as String
    }
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }
}

private extension UTF16Range {
    var nsRange: NSRange { NSRange(location: location, length: length) }
}
