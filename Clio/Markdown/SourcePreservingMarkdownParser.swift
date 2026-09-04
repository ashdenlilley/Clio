import Foundation

enum MarkdownParserError: LocalizedError, Equatable {
    case sourceExceedsSafeLimit(Int)

    var errorDescription: String? {
        switch self {
        case .sourceExceedsSafeLimit(let bytes):
            return "This document is \(bytes) bytes; Clio safely supports files through 50 MiB."
        }
    }
}

/// Source-preserving facade over the revision-pinned swift-markdown/cmark-gfm
/// semantic parser and Clio's marker-aware presentation lexer.
struct SourcePreservingMarkdownParser: MarkdownParsing {
    static let reducedHighlightUTF16Limit = 1_048_576

    func parse(_ snapshot: DocumentTextSnapshot) async throws -> ParsedMarkdown {
        try Task.checkCancellation()
        guard snapshot.sizeMode != .unsupported else {
            throw MarkdownParserError.sourceExceedsSafeLimit(snapshot.source.utf8.count)
        }

        let semantics = try SwiftMarkdownSemanticParser(source: snapshot.source).parse()
        try Task.checkCancellation()

        if snapshot.sizeMode == .safeLargeFile {
            let visibleSpans = try Self.reducedHighlightingSpans(in: snapshot.source)
            let boundedSemanticSpans = semantics.spans.filter {
                $0.range.upperBound <= Self.reducedHighlightUTF16Limit
            }
            let extensionBlocks = try MarkdownExtensionModelScanner(snapshot.source).scan()
            let diagnostic = MarkdownDiagnostic(
                severity: .note,
                message: "Reduced highlighting is active for this large document.",
                range: nil
            )
            return ParsedMarkdown(
                documentID: snapshot.documentID,
                generation: snapshot.generation,
                sourceFingerprint: snapshot.sourceFingerprint,
                sizeMode: snapshot.sizeMode,
                document: MarkdownDocumentModel(blocks: Self.applyingExtensions(
                    extensionBlocks,
                    to: semantics.blocks
                )),
                spans: Self.normalizedSpans(visibleSpans + boundedSemanticSpans),
                diagnostics: [diagnostic]
            )
        }

        var parser = MarkdownPresentationLexer(
            source: snapshot.source,
            mode: MarkdownHighlightingMode(sizeMode: snapshot.sizeMode)
        )
        let presentation = try parser.parse()
        let blocks = Self.applyingExtensions(
            presentation.extensionBlocks,
            to: semantics.blocks
        )
        return ParsedMarkdown(
            documentID: snapshot.documentID,
            generation: snapshot.generation,
            sourceFingerprint: snapshot.sourceFingerprint,
            sizeMode: snapshot.sizeMode,
            document: MarkdownDocumentModel(blocks: blocks),
            spans: Self.normalizedSpans(
                presentation.spans.filter { !Self.semanticDelimiterKinds.contains($0.kind) }
                    + semantics.spans
            ),
            diagnostics: presentation.diagnostics
        )
    }

    static func reducedHighlightingSpans(in source: String) throws -> [MarkdownSpan] {
        let text = source as NSString
        let cap = min(text.length, reducedHighlightUTF16Limit)
        let composedCap = cap < text.length
            ? text.rangeOfComposedCharacterSequence(at: cap).location
            : cap
        let prefixEnd = composedCap > 0
            ? NSMaxRange(text.lineRange(for: NSRange(location: composedCap - 1, length: 0)))
            : 0
        var parser = MarkdownPresentationLexer(
            source: text.substring(to: min(prefixEnd, text.length)),
            mode: .reduced,
            spanLimit: reducedHighlightUTF16Limit
        )
        return try parser.parse().spans.filter {
            !semanticDelimiterKinds.contains($0.kind)
        }
    }

    static func parse(
        source: String,
        filename: String = "untitled.md",
        documentID: DocumentID = DocumentID(),
        generation: BufferGeneration = BufferGeneration()
    ) async throws -> ParsedMarkdown {
        try await Self().parse(DocumentTextSnapshot(
            documentID: documentID,
            generation: generation,
            filename: filename,
            source: source,
            sourceFingerprint: try StableSourceFingerprint.makeCheckingCancellation(source)
        ))
    }

    static func spanOrder(_ lhs: MarkdownSpan, _ rhs: MarkdownSpan) -> Bool {
        if lhs.range.location != rhs.range.location { return lhs.range.location < rhs.range.location }
        if lhs.range.length != rhs.range.length { return lhs.range.length > rhs.range.length }
        return String(describing: lhs.role) < String(describing: rhs.role)
    }

