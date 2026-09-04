import Foundation
import Markdown

/// Converts the exact, revision-pinned swift-markdown AST into Clio's stable
/// export model. Source coordinates remain UTF-16 offsets into the untouched
/// editor buffer; cmark's UTF-8 columns are translated at this boundary.
struct SwiftMarkdownSemanticResult {
    let blocks: [MarkdownBlock]
    let spans: [MarkdownSpan]
}

struct SwiftMarkdownSemanticParser {
    private let source: String
    private let coordinates: SwiftMarkdownSourceCoordinates

    init(source: String) throws {
        self.source = source
        coordinates = try SwiftMarkdownSourceCoordinates(source)
    }

    func parse() throws -> SwiftMarkdownSemanticResult {
        try Task.checkCancellation()
        let document = Markdown.Document(parsing: source, options: [.disableSmartOpts])
        try Task.checkCancellation()
        var spans: [MarkdownSpan] = []
        let blocks = try document.children.compactMap { child in
            try convertBlock(child, spans: &spans)
        }
        return SwiftMarkdownSemanticResult(blocks: blocks, spans: spans)
    }

    private func convertBlock(
        _ node: Markup,
        spans: inout [MarkdownSpan]
    ) throws -> MarkdownBlock? {
        try Task.checkCancellation()
        let nodeRange = range(of: node)
        if let heading = node as? Markdown.Heading {
            add(.heading, .content, contentRange(of: heading) ?? nodeRange, level: heading.level, to: &spans)
            return .heading(
                level: heading.level,
                content: try convertInlines(heading.children, spans: &spans),
                range: nodeRange
            )
        }
        if let paragraph = node as? Markdown.Paragraph {
            add(.paragraph, .content, contentRange(of: paragraph) ?? nodeRange, to: &spans)
            return .paragraph(
                content: try convertInlines(paragraph.children, spans: &spans),
                range: nodeRange
            )
        }
        if let quote = node as? Markdown.BlockQuote {
            add(.blockquote, .content, nodeRange, to: &spans)
            return .blockquote(
                blocks: try quote.children.compactMap { try convertBlock($0, spans: &spans) },
                range: nodeRange
            )
        }
        if let list = node as? Markdown.OrderedList {
            return try convertList(
                listItems: Array(list.listItems),
                ordered: true,
                start: Int(list.startIndex),
                range: nodeRange,
                spans: &spans
            )
        }
        if let list = node as? Markdown.UnorderedList {
            return try convertList(
                listItems: Array(list.listItems),
                ordered: false,
                start: nil,
                range: nodeRange,
                spans: &spans
            )
        }
        if let code = node as? Markdown.CodeBlock {
            add(.codeFence, .content, nodeRange, to: &spans)
            return .codeFence(language: code.language, source: code.code, range: nodeRange)
        }
        if let table = node as? Markdown.Table {
            return try convertTable(table, range: nodeRange, spans: &spans)
        }
        if node is Markdown.ThematicBreak {
            add(.thematicBreak, .blockRule, nodeRange, to: &spans)
            return .thematicBreak(range: nodeRange)
        }
        if let html = node as? Markdown.HTMLBlock {
            return .rawHTML(source: html.rawHTML, range: nodeRange)
        }
        return nil
    }

    private func convertList(
        listItems: [Markdown.ListItem],
        ordered: Bool,
        start: Int?,
        range: UTF16Range,
        spans: inout [MarkdownSpan]
    ) throws -> MarkdownBlock {
        let kind: MarkdownSemanticKind = ordered ? .orderedList : .unorderedList
        add(kind, .content, range, to: &spans)
        var items: [MarkdownListItem] = []
        for item in listItems {
            try Task.checkCancellation()
            let itemRange = self.range(of: item)
            let task: MarkdownTaskState?
            switch item.checkbox {
            case .checked?: task = .checked
            case .unchecked?: task = .unchecked
            case nil: task = nil
            }
            if task != nil { add(.task, .content, itemRange, to: &spans) }
            items.append(MarkdownListItem(
                taskState: task,
                blocks: try item.children.compactMap { try convertBlock($0, spans: &spans) },
                range: itemRange
            ))
        }
        return .list(MarkdownList(
            isOrdered: ordered,
            start: start,
            isTight: listIsTight(range),
            items: items,
            range: range
        ))
    }

