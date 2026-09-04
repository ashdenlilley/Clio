import AppKit
import Darwin
import XCTest
@testable import Clio

final class MarkdownPerformanceTests: XCTestCase {
    @MainActor
    func testDenseParseKeepsMainActorHeartbeatResponsiveAndCancelsPromptly() async throws {
        let block = "## heading\n\nParagraph with **strong** and [link](https://example.com).\n\n"
        let source = String(repeating: block, count: 32_000)
        let parse = Task { try await SourcePreservingMarkdownParser.parse(source: source) }

        var heartbeats = 0
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(15))
            heartbeats += 1
        }

        let clock = ContinuousClock()
        let cancellationStarted = clock.now
        parse.cancel()
        do {
            _ = try await parse.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // The abandoned cmark generation is contained by the parser pool.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(heartbeats, 8)
        XCTAssertLessThan(
            cancellationStarted.duration(to: clock.now),
            .milliseconds(250)
        )
    }

    func testSafeLargeDenseInputStopsAtComplexityBudgetWithBoundedRSS() async throws {
        let byteCount = PerformanceContract.safeLargeFileByteLimit
        let unit = "# h\n\n"
        let repeated = String(repeating: unit, count: byteCount / unit.utf8.count)
        let source = repeated + String(
            repeating: "x",
            count: byteCount - repeated.utf8.count
        )
        XCTAssertEqual(source.utf8.count, byteCount)
        let residentBefore = currentResidentMemoryBytes()
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await SourcePreservingMarkdownParser.parse(source: source)
            XCTFail("Expected a controlled semantic-complexity failure")
        } catch let error as MarkdownParserError {
            XCTAssertEqual(
                error,
                .semanticComplexityExceeded(
                    SourcePreservingMarkdownParser.safeSemanticElementLimit
                )
            )
        }

        let residentAfter = currentResidentMemoryBytes()
        let residentGrowth = residentAfter > residentBefore
            ? residentAfter - residentBefore
            : 0
        XCTAssertLessThan(started.duration(to: clock.now), .seconds(20))
        XCTAssertLessThan(residentGrowth, 768 * 1_024 * 1_024)
    }

    func testSparseCoordinateCheckpointsPreserveDenseUnicodeTailRanges() async throws {
        let unit = "αβγ paragraph with **strong**.\n\n"
        let source = String(repeating: unit, count: 48_000) + "# 尾部 sentinel\n"
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)
        let text = source as NSString
        let tail = try XCTUnwrap(parsed.document.blocks.last)
        let range: UTF16Range
        guard case .heading(level: 1, content: _, range: let headingRange) = tail else {
            return XCTFail("Expected the final Unicode heading")
        }
        range = headingRange

        XCTAssertEqual(text.substring(with: range.nsRange), "# 尾部 sentinel")
        XCTAssertGreaterThan(range.location, 1_000_000)
    }

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

private func currentResidentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return UInt64(info.resident_size)
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }
}

private extension UTF16Range {
    var nsRange: NSRange { NSRange(location: location, length: length) }
}