    static func normalizedSpans(_ spans: [MarkdownSpan]) -> [MarkdownSpan] {
        Array(Set(spans)).sorted(by: spanOrder)
    }

    private static let semanticDelimiterKinds: Set<MarkdownSemanticKind> = [
        .emphasis, .strong, .strikethrough,
    ]

    /// Front matter and footnotes are intentional Clio extensions layered on
    /// top of CommonMark/GFM. Extension blocks replace native interpretations
    /// only where their exact source ranges overlap.
    private static func applyingExtensions(
        _ scanned: [MarkdownBlock],
        to semantic: [MarkdownBlock]
    ) -> [MarkdownBlock] {
        let extensions = scanned.filter { block in
            switch block {
            case .frontMatter, .footnoteDefinition: return true
            default: return false
            }
        }
        guard !extensions.isEmpty else { return semantic }
        let extensionRanges = extensions.map(\.sourceRange)
        let retained = semantic.filter { block in
            !extensionRanges.contains { $0.intersects(block.sourceRange) }
        }
        return (retained + extensions).sorted {
            $0.sourceRange.location < $1.sourceRange.location
        }
    }
}

enum StableSourceFingerprint {
    /// Deterministic FNV-1a is sufficient for stale-result rejection in the UI;
    /// disk conflict detection owns its stronger content digest separately.
    static func make(_ source: String) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return String(value, radix: 16)
    }

    static func makeCheckingCancellation(_ source: String) throws -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        var scanned = 0
        for byte in source.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
            scanned += 1
            if scanned == 65_536 {
                try Task.checkCancellation()
                scanned = 0
            }
        }
        try Task.checkCancellation()
        return String(value, radix: 16)
    }
}

private extension MarkdownBlock {
    var sourceRange: UTF16Range {
        switch self {
        case .paragraph(_, let range), .heading(_, _, let range),
             .blockquote(_, let range), .codeFence(_, _, let range),
             .thematicBreak(let range), .frontMatter(_, let range),
             .footnoteDefinition(_, _, let range), .rawHTML(_, let range):
            return range
        case .list(let list): return list.range
        case .table(let table): return table.range
        }
    }
}

private extension UTF16Range {
    func intersects(_ other: UTF16Range) -> Bool {
        location < other.upperBound && other.location < upperBound
    }
}

private struct MarkdownPresentationResult {
    var extensionBlocks: [MarkdownBlock] = []
    var spans: [MarkdownSpan] = []
    var diagnostics: [MarkdownDiagnostic] = []
}

/// Marker-aware lexer only. CommonMark/GFM semantics always come from
/// SwiftMarkdownSemanticParser; the only model nodes emitted here are Clio's
/// front-matter and footnote extensions.
private struct MarkdownPresentationLexer {
    private let map: MarkdownSource
    private let mode: MarkdownHighlightingMode
    private let spanLimit: Int?
    private var result = MarkdownPresentationResult()
    private var lineIndex = 0

    init(source: String, mode: MarkdownHighlightingMode, spanLimit: Int? = nil) {
        map = MarkdownSource(source)
        self.mode = mode
        self.spanLimit = spanLimit
    }

    mutating func parse() throws -> MarkdownPresentationResult {
        if parseFrontMatter() { lineIndex += 1 }
        while lineIndex < map.lines.count {
            if lineIndex.isMultiple(of: 256) { try Task.checkCancellation() }
            if map.lines[lineIndex].isBlank {
                lineIndex += 1
            } else if try parseFence() {
                continue
            } else if parseATXHeading() {
                continue
            } else if parseSetextHeading() {
                continue
            } else if parseThematicBreak() {
                continue
            } else if parseFootnoteDefinition() {
                continue
            } else if parseTable() {
                continue
            } else if parseList() {
                continue
            } else if parseBlockquote() {
                continue
            } else if parseRawHTML() {
                continue
            } else {
                parseParagraph()
            }
        }
        try Task.checkCancellation()
        return result
    }

