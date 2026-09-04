import Foundation

/// Source-marker lexer used for presentation and Clio-only footnote syntax.
/// CommonMark/GFM semantic interpretation is owned by swift-markdown.
struct MarkdownMarkerLexer {
    private let source: NSString
    private let range: NSRange
    private var cursor: Int
    private var plainStart: Int
    var spans: [MarkdownSpan]
    var diagnostics: [MarkdownDiagnostic] = []

    init(source: String, range: NSRange, spans: [MarkdownSpan] = []) {
        self.source = source as NSString
        let location = min(max(0, range.location), self.source.length)
        self.range = NSRange(
            location: location,
            length: min(max(0, range.length), self.source.length - location)
        )
        cursor = location
        plainStart = location
        self.spans = spans
    }

    mutating func parse() -> [MarkdownInline] {
        var nodes: [MarkdownInline] = []
        let end = NSMaxRange(range)
        while cursor < end {
            if cursor.isMultiple(of: 4_096), Task.isCancelled {
                cursor = end
                break
            }
            let scalar = source.character(at: cursor)
            if scalar == 0x5C, cursor + 1 < end {
                cursor += 2
                continue
            }
            if scalar == 0x0A || scalar == 0x0D {
                flushText(into: &nodes, through: cursor)
                let newlineLength = scalar == 0x0D && cursor + 1 < end
                    && source.character(at: cursor + 1) == 0x0A ? 2 : 1
                let breakRange = NSRange(location: cursor, length: newlineLength)
                let hard = cursor >= 2
                    && source.substring(with: NSRange(location: cursor - 2, length: 2)) == "  "
                nodes.append(hard ? .hardBreak(range: breakRange.utf16) : .softBreak(range: breakRange.utf16))
                cursor += newlineLength
                plainStart = cursor
                continue
            }
            if scalar == 0x60, parseCode(into: &nodes) { continue }
            if scalar == 0x21, cursor + 1 < end,
               source.character(at: cursor + 1) == 0x5B,
               parseLink(into: &nodes, isImage: true) { continue }
            if scalar == 0x5B {
                if parseFootnote(into: &nodes) { continue }
                if parseLink(into: &nodes, isImage: false) { continue }
            }
            if scalar == 0x3C, parseAngleConstruct(into: &nodes) { continue }
            if scalar == 0x7E, hasMarker("~~", at: cursor),
               parseDelimited("~~", kind: .strikethrough, into: &nodes) { continue }
            if scalar == 0x2A || scalar == 0x5F {
                let single = String(UnicodeScalar(scalar)!)
                if hasMarker(single + single, at: cursor),
                   parseDelimited(single + single, kind: .strong, into: &nodes) { continue }
                if parseDelimited(single, kind: .emphasis, into: &nodes) { continue }
            }
            if startsURL(at: cursor), parseBareURL(into: &nodes) { continue }
            if isEmailStart(at: cursor), parseBareEmail(into: &nodes) { continue }
            cursor += 1
        }
        flushText(into: &nodes, through: end)
        return nodes
    }

    private mutating func parseCode(into nodes: inout [MarkdownInline]) -> Bool {
        let end = NSMaxRange(range)
        var count = 0
        while cursor + count < end, source.character(at: cursor + count) == 0x60 { count += 1 }
        let marker = String(repeating: "`", count: count)
        let search = NSRange(location: cursor + count, length: end - cursor - count)
        let closing = source.range(of: marker, options: [], range: search)
        guard closing.location != NSNotFound else { return false }
        flushText(into: &nodes, through: cursor)
        let opening = NSRange(location: cursor, length: count)
        let content = NSRange(location: NSMaxRange(opening), length: closing.location - NSMaxRange(opening))
        let whole = NSRange(location: cursor, length: NSMaxRange(closing) - cursor)
        addSpan(.inlineCode, .marker, opening)
        addSpan(.inlineCode, .content, content)
        addSpan(.inlineCode, .marker, closing)
        var value = source.substring(with: content)
        if value.hasPrefix(" "), value.hasSuffix(" "), value.count > 2,
           value.trimmingCharacters(in: .whitespaces).isEmpty == false {
            value.removeFirst(); value.removeLast()
        }
        nodes.append(.code(value: value, range: whole.utf16))
        advance(to: NSMaxRange(whole))
        return true
    }