    private func convertTable(
        _ table: Markdown.Table,
        range: UTF16Range,
        spans: inout [MarkdownSpan]
    ) throws -> MarkdownBlock {
        add(.table, .content, range, to: &spans)
        let alignments = table.columnAlignments.map { alignment -> MarkdownTableAlignment in
            switch alignment {
            case .left?: return .leading
            case .center?: return .center
            case .right?: return .trailing
            case nil: return .none
            }
        }
        let header = try table.head.children.compactMap { child -> MarkdownTableCell? in
            guard let cell = child as? Markdown.Table.Cell else { return nil }
            return try convertCell(cell, spans: &spans)
        }
        var rows: [[MarkdownTableCell]] = []
        for row in table.body.rows {
            rows.append(try row.children.compactMap { child -> MarkdownTableCell? in
                guard let cell = child as? Markdown.Table.Cell else { return nil }
                return try convertCell(cell, spans: &spans)
            })
        }
        return .table(MarkdownTable(
            alignments: alignments,
            header: header,
            rows: rows,
            range: range
        ))
    }

    private func convertCell(
        _ cell: Markdown.Table.Cell,
        spans: inout [MarkdownSpan]
    ) throws -> MarkdownTableCell {
        MarkdownTableCell(
            content: try convertInlines(cell.children, spans: &spans),
            range: range(of: cell)
        )
    }

