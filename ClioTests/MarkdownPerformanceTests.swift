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
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }
}