    private mutating func parseDelimited(
        _ marker: String,
        kind: MarkdownSemanticKind,
        into nodes: inout [MarkdownInline]
    ) -> Bool {
        let markerLength = (marker as NSString).length
        let searchStart = cursor + markerLength
        let end = NSMaxRange(range)
        guard searchStart < end else { return false }
        guard let closing = closingMarker(
            marker,
            in: NSRange(location: searchStart, length: end - searchStart)
        ), closing.location > searchStart else { return false }
        // Intraword underscores are ordinary source, matching CommonMark's
        // most important delimiter constraint without obscuring markers.
        if marker.first == "_", cursor > range.location,
           isWord(source.character(at: cursor - 1)),
           isWord(source.character(at: searchStart)) { return false }

        flushText(into: &nodes, through: cursor)
        let opening = NSRange(location: cursor, length: markerLength)
        let contentRange = NSRange(location: searchStart, length: closing.location - searchStart)
        let whole = NSRange(location: cursor, length: NSMaxRange(closing) - cursor)
        addSpan(kind, .marker, opening)
        addSpan(kind, .content, contentRange)
        var nested = MarkdownMarkerLexer(
            source: source as String,
            range: contentRange,
            spans: spans
        )
        let content = nested.parse()
        spans = nested.spans
        diagnostics.append(contentsOf: nested.diagnostics)
        addSpan(kind, .marker, closing)
        switch kind {
        case .strong: nodes.append(.strong(content: content, range: whole.utf16))
        case .strikethrough: nodes.append(.strikethrough(content: content, range: whole.utf16))
        default: nodes.append(.emphasis(content: content, range: whole.utf16))
        }
        advance(to: NSMaxRange(whole))
        return true
    }

    private mutating func parseFootnote(into nodes: inout [MarkdownInline]) -> Bool {
        guard hasMarker("[^", at: cursor),
              let closing = index(of: "]", after: cursor + 2),
              closing > cursor + 2 else { return false }
        flushText(into: &nodes, through: cursor)
        let whole = NSRange(location: cursor, length: closing + 1 - cursor)
        let labelRange = NSRange(location: cursor + 2, length: closing - cursor - 2)
        addSpan(.footnote, .marker, NSRange(location: cursor, length: 2))
        addSpan(.footnote, .content, labelRange)
        addSpan(.footnote, .marker, NSRange(location: closing, length: 1))
        nodes.append(.footnoteReference(
            label: source.substring(with: labelRange),
            range: whole.utf16
        ))
        advance(to: NSMaxRange(whole))
        return true
    }

    private mutating func parseLink(into nodes: inout [MarkdownInline], isImage: Bool) -> Bool {
        let opening = cursor + (isImage ? 1 : 0)
        guard source.character(at: opening) == 0x5B,
              let bracket = matchingBracket(from: opening),
              bracket + 1 < NSMaxRange(range), source.character(at: bracket + 1) == 0x28,
              let paren = matchingParen(from: bracket + 1) else { return false }
        flushText(into: &nodes, through: cursor)
        let labelRange = NSRange(location: opening + 1, length: bracket - opening - 1)
        let targetRange = NSRange(location: bracket + 2, length: paren - bracket - 2)
        let parsedTarget = linkTarget(source.substring(with: targetRange))
        let whole = NSRange(location: cursor, length: paren + 1 - cursor)
        addSpan(.link, .marker, NSRange(location: cursor, length: isImage ? 2 : 1))
        addSpan(.link, .content, labelRange)
        addSpan(.link, .marker, NSRange(location: bracket, length: 2))
        addSpan(
            .link,
            .destination,
            parsedTarget.destinationRange.offset(by: targetRange.location)
        )
        addSpan(.link, .marker, NSRange(location: paren, length: 1))
        var nested = MarkdownMarkerLexer(source: source as String, range: labelRange, spans: spans)
        let content = nested.parse()
        spans = nested.spans
        if isImage {
            nodes.append(.image(
                source: parsedTarget.destination,
                title: parsedTarget.title,
                alt: content,
                range: whole.utf16
            ))
        } else {
            nodes.append(.link(
                destination: parsedTarget.destination,
                title: parsedTarget.title,
                content: content,
                range: whole.utf16
            ))
        }
        advance(to: NSMaxRange(whole))
        return true
    }

