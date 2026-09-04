import AppKit
import XCTest
@testable import Clio

final class MarkdownParserTests: XCTestCase {
    func testComprehensiveFixtureProducesRequiredGFMSpansAndBlocks() async throws {
        let source = try fixture(named: "everything", extension: "md")
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)
        let kinds = Set(parsed.spans.map(\.kind))

        XCTAssertTrue(kinds.isSuperset(of: [
            .heading, .emphasis, .strong, .strikethrough, .unorderedList,
            .orderedList, .task, .blockquote, .inlineCode, .codeFence,
            .link, .autolink, .table, .thematicBreak, .frontMatter, .footnote,
        ]))
        XCTAssertTrue(parsed.document.blocks.contains { if case .table = $0 { true } else { false } })
        XCTAssertTrue(parsed.document.blocks.contains { if case .codeFence = $0 { true } else { false } })
        XCTAssertTrue(parsed.document.blocks.contains { if case .frontMatter = $0 { true } else { false } })
        XCTAssertTrue(parsed.document.blocks.contains { if case .footnoteDefinition = $0 { true } else { false } })
    }

    func testEverySpanAddressesOriginalUTF16SourceAndMarkersStayVisible() async throws {
        let source = "# 👩🏽‍💻 *café* and [site](https://example.com)\n"
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)
        let text = source as NSString

        for span in parsed.spans {
            XCTAssertGreaterThanOrEqual(span.range.location, 0)
            XCTAssertLessThanOrEqual(span.range.upperBound, text.length)
        }
        let markers = parsed.spans.filter { $0.role == .marker }.map {
            text.substring(with: NSRange(location: $0.range.location, length: $0.range.length))
        }
        XCTAssertTrue(markers.contains("#"))
        XCTAssertGreaterThanOrEqual(markers.filter { $0 == "*" }.count, 2)
        XCTAssertEqual(source, text as String)
        XCTAssertEqual(parsed.sourceFingerprint, StableSourceFingerprint.make(source))
    }

    func testInlineASTRetainsDestinationsTitlesAndUnicodeRanges() async throws {
        let source = "Text **bold _nested_** [世界](https://example.com \"Title\") <a@b.co>."
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)
        guard case .paragraph(let content, _) = try XCTUnwrap(parsed.document.blocks.first) else {
            return XCTFail("Expected paragraph")
        }
        XCTAssertTrue(content.contains { if case .strong = $0 { true } else { false } })
        XCTAssertTrue(content.contains {
            if case .link(let destination, let title, _, _) = $0 {
                return destination == "https://example.com" && title == "Title"
            }
            return false
        })
        XCTAssertTrue(content.contains {
            if case .autolink(let text, let destination, _) = $0 {
                return text == "a@b.co" && destination == "mailto:a@b.co"
            }
            return false
        })
    }

    func testMalformedInputIsSourcePreservingAndReportsOpenFence() async throws {
        let source = try fixture(named: "malformed", extension: "md")
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)
        XCTAssertEqual(parsed.sourceFingerprint, StableSourceFingerprint.make(source))
        XCTAssertTrue(parsed.diagnostics.contains { $0.message.contains("Unclosed") })
        XCTAssertLessThanOrEqual(parsed.spans.map(\.range.upperBound).max() ?? 0, (source as NSString).length)
    }

    func testCRLFAndEscapedMarkersKeepExactOffsets() async throws {
        let source = "# Héading\r\n\r\nEscaped \\*plain\\* and **bold**.\r\n"
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)
        let text = source as NSString
        let emphasisContents = parsed.spans.filter { $0.kind == .emphasis && $0.role == .content }
        let strong = try XCTUnwrap(parsed.spans.first { $0.kind == .strong && $0.role == .content })

        XCTAssertTrue(emphasisContents.isEmpty)
        XCTAssertEqual(text.substring(with: strong.range.nsRange), "bold")
        XCTAssertEqual(parsed.sourceFingerprint, StableSourceFingerprint.make(source))
    }

    func testSetextTablesTasksAndCodeTokensRetainSemantics() async throws {
        let source = "Title\n=====\n\n- [X] done\n\n| A | B |\n| :--- | ---: |\n| 1 | 2 |\n\n```swift\nlet value = 42 // note\n```\n"
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)
        XCTAssertTrue(parsed.spans.contains { $0.kind == .heading && $0.level == 1 })
        XCTAssertTrue(parsed.spans.contains { $0.kind == .task && $0.role == .marker })
        XCTAssertTrue(parsed.spans.contains {
            if case .codeToken(.keyword) = $0.role { return true }
            return false
        })
        let table = parsed.document.blocks.compactMap { block -> MarkdownTable? in
            if case .table(let value) = block { return value }
            return nil
        }.first
        XCTAssertEqual(table?.alignments, [.leading, .trailing])
    }

    func testFullModeParsesTenMiBSourceWithoutChangingBytes() async throws {
        let byteCount = PerformanceContract.fullMarkdownByteLimit
        let source = representativeSource(exactUTF8ByteCount: byteCount)
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)

        XCTAssertEqual(source.utf8.count, byteCount)
        XCTAssertEqual(parsed.sizeMode, .full)
        XCTAssertEqual(parsed.sourceFingerprint, StableSourceFingerprint.make(source))
        let kinds = Set(parsed.spans.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.heading, .emphasis, .strong, .task, .link, .codeFence]))
    }

    func testFiftyMiBSafeModeUsesBoundedReducedHighlighting() async throws {
        let byteCount = PerformanceContract.safeLargeFileByteLimit
        let source = "# large\n" + String(repeating: " ", count: byteCount - 8)
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)

        XCTAssertEqual(source.utf8.count, byteCount)
        XCTAssertEqual(parsed.sizeMode, .safeLargeFile)
        XCTAssertTrue(parsed.diagnostics.contains { $0.message.contains("Reduced highlighting") })
        XCTAssertLessThanOrEqual(parsed.spans.map(\.range.upperBound).max() ?? 0, 1_100_000)
    }

    func testSafeLargeExportModelIncludesTailBeyondHighlightingWindow() async throws {
        let sentinel = "TAIL_SENTINEL_Clio"
        let byteCount = PerformanceContract.fullMarkdownByteLimit + 4_096
        let prefix = "# large\n\n"
        let source = prefix
            + String(repeating: "x", count: byteCount - prefix.utf8.count - sentinel.utf8.count)
            + sentinel
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)

        XCTAssertEqual(parsed.sizeMode, .safeLargeFile)
        XCTAssertTrue(model(parsed.document, contains: sentinel))
        XCTAssertLessThanOrEqual(
            parsed.spans.map(\.range.upperBound).max() ?? 0,
            SourcePreservingMarkdownParser.reducedHighlightUTF16Limit
        )
    }

    private func fixture(named name: String, extension ext: String) throws -> String {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: ext, subdirectory: "Markdown")
                ?? bundle.url(forResource: name, withExtension: ext)
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func representativeSource(exactUTF8ByteCount count: Int) -> String {
        let unit = "# Heading\n\nParagraph with *emphasis*, **strong**, and [link](https://example.com). "
            + String(repeating: "plain ", count: 140)
            + "\n\n- [ ] task\n\n```swift\nlet value = 42\n```\n\n"
        let repetitions = count / unit.utf8.count
        let prefix = String(repeating: unit, count: repetitions)
        return prefix + String(repeating: "x", count: count - prefix.utf8.count)
    }

    private func model(_ model: MarkdownDocumentModel, contains sentinel: String) -> Bool {
        for block in model.blocks {
            switch block {
            case .paragraph(let inline, _), .heading(_, let inline, _):
                if inline.contains(where: { node in
                    if case .text(let value, _) = node { return value.contains(sentinel) }
                    return false
                }) { return true }
            case .codeFence(_, let source, _), .frontMatter(let source, _), .rawHTML(let source, _):
                if source.contains(sentinel) { return true }
            default:
                continue
            }
        }
        return false
    }
}

private extension UTF16Range {
    var nsRange: NSRange { NSRange(location: location, length: length) }
}
