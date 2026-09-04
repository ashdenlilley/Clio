import Foundation

/// Linear, cancellable model scan for Clio's two non-CommonMark extensions.
/// It is intentionally independent from the bounded presentation lexer so a
/// footnote near the end of a 10–50 MiB document remains exportable.
struct MarkdownExtensionModelScanner {
    private let source: NSString

    init(_ source: String) {
        self.source = source as NSString
    }

    func scan() throws -> [MarkdownBlock] {
        guard source.length > 0 else { return [] }
        var blocks: [MarkdownBlock] = []
        var cursor = 0
        if let frontMatter = try scanFrontMatter() {
            blocks.append(frontMatter.block)
            cursor = frontMatter.end
        }
        var lineCount = 0
        while cursor < source.length {
            if lineCount.isMultiple(of: 256) { try Task.checkCancellation() }
            let line = lineRange(at: cursor)
            if let definition = footnote(at: line) {
                blocks.append(definition.block)
                cursor = definition.end
            } else {
                cursor = NSMaxRange(line)
            }
            lineCount += 1
        }
        return blocks
    }

    private func scanFrontMatter() throws -> (block: MarkdownBlock, end: Int)? {
        guard source.length >= 3,
              source.character(at: 0) == 0x2D,
              source.character(at: 1) == 0x2D,
              source.character(at: 2) == 0x2D else { return nil }
        let first = lineRange(at: 0)
        guard equalsTrimmed(first, "---") else { return nil }
        var cursor = NSMaxRange(first)
        var lineCount = 0
        while cursor < source.length {
            if lineCount.isMultiple(of: 256) { try Task.checkCancellation() }
            let line = lineRange(at: cursor)
            if equalsTrimmed(line, "---") || equalsTrimmed(line, "...") {
                let range = NSRange(location: 0, length: NSMaxRange(line))
                return (
                    .frontMatter(source: source.substring(with: range), range: range.utf16),
                    NSMaxRange(line)
                )
            }
            cursor = NSMaxRange(line)
            lineCount += 1
        }
        return nil
    }

    private func footnote(
        at line: NSRange
    ) -> (block: MarkdownBlock, end: Int)? {
        let content = contentRange(of: line)
        var cursor = content.location
        var indentation = 0
        while cursor < NSMaxRange(content), source.character(at: cursor) == 0x20,
              indentation < 4 {
            cursor += 1
            indentation += 1
        }
        guard indentation <= 3,
              cursor + 3 < NSMaxRange(content),
              source.character(at: cursor) == 0x5B,
              source.character(at: cursor + 1) == 0x5E else { return nil }
        let labelStart = cursor + 2
        var close = labelStart
        while close < NSMaxRange(content), source.character(at: close) != 0x5D { close += 1 }
        guard close > labelStart,
              close + 1 < NSMaxRange(content),
              source.character(at: close + 1) == 0x3A else { return nil }
        let label = source.substring(with: NSRange(location: labelStart, length: close - labelStart))
        var bodyStart = close + 2
        while bodyStart < NSMaxRange(content), isHorizontalSpace(source.character(at: bodyStart)) {
            bodyStart += 1
        }
        var last = line
        var next = NSMaxRange(line)
        while next < source.length {
            let candidate = lineRange(at: next)
            let candidateContent = contentRange(of: candidate)
            var indentation = 0
            while indentation < candidateContent.length,
                  source.character(at: candidateContent.location + indentation) == 0x20 {
                indentation += 1
            }
            guard indentation >= 4 else { break }
            last = candidate
            next = NSMaxRange(candidate)
        }
        let bodyRange = NSRange(
            location: bodyStart,
            length: max(0, NSMaxRange(contentRange(of: last)) - bodyStart)
        )
        let whole = NSRange(location: line.location, length: NSMaxRange(last) - line.location)
        let text = MarkdownInline.text(value: source.substring(with: bodyRange), range: bodyRange.utf16)
        return (
            .footnoteDefinition(
                label: label,
                blocks: [.paragraph(content: [text], range: bodyRange.utf16)],
                range: whole.utf16
            ),
            NSMaxRange(last)
        )
    }

    private func lineRange(at offset: Int) -> NSRange {
        source.lineRange(for: NSRange(location: min(offset, source.length), length: 0))
    }

    private func contentRange(of line: NSRange) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location {
            let scalar = source.character(at: end - 1)
            guard scalar == 0x0A || scalar == 0x0D else { break }
            end -= 1
        }
        return NSRange(location: line.location, length: end - line.location)
    }

    private func equalsTrimmed(_ line: NSRange, _ expected: String) -> Bool {
        let content = contentRange(of: line)
        var lower = content.location
        var upper = NSMaxRange(content)
        while lower < upper, isHorizontalSpace(source.character(at: lower)) { lower += 1 }
        while upper > lower, isHorizontalSpace(source.character(at: upper - 1)) { upper -= 1 }
        return source.substring(with: NSRange(location: lower, length: upper - lower)) == expected
    }

    private func isHorizontalSpace(_ scalar: unichar) -> Bool {
        scalar == 0x20 || scalar == 0x09
    }
}

private extension NSRange {
    var utf16: UTF16Range { UTF16Range(location: location, length: length) }
}
