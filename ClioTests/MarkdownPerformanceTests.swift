import AppKit
import XCTest
@testable import Clio

final class MarkdownPerformanceTests: XCTestCase {
    func testIncrementalHighlightingWorkIsBoundedToEditedIsland() async throws {
        let block = "Paragraph with **strong** and [link](https://example.com).\n\n"
        let source = String(repeating: block, count: 32_000) + "Unique *needle* here.\n"
        let engine = IncrementalMarkdownHighlighter()
        _ = try await engine.update(source: source)
        let oldRange = (source as NSString).range(of: "needle")
        let edit = MarkdownTextEdit(replacedRange: oldRange.utf16, replacement: "thread")
        let changed = NSMutableString(string: source)
        changed.replaceCharacters(in: oldRange, with: "thread")

        let clock = ContinuousClock()
        let start = clock.now
        let update = try await engine.update(source: changed as String, edit: edit)
        let elapsed = start.duration(to: clock.now)

        XCTAssertLessThan(update.parsedUTF16Length, 512)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertTrue(update.spans.contains { $0.kind == .emphasis })
    }

    func testCancelledParseDoesNotPublishPartialResult() async {
        let source = String(repeating: "line with **syntax**\n", count: 100_000)
        let task = Task {
            try await SourcePreservingMarkdownParser.parse(source: source)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: callers retain their previously applied generation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelledInFlightHighlightDoesNotPublishUpdate() async {
        let source = String(repeating: "```swift\nlet value = 42\n```\n", count: 180_000)
        let engine = IncrementalMarkdownHighlighter()
        let task = Task { try await engine.update(source: source) }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected in-flight cancellation")
        } catch is CancellationError {
            // The actor retains its last fully published generation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testRepresentativeIncrementalTextKitApplyStaysInteractive() async throws {
        let block = "Paragraph with **strong** and [link](https://example.com).\n\n"
        let source = String(repeating: block, count: 4_000) + "Tail *needle*.\n"
        let engine = IncrementalMarkdownHighlighter()
        _ = try await engine.update(source: source)
        let range = (source as NSString).range(of: "needle")
        let changed = NSMutableString(string: source)
        changed.replaceCharacters(in: range, with: "thread")
        let update = try await engine.update(
            source: changed as String,
            edit: MarkdownTextEdit(replacedRange: range.utf16, replacement: "thread")
        )
        let textView = EditorTextView.makeTextKit2TextView()
        textView.string = changed as String
        let highlighter = MarkdownTextKitHighlighter()
        let clock = ContinuousClock()
        let start = clock.now

        highlighter.apply(update, to: textView, configuration: EditorConfiguration())

        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
        XCTAssertEqual(textView.string, changed as String)
    }
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }
}