    private mutating func parseFrontMatter() -> Bool {
        guard map.lines.first?.trimmed == "---", map.lines.count > 1 else { return false }
        var closing: Int?
        for index in 1..<map.lines.count
        where map.lines[index].trimmed == "---" || map.lines[index].trimmed == "..." {
            closing = index
            break
        }
        guard let closing else { return false }
        let range = union(map.lines[0].fullRange, map.lines[closing].fullRange)
        result.extensionBlocks.append(.frontMatter(source: map.substring(range), range: range.utf16))
        addSpan(.frontMatter, .marker, map.lines[0].contentRange)
        addSpan(.frontMatter, .marker, map.lines[closing].contentRange)
        if closing > 1 {
            let content = NSRange(
                location: NSMaxRange(map.lines[0].fullRange),
                length: map.lines[closing].fullRange.location - NSMaxRange(map.lines[0].fullRange)
            )
            addSpan(.frontMatter, .content, content)
        }
        lineIndex = closing
        return true
    }

    private mutating func parseFence() throws -> Bool {
        let openingLine = map.lines[lineIndex]
        guard let opening = openingLine.fence else { return false }
        var closingIndex: Int?
        var cursor = lineIndex + 1
        while cursor < map.lines.count {
            if let candidate = map.lines[cursor].fence,
               candidate.character == opening.character,
               candidate.count >= opening.count,
               candidate.infoRange == nil {
                closingIndex = cursor
                break
            }
            cursor += 1
        }
        let lastIndex = closingIndex ?? (map.lines.count - 1)
        let range = union(openingLine.fullRange, map.lines[lastIndex].fullRange)
        let bodyStart = NSMaxRange(openingLine.fullRange)
        let bodyEnd = closingIndex.map { map.lines[$0].fullRange.location } ?? NSMaxRange(range)
        let bodyRange = NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart))
        let language = opening.infoRange.map { map.substring($0).trimmingCharacters(in: .whitespaces) }
        addSpan(.codeFence, .marker, opening.markerRange)
        if let info = opening.infoRange { addSpan(.codeFence, .infoString, info) }
        if let closingIndex, let closing = map.lines[closingIndex].fence {
            addSpan(.codeFence, .marker, closing.markerRange)
        } else {
            result.diagnostics.append(MarkdownDiagnostic(
                severity: .note,
                message: "Unclosed fenced code block",
                range: opening.markerRange.utf16
            ))
        }
        if bodyRange.length > 0 {
            addSpan(.codeFence, .content, bodyRange)
            if mode == .full {
                result.spans.append(contentsOf: try MarkdownCodeTokenizer.spans(
                    in: map.substring(bodyRange),
                    offset: bodyRange.location,
                    language: language
                ))
            }
        }
        lineIndex = lastIndex + 1
        return true
    }

    private mutating func parseATXHeading() -> Bool {
        let line = map.lines[lineIndex]
        let value = line.text as NSString
        var cursor = min(line.indentation, value.length)
        guard cursor <= 3 else { return false }
        let markerStart = cursor
        while cursor < value.length, value.character(at: cursor) == 0x23 { cursor += 1 }
        let level = cursor - markerStart
        guard (1...6).contains(level),
              cursor == value.length || isWhitespace(value.character(at: cursor)) else { return false }
        let openingRange = NSRange(location: line.contentRange.location + markerStart, length: level)
        addSpan(.heading, .marker, openingRange, level: level)
        while cursor < value.length, isWhitespace(value.character(at: cursor)) { cursor += 1 }
        var end = value.length
        while end > cursor, isWhitespace(value.character(at: end - 1)) { end -= 1 }
        var closingStart = end
        while closingStart > cursor, value.character(at: closingStart - 1) == 0x23 { closingStart -= 1 }
        if closingStart < end,
           closingStart == cursor || isWhitespace(value.character(at: closingStart - 1)) {
            addSpan(.heading, .marker, NSRange(
                location: line.contentRange.location + closingStart,
                length: end - closingStart
            ), level: level)
            end = closingStart
            while end > cursor, isWhitespace(value.character(at: end - 1)) { end -= 1 }
        }
        let contentRange = NSRange(
            location: line.contentRange.location + cursor,
            length: max(0, end - cursor)
        )
        _ = parseInline(contentRange)
        addSpan(.heading, .content, contentRange, level: level)
        lineIndex += 1
        return true
    }

    private mutating func parseSetextHeading() -> Bool {
        guard lineIndex + 1 < map.lines.count,
              !map.lines[lineIndex].isBlank,
              let level = setextLevel(map.lines[lineIndex + 1]) else { return false }
        let contentLine = map.lines[lineIndex]
        let ruleLine = map.lines[lineIndex + 1]
        _ = parseInline(contentLine.contentRange)
        addSpan(.heading, .content, contentLine.contentRange, level: level)
        addSpan(.heading, .marker, ruleLine.contentRange, level: level)
        lineIndex += 2
        return true
    }

    private func setextLevel(_ line: MarkdownSourceLine) -> Int? {
        let compact = line.trimmed
        guard compact.count > 0, line.indentation <= 3 else { return nil }
        if compact.allSatisfy({ $0 == "=" }) { return 1 }
        if compact.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private mutating func parseThematicBreak() -> Bool {
        let line = map.lines[lineIndex]
        let compact = line.text.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let marker = compact.first,
              marker == "*" || marker == "-" || marker == "_",
              compact.allSatisfy({ $0 == marker }),
              line.indentation <= 3 else { return false }
        addSpan(.thematicBreak, .blockRule, line.contentRange)
        lineIndex += 1
        return true
    }

    private mutating func parseFootnoteDefinition() -> Bool {
        let line = map.lines[lineIndex]
        guard let match = firstMatch(#"^ {0,3}\[\^([^\]\r\n]+)\]:[ \t]*(.*)$"#, in: line.text),
              match.numberOfRanges == 3 else { return false }
        let labelLocal = match.range(at: 1)
        let bodyLocal = match.range(at: 2)
        let label = (line.text as NSString).substring(with: labelLocal)
        let markerLength = max(0, bodyLocal.location)
        let markerRange = NSRange(location: line.contentRange.location, length: markerLength)
        let firstBodyRange = bodyLocal.offset(by: line.contentRange.location)
        var lastLine = lineIndex
        while lastLine + 1 < map.lines.count {
            let continuation = map.lines[lastLine + 1]
            guard !continuation.isBlank, continuation.indentation >= 4 else { break }
            lastLine += 1
        }
        let bodyRange = NSRange(
            location: firstBodyRange.location,
            length: NSMaxRange(map.lines[lastLine].contentRange) - firstBodyRange.location
        )
        addSpan(.footnote, .marker, markerRange)
        addSpan(.footnote, .content, bodyRange)
        let content = parseInline(bodyRange)
        let paragraph = MarkdownBlock.paragraph(content: content, range: bodyRange.utf16)
        result.extensionBlocks.append(.footnoteDefinition(
            label: label,
            blocks: [paragraph],
            range: union(line.fullRange, map.lines[lastLine].fullRange).utf16
        ))
        lineIndex = lastLine + 1
        return true
    }

    private mutating func parseTable() -> Bool {
        guard mode == .full, lineIndex + 1 < map.lines.count else { return false }
        let headerLine = map.lines[lineIndex]
        let delimiterLine = map.lines[lineIndex + 1]
        guard headerLine.text.contains("|"),
              let alignments = tableAlignments(in: delimiterLine.text),
              alignments.count > 0 else { return false }
        let headerRanges = tableCellRanges(in: headerLine)
        guard headerRanges.count == alignments.count else { return false }
        var rowRanges: [[NSRange]] = []
        var cursor = lineIndex + 2
        while cursor < map.lines.count,
              !map.lines[cursor].isBlank,
              map.lines[cursor].text.contains("|") {
            let cells = tableCellRanges(in: map.lines[cursor])
            guard !cells.isEmpty else { break }
            rowRanges.append(cells)
            cursor += 1
        }

        for range in headerRanges + rowRanges.flatMap({ $0 }) {
            addSpan(.table, .content, range)
            _ = parseInline(range)
        }
        for pipe in pipeRanges(in: headerLine) { addSpan(.table, .marker, pipe) }
        for pipe in pipeRanges(in: delimiterLine) { addSpan(.table, .marker, pipe) }
        addSpan(.table, .blockRule, delimiterLine.contentRange)
        for row in lineIndex + 2..<cursor {
            for pipe in pipeRanges(in: map.lines[row]) { addSpan(.table, .marker, pipe) }
        }
        lineIndex = cursor
        return true
    }

    private func tableAlignments(in source: String) -> [MarkdownTableAlignment]? {
        let cells = splitTableCells(source)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for raw in cells {
            let cell = raw.trimmingCharacters(in: .whitespaces)
            guard firstMatch(#"^:?-{3,}:?$"#, in: cell) != nil else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.leading)
            case (false, true): alignments.append(.trailing)
            case (false, false): alignments.append(.none)
            }
        }
        return alignments
    }

    private func splitTableCells(_ source: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        var codeTicks = 0
        for character in source {
            if character == "\\", !escaped {
                escaped = true
                current.append(character)
                continue
            }
            if character == "`", !escaped { codeTicks = codeTicks == 0 ? 1 : 0 }
            if character == "|", !escaped, codeTicks == 0 {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            escaped = false
        }
        cells.append(current)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells
    }

    private func tableCellRanges(in line: MarkdownSourceLine) -> [NSRange] {
        let value = line.text as NSString
        let pipes = localPipeOffsets(in: value)
        var boundaries = [-1] + pipes + [value.length]
        if pipes.first == 0 { boundaries.removeFirst() }
        if pipes.last == value.length - 1 { boundaries.removeLast() }
        var ranges: [NSRange] = []
        for pair in zip(boundaries, boundaries.dropFirst()) {
            var start = pair.0 + 1
            var end = pair.1
            while start < end, isWhitespace(value.character(at: start)) { start += 1 }
            while end > start, isWhitespace(value.character(at: end - 1)) { end -= 1 }
            ranges.append(NSRange(
                location: line.contentRange.location + start,
                length: end - start
            ))
        }
        return ranges
    }

    private func pipeRanges(in line: MarkdownSourceLine) -> [NSRange] {
        localPipeOffsets(in: line.text as NSString).map {
            NSRange(location: line.contentRange.location + $0, length: 1)
        }
    }

    private func localPipeOffsets(in value: NSString) -> [Int] {
        var offsets: [Int] = []
        var escaped = false
        var inCode = false
        for index in 0..<value.length {
            let scalar = value.character(at: index)
            if scalar == 0x5C, !escaped { escaped = true; continue }
            if scalar == 0x60, !escaped { inCode.toggle() }
            if scalar == 0x7C, !escaped, !inCode { offsets.append(index) }
            escaped = false
        }
        return offsets
    }

    private mutating func parseList() -> Bool {
        guard let first = listPrefix(in: map.lines[lineIndex]) else { return false }
        let isOrdered = first.number != nil
        var cursor = lineIndex
        var itemCount = 0

        while cursor < map.lines.count,
              let prefix = listPrefix(in: map.lines[cursor]),
              (prefix.number != nil) == isOrdered {
            let line = map.lines[cursor]
            addSpan(isOrdered ? .orderedList : .unorderedList, .marker, prefix.marker)
            var bodyStart = NSMaxRange(prefix.marker)
            let lineEnd = NSMaxRange(line.contentRange)
            while bodyStart < lineEnd,
                  isWhitespace((map.source as NSString).character(at: bodyStart)) { bodyStart += 1 }
            if lineEnd - bodyStart >= 3 {
                let candidate = (map.source as NSString).substring(
                    with: NSRange(location: bodyStart, length: 3)
                ).lowercased()
                if candidate == "[ ]" || candidate == "[x]" {
                    addSpan(.task, .marker, NSRange(location: bodyStart, length: 3))
                    bodyStart += 3
                    while bodyStart < lineEnd,
                          isWhitespace((map.source as NSString).character(at: bodyStart)) { bodyStart += 1 }
                }
            }
            let bodyRange = NSRange(location: bodyStart, length: max(0, lineEnd - bodyStart))
            _ = parseInline(bodyRange)
            addSpan(isOrdered ? .orderedList : .unorderedList, .content, bodyRange)
            itemCount += 1
            cursor += 1
        }
        guard itemCount > 0 else { return false }
        lineIndex = cursor
        return true
    }

    private func listPrefix(in line: MarkdownSourceLine) -> (marker: NSRange, number: Int?)? {
        guard let match = firstMatch(#"^[ \t]*(?:([-+*])|([0-9]{1,9})[.)])(?=[ \t]+|$)"#, in: line.text)
        else { return nil }
        let marker = match.range.offset(by: line.contentRange.location)
        let numberRange = match.range(at: 2)
        let number = numberRange.location == NSNotFound
            ? nil
            : Int((line.text as NSString).substring(with: numberRange))
        return (marker, number)
    }

    private mutating func parseBlockquote() -> Bool {
        guard quotePrefix(in: map.lines[lineIndex]) != nil else { return false }
        var cursor = lineIndex
        while cursor < map.lines.count, let prefix = quotePrefix(in: map.lines[cursor]) {
            let line = map.lines[cursor]
            addSpan(.blockquote, .marker, prefix)
            var contentStart = NSMaxRange(prefix)
            let end = NSMaxRange(line.contentRange)
            if contentStart < end,
               isWhitespace((map.source as NSString).character(at: contentStart)) {
                contentStart += 1
            }
            let contentRange = NSRange(location: contentStart, length: max(0, end - contentStart))
            addSpan(.blockquote, .content, contentRange)
            _ = parseInline(contentRange)
            cursor += 1
        }
        lineIndex = cursor
        return true
    }

    private func quotePrefix(in line: MarkdownSourceLine) -> NSRange? {
        guard line.indentation <= 3,
              let match = firstMatch(#"^ {0,3}>"#, in: line.text) else { return nil }
        return match.range.offset(by: line.contentRange.location)
    }

    private mutating func parseRawHTML() -> Bool {
        let line = map.lines[lineIndex]
        let trimmed = line.trimmed
        guard mode == .full,
              trimmed.hasPrefix("<"), trimmed.hasSuffix(">"),
              firstMatch(#"^</?[A-Za-z][^>]*>$"#, in: trimmed) != nil else { return false }
        addSpan(.paragraph, .content, line.contentRange)
        lineIndex += 1
        return true
    }

    private mutating func parseParagraph() {
        let start = lineIndex
        var cursor = lineIndex + 1
        while cursor < map.lines.count, !map.lines[cursor].isBlank {
            if map.lines[cursor].fence != nil
                || looksLikeATXHeading(map.lines[cursor])
                || listPrefix(in: map.lines[cursor]) != nil
                || quotePrefix(in: map.lines[cursor]) != nil
                || looksLikeFootnote(map.lines[cursor])
                || isThematic(map.lines[cursor]) {
                break
            }
            cursor += 1
        }
        let end = cursor - 1
        let contentRange = NSRange(
            location: map.lines[start].contentRange.location,
            length: NSMaxRange(map.lines[end].contentRange) - map.lines[start].contentRange.location
        )
        _ = parseInline(contentRange)
        addSpan(.paragraph, .content, contentRange)
        lineIndex = cursor
    }

    private func looksLikeATXHeading(_ line: MarkdownSourceLine) -> Bool {
        firstMatch(#"^ {0,3}#{1,6}(?:[ \t]+|$)"#, in: line.text) != nil
    }

    private func looksLikeFootnote(_ line: MarkdownSourceLine) -> Bool {
        firstMatch(#"^ {0,3}\[\^[^\]]+\]:"#, in: line.text) != nil
    }

    private func isThematic(_ line: MarkdownSourceLine) -> Bool {
        let compact = line.text.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let first = compact.first,
              first == "*" || first == "-" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private mutating func parseInline(_ range: NSRange) -> [MarkdownInline] {
        guard mode == .full else {
            let value = map.substring(range)
            return value.isEmpty ? [] : [.text(value: value, range: range.utf16)]
        }
        var parser = MarkdownMarkerLexer(
            source: map.source,
            range: range,
            spans: result.spans
        )
        let content = parser.parse()
        result.spans = parser.spans
        result.diagnostics.append(contentsOf: parser.diagnostics)
        return content
    }

    private mutating func addSpan(
        _ kind: MarkdownSemanticKind,
        _ role: MarkdownSpanRole,
        _ range: NSRange,
        level: Int? = nil
    ) {
        guard range.length > 0 else { return }
        let clamped: NSRange
        if let spanLimit {
            guard range.location < spanLimit else { return }
            clamped = NSRange(
                location: range.location,
                length: min(range.length, spanLimit - range.location)
            )
        } else {
            clamped = range
        }
        guard clamped.length > 0 else { return }
        result.spans.append(MarkdownSpan(
            kind: kind,
            role: role,
            range: clamped.utf16,
            level: level
        ))
    }
}

func firstMatch(_ pattern: String, in source: String) -> NSTextCheckingResult? {
    guard let regex = MarkdownRegexCache.shared.regex(for: pattern) else { return nil }
    return regex.firstMatch(
        in: source,
        range: NSRange(location: 0, length: (source as NSString).length)
    )
}

private final class MarkdownRegexCache: @unchecked Sendable {
    static let shared = MarkdownRegexCache()
    private var storage: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func regex(for pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = storage[pattern] { return cached }
        guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
        storage[pattern] = compiled
        return compiled
    }
}

private func union(_ first: NSRange, _ last: NSRange) -> NSRange {
    NSRange(location: first.location, length: max(0, NSMaxRange(last) - first.location))
}

private func isWhitespace(_ scalar: unichar) -> Bool {
    scalar == 0x20 || scalar == 0x09
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }
    func offset(by amount: Int) -> NSRange {
        NSRange(location: location + amount, length: length)
    }
}