    private func convertInlines(
        _ children: MarkupChildren,
        spans: inout [MarkdownSpan]
    ) throws -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        for child in children {
            if let text = child as? Markdown.Text {
                result.append(contentsOf: convertText(text, spans: &spans))
            } else if let converted = try convertInline(child, spans: &spans) {
                result.append(converted)
            }
        }
        return result
    }

    private func convertInline(
        _ node: Markup,
        spans: inout [MarkdownSpan]
    ) throws -> MarkdownInline? {
        try Task.checkCancellation()
        let nodeRange = range(of: node)
        if let emphasis = node as? Markdown.Emphasis {
            addDelimiterSpans(.emphasis, node: emphasis, to: &spans)
            add(.emphasis, .content, delimiterContentRange(.emphasis, node: emphasis), to: &spans)
            return .emphasis(
                content: try convertInlines(emphasis.children, spans: &spans),
                range: nodeRange
            )
        }
        if let strong = node as? Markdown.Strong {
            addDelimiterSpans(.strong, node: strong, to: &spans)
            add(.strong, .content, delimiterContentRange(.strong, node: strong), to: &spans)
            return .strong(
                content: try convertInlines(strong.children, spans: &spans),
                range: nodeRange
            )
        }
        if let strike = node as? Markdown.Strikethrough {
            addDelimiterSpans(.strikethrough, node: strike, to: &spans)
            add(
                .strikethrough,
                .content,
                delimiterContentRange(.strikethrough, node: strike),
                to: &spans
            )
            return .strikethrough(
                content: try convertInlines(strike.children, spans: &spans),
                range: nodeRange
            )
        }
        if let code = node as? Markdown.InlineCode {
            return .code(value: code.code, range: nodeRange)
        }
        if let link = node as? Markdown.Link {
            let destination = link.destination ?? ""
            let literal = substring(nodeRange)
            let childText = link.childCount == 1
                ? (link.child(at: 0) as? Markdown.Text)?.string
                : nil
            let isAutomatic = literal.hasPrefix("<")
                || (childText == literal
                    && (destination == literal || destination == "mailto:" + literal))
            addDelimiterSpans(isAutomatic ? .autolink : .link, node: link, to: &spans)
            add(
                isAutomatic ? .autolink : .link,
                .content,
                contentRange(of: link) ?? nodeRange,
                to: &spans
            )
            if isAutomatic, let text = childText {
                return .autolink(text: text, destination: destination, range: nodeRange)
            }
            return .link(
                destination: destination,
                title: link.title,
                content: try convertInlines(link.children, spans: &spans),
                range: nodeRange
            )
        }
        if let image = node as? Markdown.Image {
            return .image(
                source: image.source ?? "",
                title: image.title,
                alt: try convertInlines(image.children, spans: &spans),
                range: nodeRange
            )
        }
        if node is Markdown.SoftBreak { return .softBreak(range: nodeRange) }
        if node is Markdown.LineBreak { return .hardBreak(range: nodeRange) }
        if let html = node as? Markdown.InlineHTML {
            return .rawHTML(source: html.rawHTML, range: nodeRange)
        }
        return nil
    }

    private func convertText(
        _ text: Markdown.Text,
        spans: inout [MarkdownSpan]
    ) -> [MarkdownInline] {
        let nodeRange = range(of: text)
        let literal = substring(nodeRange)
        guard literal.contains("[^")
                || literal.contains("http://")
                || literal.contains("https://")
                || literal.contains("www.")
                || literal.contains("@") else {
            return [.text(value: text.string, range: nodeRange)]
        }
        let value = literal as NSString
        let matches = textExtensionMatches(in: value)
        guard !matches.isEmpty else { return [.text(value: text.string, range: nodeRange)] }
        var result: [MarkdownInline] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let prefix = NSRange(location: cursor, length: match.range.location - cursor)
                result.append(.text(
                    value: decodedLiteralText(value.substring(with: prefix)),
                    range: prefix.offset(by: nodeRange.location).utf16
                ))
            }
            let absolute = match.range.offset(by: nodeRange.location)
            switch match.kind {
            case .footnote(let label):
                add(.footnote, .content, absolute.utf16, to: &spans)
                spans.append(MarkdownSpan(
                    kind: .footnote,
                    role: .marker,
                    range: UTF16Range(location: absolute.location, length: 2)
                ))
                spans.append(MarkdownSpan(
                    kind: .footnote,
                    role: .marker,
                    range: UTF16Range(location: absolute.upperBound - 1, length: 1)
                ))
                result.append(.footnoteReference(label: label, range: absolute.utf16))
            case .autolink(let display, let destination):
                add(.autolink, .destination, absolute.utf16, to: &spans)
                result.append(.autolink(
                    text: display,
                    destination: destination,
                    range: absolute.utf16
                ))
            }
            cursor = match.range.upperBound
        }
        if cursor < value.length {
            let suffix = NSRange(location: cursor, length: value.length - cursor)
            result.append(.text(
                value: decodedLiteralText(value.substring(with: suffix)),
                range: suffix.offset(by: nodeRange.location).utf16
            ))
        }
        return result
    }

    /// cmark decodes character references before exposing `Text.string`, while
    /// its source range still covers the original entity spelling. Reparse only
    /// split literal fragments so an adjacent `[^label]` cannot disappear.
    private func decodedLiteralText(_ literal: String) -> String {
        let document = Markdown.Document(parsing: literal, options: [.disableSmartOpts])
        let paragraphs = document.children.compactMap { $0 as? Markdown.Paragraph }
        guard !paragraphs.isEmpty else { return literal }
        return paragraphs.map(\.plainText).joined(separator: "\n")
    }

    private enum TextExtensionKind {
        case footnote(String)
        case autolink(display: String, destination: String)
    }

    private struct TextExtensionMatch {
        let range: NSRange
        let kind: TextExtensionKind
    }

    private func textExtensionMatches(in value: NSString) -> [TextExtensionMatch] {
        var matches: [TextExtensionMatch] = []
        var cursor = 0
        while cursor < value.length {
            if cursor.isMultiple(of: 4_096), Task.isCancelled { break }
            if value.character(at: cursor) == 0x5B,
               has("[^", at: cursor, in: value),
               let close = closingBracket(after: cursor + 2, in: value) {
                let labelRange = NSRange(location: cursor + 2, length: close - cursor - 2)
                if labelRange.length > 0 {
                    matches.append(TextExtensionMatch(
                        range: NSRange(location: cursor, length: close + 1 - cursor),
                        kind: .footnote(value.substring(with: labelRange))
                    ))
                    cursor = close + 1
                    continue
                }
            }
            let urlPrefix = ["https://", "http://", "www."].first {
                has($0, at: cursor, in: value)
            }
            if let urlPrefix {
                var end = cursor + (urlPrefix as NSString).length
                while end < value.length, !isURLBoundary(value.character(at: end)) { end += 1 }
                while end > cursor, ".,:;!?".utf16.contains(value.character(at: end - 1)) {
                    end -= 1
                }
                let range = NSRange(location: cursor, length: end - cursor)
                let display = value.substring(with: range)
                let destination = display.hasPrefix("www.") ? "http://" + display : display
                matches.append(TextExtensionMatch(
                    range: range,
                    kind: .autolink(display: display, destination: destination)
                ))
                cursor = max(end, cursor + 1)
                continue
            }
            if isEmailCharacter(value.character(at: cursor)) {
                let start = cursor
                while cursor < value.length, isEmailCharacter(value.character(at: cursor)) {
                    cursor += 1
                }
                let range = NSRange(location: start, length: cursor - start)
                if range.length <= 320 {
                    let candidate = value.substring(with: range)
                    if candidate.contains("@"), isEmail(candidate) {
                        matches.append(TextExtensionMatch(
                            range: range,
                            kind: .autolink(display: candidate, destination: "mailto:" + candidate)
                        ))
                    }
                }
                continue
            }
            cursor += 1
        }
        return matches
    }

    private func has(_ needle: String, at location: Int, in value: NSString) -> Bool {
        let length = (needle as NSString).length
        guard location + length <= value.length else { return false }
        return value.substring(with: NSRange(location: location, length: length)) == needle
    }

    private func closingBracket(after start: Int, in value: NSString) -> Int? {
        var cursor = start
        while cursor < value.length {
            let scalar = value.character(at: cursor)
            if scalar == 0x5D { return cursor }
            if scalar == 0x0A || scalar == 0x0D { return nil }
            cursor += 1
            if cursor - start > 1_024 { return nil }
        }
        return nil
    }

    private func isURLBoundary(_ scalar: unichar) -> Bool {
        guard let unicode = UnicodeScalar(scalar) else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(unicode)
            || scalar == 0x3C || scalar == 0x3E
    }

    private func isEmailCharacter(_ scalar: unichar) -> Bool {
        guard let unicode = UnicodeScalar(scalar) else { return false }
        return CharacterSet.alphanumerics.contains(unicode)
            || ".!#$%&'*+/=?^_`{|}~-@".utf16.contains(scalar)
    }

    private func isEmail(_ value: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"#
        ) else { return false }
        let range = NSRange(location: 0, length: (value as NSString).length)
        return expression.firstMatch(in: value, range: range)?.range == range
    }

    private func range(of node: Markup) -> UTF16Range {
        guard let sourceRange = node.range else {
            return UTF16Range(location: 0, length: 0)
        }
        return coordinates.range(sourceRange)
    }

    private func contentRange(of node: Markup) -> UTF16Range? {
        let children = Array(node.children)
        guard let first = children.first, let last = children.last else { return nil }
        let lower = range(of: first)
        let upper = range(of: last)
        guard lower.length > 0 || upper.length > 0 else { return nil }
        return UTF16Range(
            location: lower.location,
            length: max(0, upper.upperBound - lower.location)
        )
    }

    private func addDelimiterSpans(
        _ kind: MarkdownSemanticKind,
        node: Markup,
        to spans: inout [MarkdownSpan]
    ) {
        let whole = range(of: node)
        let width = kind == .emphasis ? 1 : 2
        let inset = coincidentAncestorWidth(of: node, range: whole)
        guard whole.length >= (inset + width) * 2 else { return }
        let opening = UTF16Range(location: whole.location + inset, length: width)
        let closing = UTF16Range(location: whole.upperBound - inset - width, length: width)
        guard validDelimiter(substring(opening), kind: kind),
              validDelimiter(substring(closing), kind: kind) else { return }
        add(kind, .marker, opening, to: &spans)
        add(kind, .marker, closing, to: &spans)
    }

    private func delimiterContentRange(
        _ kind: MarkdownSemanticKind,
        node: Markup
    ) -> UTF16Range {
        let whole = range(of: node)
        let width = kind == .emphasis ? 1 : 2
        let inset = coincidentAncestorWidth(of: node, range: whole)
        let total = inset + width
        guard whole.length >= total * 2 else { return whole }
        return UTF16Range(location: whole.location + total, length: whole.length - total * 2)
    }

    private func coincidentAncestorWidth(of node: Markup, range: UTF16Range) -> Int {
        var result = 0
        var ancestor = node.parent
        while let parent = ancestor,
              isDelimiter(parent),
              self.range(of: parent) == range {
            result += parent is Markdown.Emphasis ? 1 : 2
            ancestor = parent.parent
        }
        return result
    }

    private func isDelimiter(_ node: Markup) -> Bool {
        node is Markdown.Emphasis || node is Markdown.Strong || node is Markdown.Strikethrough
    }

    private func validDelimiter(_ value: String, kind: MarkdownSemanticKind) -> Bool {
        switch kind {
        case .emphasis: return value == "*" || value == "_"
        case .strong: return value == "**" || value == "__"
        case .strikethrough: return value == "~~"
        default: return false
        }
    }

    private func add(
        _ kind: MarkdownSemanticKind,
        _ role: MarkdownSpanRole,
        _ range: UTF16Range,
        level: Int? = nil,
        to spans: inout [MarkdownSpan]
    ) {
        guard range.length > 0 else { return }
        spans.append(MarkdownSpan(kind: kind, role: role, range: range, level: level))
    }

    private func substring(_ range: UTF16Range) -> String {
        let text = source as NSString
        return text.substring(with: range.clamped(toUTF16Length: text.length).nsRange)
    }

    private func listIsTight(_ range: UTF16Range) -> Bool {
        let value = substring(range)
        return !value.contains("\n\n") && !value.contains("\r\n\r\n")
    }
}