    private mutating func parseAngleConstruct(into nodes: inout [MarkdownInline]) -> Bool {
        guard let close = index(of: ">", after: cursor + 1) else { return false }
        let bodyRange = NSRange(location: cursor + 1, length: close - cursor - 1)
        let body = source.substring(with: bodyRange)
        let destination: String?
        if body.hasPrefix("http://") || body.hasPrefix("https://") {
            destination = body
        } else if isEmail(body) {
            destination = "mailto:" + body
        } else {
            destination = nil
        }
        let whole = NSRange(location: cursor, length: close + 1 - cursor)
        guard let destination else {
            guard firstMatch(#"^/?[A-Za-z][^>]*$"#, in: body) != nil else { return false }
            flushText(into: &nodes, through: cursor)
            addSpan(.paragraph, .marker, whole)
            nodes.append(.rawHTML(source: source.substring(with: whole), range: whole.utf16))
            advance(to: NSMaxRange(whole))
            return true
        }
        flushText(into: &nodes, through: cursor)
        addSpan(.autolink, .marker, NSRange(location: cursor, length: 1))
        addSpan(.autolink, .destination, bodyRange)
        addSpan(.autolink, .marker, NSRange(location: close, length: 1))
        nodes.append(.autolink(text: body, destination: destination, range: whole.utf16))
        advance(to: NSMaxRange(whole))
        return true
    }

    private mutating func parseBareURL(into nodes: inout [MarkdownInline]) -> Bool {
        let end = NSMaxRange(range)
        var urlEnd = cursor
        while urlEnd < end {
            let scalar = source.character(at: urlEnd)
            guard !isUnicodeWhitespace(scalar),
                  scalar != 0x3C, scalar != 0x3E else { break }
            urlEnd += 1
        }
        while urlEnd > cursor,
              [0x2E, 0x2C, 0x3A, 0x3B, 0x21, 0x3F].contains(source.character(at: urlEnd - 1)) {
            urlEnd -= 1
        }
        guard urlEnd > cursor else { return false }
        flushText(into: &nodes, through: cursor)
        let urlRange = NSRange(location: cursor, length: urlEnd - cursor)
        let display = source.substring(with: urlRange)
        let destination = display.hasPrefix("www.") ? "http://" + display : display
        addSpan(.autolink, .destination, urlRange)
        nodes.append(.autolink(text: display, destination: destination, range: urlRange.utf16))
        advance(to: urlEnd)
        return true
    }

    private mutating func parseBareEmail(into nodes: inout [MarkdownInline]) -> Bool {
        let tail = NSRange(location: cursor, length: NSMaxRange(range) - cursor)
        guard let regex = try? NSRegularExpression(
            pattern: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+"#
        ), let match = regex.firstMatch(in: source as String, range: tail) else { return false }
        flushText(into: &nodes, through: cursor)
        let email = source.substring(with: match.range)
        addSpan(.autolink, .destination, match.range)
        nodes.append(.autolink(
            text: email,
            destination: "mailto:" + email,
            range: match.range.utf16
        ))
        advance(to: NSMaxRange(match.range))
        return true
    }

    private func startsURL(at location: Int) -> Bool {
        hasMarker("https://", at: location)
            || hasMarker("http://", at: location)
            || hasMarker("www.", at: location)
    }

    private func isEmailStart(at location: Int) -> Bool {
        guard location == range.location || !isWord(source.character(at: location - 1)) else {
            return false
        }
        guard isWord(source.character(at: location)) else { return false }
        let end = min(NSMaxRange(range), location + 320)
        var cursor = location
        var foundAt = false
        var foundDotAfterAt = false
        while cursor < end {
            let scalar = source.character(at: cursor)
            if isUnicodeWhitespace(scalar) { break }
            if scalar == 0x40 { foundAt = true }
            if scalar == 0x2E, foundAt { foundDotAfterAt = true }
            cursor += 1
        }
        return foundAt && foundDotAfterAt
    }

    private func isEmail(_ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        ) else { return false }
        let range = NSRange(location: 0, length: (value as NSString).length)
        return regex.firstMatch(in: value, range: range)?.range == range
    }

