import XCTest
@testable import Clio

final class MarkdownConformanceTests: XCTestCase {
    func testDelimiterFlankingAndNestingUseCommonMarkSemantics() async throws {
        let source = try fixture("delimiters")
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)
        let inlines = parsed.document.blocks.flatMap(\.allInlines)

        XCTAssertTrue(inlines.contains { inline in
            guard case .emphasis(let children, _) = inline else { return false }
            return children.contains { if case .strong = $0 { return true }; return false }
        })
        XCTAssertTrue(inlines.contains { if case .strikethrough = $0 { return true }; return false })
        let emphasizedSource = sourceSlices(for: .emphasis, role: .content, parsed: parsed, source: source)
        XCTAssertFalse(emphasizedSource.contains("underscore"))
        let emphasisMarkers = sourceSlices(for: .emphasis, role: .marker, parsed: parsed, source: source)
        let strongMarkers = sourceSlices(for: .strong, role: .marker, parsed: parsed, source: source)
        XCTAssertGreaterThanOrEqual(emphasisMarkers.filter { $0 == "*" }.count, 2, "\(emphasisMarkers)")
        XCTAssertGreaterThanOrEqual(strongMarkers.filter { $0 == "**" }.count, 2, "\(strongMarkers)")
        XCTAssertEqual(source, source as NSString as String)
    }

    func testReferencesCodeSpanRunsAndEntities() async throws {
        let source = try fixture("links-code-entities")
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)
        let inlines = parsed.document.blocks.flatMap(\.allInlines)
        let links = inlines.compactMap { inline -> String? in
            if case .link(let destination, _, _, _) = inline { return destination }
            return nil
        }
        let code = inlines.compactMap { inline -> String? in
            if case .code(let value, _) = inline { return value }
            return nil
        }
        let text = inlines.compactMap { inline -> String? in
            if case .text(let value, _) = inline { return value }
            return nil
        }.joined()

        XCTAssertTrue(links.contains("https://clio.example"))
        XCTAssertTrue(links.contains("/relative"))
        XCTAssertEqual(code, ["one", "code ` inside"])
        XCTAssertTrue(text.contains("& 🙂"))
    }

    func testIndentedCodeNestedLooseListsQuotesAndTable() async throws {
        let parsed = try await SourcePreservingMarkdownParser.parse(source: fixture("blocks"))
        XCTAssertTrue(parsed.document.blocks.contains {
            if case .codeFence(let language, let source, _) = $0 {
                return language == nil && source.contains("indented <code>")
            }
            return false
        })
        let lists = parsed.document.blocks.compactMap { block -> MarkdownList? in
            if case .list(let list) = block { return list }
            return nil
        }
        XCTAssertEqual(lists.count, 2)
        XCTAssertFalse(try XCTUnwrap(lists.first).isTight)
        XCTAssertTrue(try XCTUnwrap(lists.first).items.flatMap(\.blocks).contains {
            if case .list = $0 { return true }; return false
        })
        XCTAssertTrue(parsed.document.blocks.contains {
            guard case .blockquote(let children, _) = $0 else { return false }
            return children.contains { if case .blockquote = $0 { return true }; return false }
        })
        let table = parsed.document.blocks.compactMap { block -> MarkdownTable? in
            if case .table(let table) = block { return table }; return nil
        }.first
        XCTAssertEqual(table?.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(table?.rows.count, 1)
    }

    func testGFMHTMLAndClioExtensionsRemainSemantic() async throws {
        let parsed = try await SourcePreservingMarkdownParser.parse(source: fixture("gfm-extensions"))
        XCTAssertTrue(parsed.document.blocks.contains { if case .frontMatter = $0 { return true }; return false })
        XCTAssertTrue(parsed.document.blocks.contains { if case .rawHTML = $0 { return true }; return false })
        XCTAssertTrue(parsed.document.blocks.contains { if case .footnoteDefinition = $0 { return true }; return false })
        let inlines = parsed.document.blocks.flatMap(\.allInlines)
        XCTAssertTrue(inlines.contains { if case .strikethrough = $0 { return true }; return false })
        XCTAssertTrue(inlines.contains { if case .autolink = $0 { return true }; return false })
        XCTAssertTrue(inlines.contains { if case .footnoteReference(label: "note", range: _) = $0 { return true }; return false })
        let tasks = parsed.document.blocks.compactMap { block -> [MarkdownTaskState?]? in
            if case .list(let list) = block { return list.items.map(\.taskState) }; return nil
        }.flatMap { $0 }
        XCTAssertEqual(tasks.compactMap { $0 }, [.checked, .unchecked])
        let footnoteText = parsed.document.blocks.compactMap { block -> [MarkdownBlock]? in
            if case .footnoteDefinition(label: "note", blocks: let blocks, range: _) = block {
                return blocks
            }
            return nil
        }.flatMap { $0 }.flatMap(\.allInlines).compactMap { inline -> String? in
            if case .text(let value, _) = inline { return value }; return nil
        }.joined()
        XCTAssertTrue(footnoteText.contains("continued line"))
    }

    func testMalformedUnicodeRangesAddressExactOriginalSource() async throws {
        let source = try fixture("malformed-unicode")
        let parsed = try await SourcePreservingMarkdownParser.parse(source: source)
        let text = source as NSString
        XCTAssertTrue(parsed.spans.allSatisfy { $0.range.upperBound <= text.length })
        XCTAssertTrue(sourceSlices(for: .strong, role: .content, parsed: parsed, source: source).contains("bold _nested_"))
        let markers = sourceSlices(for: .strong, role: .marker, parsed: parsed, source: source)
        XCTAssertEqual(markers.filter { $0 == "**" }.count, 2)
        XCTAssertEqual(parsed.sourceFingerprint, StableSourceFingerprint.make(source))
    }

    private func fixture(_ name: String) throws -> String {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "md", subdirectory: "Markdown/Conformance")
                ?? bundle.url(forResource: name, withExtension: "md")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceSlices(
        for kind: MarkdownSemanticKind,
        role: MarkdownSpanRole,
        parsed: ParsedMarkdown,
        source: String
    ) -> [String] {
        let text = source as NSString
        return parsed.spans.filter { $0.kind == kind && $0.role == role }.map {
            text.substring(with: NSRange(location: $0.range.location, length: $0.range.length))
        }
    }
}

private extension MarkdownBlock {
    var allInlines: [MarkdownInline] {
        switch self {
        case .paragraph(let values, _), .heading(_, let values, _): return values.flatMap(\.flattened)
        case .blockquote(let blocks, _): return blocks.flatMap(\.allInlines)
        case .list(let list): return list.items.flatMap { $0.blocks.flatMap(\.allInlines) }
        case .table(let table):
            return (table.header + table.rows.flatMap { $0 }).flatMap { $0.content.flatMap(\.flattened) }
        case .footnoteDefinition(_, let blocks, _): return blocks.flatMap(\.allInlines)
        default: return []
        }
    }
}

private extension MarkdownInline {
    var flattened: [MarkdownInline] {
        switch self {
        case .emphasis(let children, _), .strong(let children, _), .strikethrough(let children, _):
            return [self] + children.flatMap(\.flattened)
        case .link(_, _, let children, _): return [self] + children.flatMap(\.flattened)
        case .image(_, _, let children, _): return [self] + children.flatMap(\.flattened)
        default: return [self]
        }
    }
}
