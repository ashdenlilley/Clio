import Foundation

struct MarkdownTextEdit: Equatable, Sendable {
    let replacedRange: UTF16Range
    let replacement: String

    init(replacedRange: UTF16Range, replacement: String) {
        self.replacedRange = replacedRange
        self.replacement = replacement
    }
}

struct MarkdownInvalidation: Equatable, Sendable {
    let oldRange: UTF16Range
    let newRange: UTF16Range
}

/// Expands edits to stable block boundaries. This is deliberately independent
/// of AppKit so background parsing and tests use the same UTF-16 arithmetic as
/// NSTextView.
enum MarkdownInvalidationPlanner {
    static func ranges(for edit: MarkdownTextEdit, in source: String) -> MarkdownInvalidation {
        let oldText = source as NSString
        let oldRange = NSRange(
            location: min(edit.replacedRange.location, oldText.length),
            length: min(
                edit.replacedRange.length,
                max(0, oldText.length - min(edit.replacedRange.location, oldText.length))
            )
        )
        let mutable = NSMutableString(string: source)
        mutable.replaceCharacters(in: oldRange, with: edit.replacement)
        let newSource = mutable as String
        let insertedLength = (edit.replacement as NSString).length

        return MarkdownInvalidation(
            oldRange: expandedBlockRange(
                around: oldRange,
                in: source
            ),
            newRange: expandedBlockRange(
                around: NSRange(location: oldRange.location, length: insertedLength),
                in: newSource
            )
        )
    }

    static func expandedBlockRange(around range: NSRange, in source: String) -> UTF16Range {
        let map = MarkdownSource(source)
        guard !map.lines.isEmpty else { return UTF16Range(location: 0, length: 0) }

        let lowerOffset = min(range.location, map.length)
        let upperOffset = min(max(lowerOffset, NSMaxRange(range)), map.length)
        var lower = map.lineIndex(containing: lowerOffset)
        var upper = map.lineIndex(containing: max(lowerOffset, upperOffset - 1))

        while lower > 0,
              !map.lines[lower].isBlank,
              !map.lines[lower - 1].isBlank {
            lower -= 1
        }
        while upper + 1 < map.lines.count,
              !map.lines[upper].isBlank,
              !map.lines[upper + 1].isBlank {
            upper += 1
        }

        // Adjacent lines can change list, setext-heading, table, and delimiter
        // interpretation. Include one context line, but never walk through a
        // blank separator into a second unrelated block.
        lower = max(0, lower - 1)
        upper = min(map.lines.count - 1, upper + 1)

        // A fence or front-matter delimiter can affect every following line.
        var openFence: (marker: MarkdownFence, line: Int)?
        var index = 0
        while index < lower {
            if let fence = map.lines[index].fence {
                if let active = openFence,
                   active.marker.character == fence.character,
                   fence.count >= active.marker.count,
                   fence.infoRange == nil {
                    openFence = nil
                } else if openFence == nil {
                    openFence = (fence, index)
                }
            }
            index += 1
        }
        if let active = openFence { lower = active.line }
        if map.lines.first?.trimmed == "---" {
            let frontMatterClosing = frontMatterEnd(in: map)
            if lower <= frontMatterClosing {
                lower = 0
                upper = max(upper, frontMatterClosing)
            }
        }
        if let fence = openFence?.marker ?? map.lines[lower].fence {
            var cursor = max(lower + 1, index)
            while cursor < map.lines.count {
                if let candidate = map.lines[cursor].fence,
                   candidate.character == fence.character,
                   candidate.count >= fence.count,
                   candidate.infoRange == nil {
                    upper = max(upper, cursor)
                    break
                }
                cursor += 1
            }
            if cursor == map.lines.count { upper = map.lines.count - 1 }
        }

        let start = map.lines[lower].fullRange.location
        let end = NSMaxRange(map.lines[upper].fullRange)
        return UTF16Range(location: start, length: max(0, end - start))
    }

    private static func frontMatterEnd(in source: MarkdownSource) -> Int {
        guard source.lines.count > 1 else { return 0 }
        for index in 1..<source.lines.count
        where source.lines[index].trimmed == "---" || source.lines[index].trimmed == "..." {
            return index
        }
        return source.lines.count - 1
    }
}

struct MarkdownFence: Equatable, Sendable {
    let character: unichar
    let count: Int
    let markerRange: NSRange
    let infoRange: NSRange?
}

struct MarkdownSourceLine: Sendable {
    let fullRange: NSRange
    let contentRange: NSRange
    let text: String

    var trimmed: String { text.trimmingCharacters(in: .whitespaces) }
    var isBlank: Bool { trimmed.isEmpty }

    var indentation: Int {
        var count = 0
        for character in text {
            guard character == " " else { break }
            count += 1
        }
        return count
    }

    var fence: MarkdownFence? {
        let value = text as NSString
        let indent = min(indentation, value.length)
        guard indent <= 3, value.length - indent >= 3 else { return nil }
        let character = value.character(at: indent)
        guard character == 0x60 || character == 0x7E else { return nil }
        var count = 0
        while indent + count < value.length,
              value.character(at: indent + count) == character { count += 1 }
        guard count >= 3 else { return nil }
        var infoStart = indent + count
        while infoStart < value.length,
              value.character(at: infoStart) == 0x20 || value.character(at: infoStart) == 0x09 {
            infoStart += 1
        }
        let info = infoStart < value.length
            ? NSRange(location: contentRange.location + infoStart, length: value.length - infoStart)
            : nil
        return MarkdownFence(
            character: character,
            count: count,
            markerRange: NSRange(location: contentRange.location + indent, length: count),
            infoRange: info
        )
    }
}

struct MarkdownSource: Sendable {
    let source: String
    let length: Int
    let lines: [MarkdownSourceLine]

    init(_ source: String) {
        self.source = source
        let text = source as NSString
        length = text.length
        guard text.length > 0 else {
            lines = [MarkdownSourceLine(
                fullRange: NSRange(location: 0, length: 0),
                contentRange: NSRange(location: 0, length: 0),
                text: ""
            )]
            return
        }

        var records: [MarkdownSourceLine] = []
        var location = 0
        while location < text.length {
            let full = text.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(full)
            while contentEnd > full.location {
                let scalar = text.character(at: contentEnd - 1)
                guard scalar == 0x0A || scalar == 0x0D else { break }
                contentEnd -= 1
            }
            let content = NSRange(location: full.location, length: contentEnd - full.location)
            records.append(MarkdownSourceLine(
                fullRange: full,
                contentRange: content,
                text: text.substring(with: content)
            ))
            location = NSMaxRange(full)
        }
        lines = records
    }

    func lineIndex(containing offset: Int) -> Int {
        let target = min(max(0, offset), length)
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(lines[mid].fullRange) <= target, mid + 1 < lines.count {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return min(low, lines.count - 1)
    }

    func substring(_ range: NSRange) -> String {
        let safeLocation = min(max(0, range.location), length)
        let safeLength = min(max(0, range.length), length - safeLocation)
        return (source as NSString).substring(
            with: NSRange(location: safeLocation, length: safeLength)
        )
    }
}

extension MarkdownHighlightingMode {
    init(sizeMode: DocumentSizeMode) {
        switch sizeMode {
        case .full: self = .full
        case .safeLargeFile: self = .reduced
        case .unsupported: self = .unsupported
        }
    }
}