    private func linkTarget(
        _ value: String
    ) -> (destination: String, title: String?, destinationRange: NSRange) {
        let raw = value as NSString
        var lower = 0
        var upper = raw.length
        while lower < upper, isUnicodeWhitespace(raw.character(at: lower)) { lower += 1 }
        while upper > lower, isUnicodeWhitespace(raw.character(at: upper - 1)) { upper -= 1 }
        let trimmed = raw.substring(with: NSRange(location: lower, length: upper - lower))
        guard let match = firstMatch(#"^(?:<([^>]*)>|(\S+?))(?:[ \t]+[\"'](.*)[\"'])?$"#, in: trimmed)
        else { return (trimmed, nil, NSRange(location: lower, length: upper - lower)) }
        let text = trimmed as NSString
        let angle = match.range(at: 1)
        let plain = match.range(at: 2)
        let title = match.range(at: 3)
        let destinationRange = angle.location != NSNotFound ? angle : plain
        return (
            text.substring(with: destinationRange),
            title.location == NSNotFound ? nil : text.substring(with: title),
            destinationRange.offset(by: lower)
        )
    }

    private func matchingBracket(from opening: Int) -> Int? {
        matching(open: 0x5B, close: 0x5D, from: opening)
    }

    private func matchingParen(from opening: Int) -> Int? {
        matching(open: 0x28, close: 0x29, from: opening)
    }

    private func matching(open: unichar, close: unichar, from opening: Int) -> Int? {
        var depth = 0
        var escaped = false
        for location in opening..<NSMaxRange(range) {
            let scalar = source.character(at: location)
            if scalar == 0x5C, !escaped { escaped = true; continue }
            if !escaped {
                if scalar == open { depth += 1 }
                if scalar == close {
                    depth -= 1
                    if depth == 0 { return location }
                }
            }
            escaped = false
        }
        return nil
    }

    private func index(of character: String, after start: Int) -> Int? {
        let end = NSMaxRange(range)
        guard start < end else { return nil }
        let found = source.range(
            of: character,
            options: [],
            range: NSRange(location: start, length: end - start)
        )
        return found.location == NSNotFound ? nil : found.location
    }

    private func hasMarker(_ marker: String, at location: Int) -> Bool {
        let length = (marker as NSString).length
        guard location + length <= NSMaxRange(range) else { return false }
        return source.substring(with: NSRange(location: location, length: length)) == marker
    }

    private func closingMarker(_ marker: String, in searchRange: NSRange) -> NSRange? {
        var remaining = searchRange
        while remaining.length > 0 {
            let found = source.range(of: marker, options: [], range: remaining)
            guard found.location != NSNotFound else { return nil }
            var slashCount = 0
            var cursor = found.location
            while cursor > range.location, source.character(at: cursor - 1) == 0x5C {
                slashCount += 1
                cursor -= 1
            }
            if slashCount.isMultiple(of: 2) { return found }
            let next = NSMaxRange(found)
            remaining = NSRange(location: next, length: NSMaxRange(searchRange) - next)
        }
        return nil
    }

    private mutating func flushText(into nodes: inout [MarkdownInline], through end: Int) {
        guard end > plainStart else { return }
        let textRange = NSRange(location: plainStart, length: end - plainStart)
        nodes.append(.text(value: source.substring(with: textRange), range: textRange.utf16))
    }

    private mutating func advance(to location: Int) {
        cursor = location
        plainStart = location
    }

    private mutating func addSpan(
        _ kind: MarkdownSemanticKind,
        _ role: MarkdownSpanRole,
        _ range: NSRange
    ) {
        guard range.length > 0 else { return }
        spans.append(MarkdownSpan(kind: kind, role: role, range: range.utf16))
    }
}

private func isWord(_ scalar: unichar) -> Bool {
    guard let unicode = UnicodeScalar(scalar) else { return false }
    return CharacterSet.alphanumerics.contains(unicode) || scalar == 0x5F
}

private func isUnicodeWhitespace(_ scalar: unichar) -> Bool {
    guard let unicode = UnicodeScalar(scalar) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(unicode)
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }

    func offset(by amount: Int) -> NSRange {
        NSRange(location: location + amount, length: length)
    }
}