private struct SwiftMarkdownSourceCoordinates {
    private let source: String
    private let utf8LineStarts: [Int]
    private let utf16LineStarts: [Int]
    private let utf8Count: Int

    init(_ source: String) throws {
        self.source = source
        utf8Count = source.utf8.count
        var byteStarts = [0]
        var wordStarts = [0]
        var byteOffset = 0
        var utf16Offset = 0
        var scanned = 0
        for scalar in source.unicodeScalars {
            let byteWidth = scalar.utf8.count
            let wordWidth = scalar.utf16.count
            byteOffset += byteWidth
            utf16Offset += wordWidth
            if scalar == "\n" {
                byteStarts.append(byteOffset)
                wordStarts.append(utf16Offset)
            }
            scanned += byteWidth
            if scanned >= 65_536 {
                try Task.checkCancellation()
                scanned = 0
            }
        }
        utf8LineStarts = byteStarts
        utf16LineStarts = wordStarts
    }

    func range(_ sourceRange: Markdown.SourceRange) -> UTF16Range {
        let lower = offset(sourceRange.lowerBound)
        let upper = max(lower, offset(sourceRange.upperBound))
        return UTF16Range(location: lower, length: upper - lower)
    }

    private func offset(_ location: Markdown.SourceLocation) -> Int {
        let line = min(max(0, location.line - 1), utf8LineStarts.count - 1)
        let byteOffset = min(
            utf8Count,
            utf8LineStarts[line] + max(0, location.column - 1)
        )
        let byteIndex = source.utf8.index(source.utf8.startIndex, offsetBy: byteOffset)
        guard let stringIndex = String.Index(byteIndex, within: source) else {
            return utf16LineStarts[line]
        }
        let lineByteIndex = source.utf8.index(
            source.utf8.startIndex,
            offsetBy: utf8LineStarts[line]
        )
        guard let lineIndex = String.Index(lineByteIndex, within: source) else {
            return utf16LineStarts[line]
        }
        return utf16LineStarts[line] + source[lineIndex..<stringIndex].utf16.count
    }
}

private extension String {
    func dropEnds() -> String {
        guard count >= 2 else { return self }
        return String(dropFirst().dropLast())
    }
}

private extension UTF16Range {
    var nsRange: NSRange { NSRange(location: location, length: length) }
}

private extension NSRange {
    var upperBound: Int { NSMaxRange(self) }
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }

    func offset(by amount: Int) -> NSRange {
        NSRange(location: location + amount, length: length)
    }
}
