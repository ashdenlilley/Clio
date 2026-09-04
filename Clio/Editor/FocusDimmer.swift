import AppKit

/// Applies focus mode as TextKit 2 rendering attributes. The underlying
/// attributed source remains untouched, so syntax highlighting and copied text
/// retain their own attributes and exact characters.
final class FocusDimmer {
    func apply(to textView: NSTextView, configuration: EditorConfiguration) {
        clear(in: textView)
        guard configuration.isFocusModeEnabled,
              let focusRange = Self.focusRange(
                in: textView.string,
                selection: textView.selectedRange()
              ),
              let contentStorage = textView.textContentStorage,
              let layoutManager = textView.textLayoutManager else { return }

        let sourceLength = (textView.string as NSString).length
        let dimmedColor = Palette.foreground.withAlphaComponent(
            configuration.resolvedFocusDimmingOpacity
        )

        if focusRange.location > 0,
           let leadingRange = Self.textRange(
               for: NSRange(location: 0, length: focusRange.location),
               contentStorage: contentStorage,
               documentLength: sourceLength
           ) {
            layoutManager.setRenderingAttributes(
                [.foregroundColor: dimmedColor],
                for: leadingRange
            )
        }

        let focusEnd = NSMaxRange(focusRange)
        if focusEnd < sourceLength,
           let trailingRange = Self.textRange(
               for: NSRange(location: focusEnd, length: sourceLength - focusEnd),
               contentStorage: contentStorage,
               documentLength: sourceLength
           ) {
            layoutManager.setRenderingAttributes(
                [.foregroundColor: dimmedColor],
                for: trailingRange
            )
        }
    }

    func clear(in textView: NSTextView) {
        guard let contentStorage = textView.textContentStorage,
              let layoutManager = textView.textLayoutManager else { return }
        layoutManager.invalidateRenderingAttributes(for: contentStorage.documentRange)
    }

    /// Returns the current unit of thought, or `nil` when a selection crosses
    /// units and focus mode should be suppressed.
    static func focusRange(in string: String, selection: NSRange) -> NSRange? {
        let source = string as NSString
        let lines = Line.records(in: source)
        guard !lines.isEmpty else { return NSRange(location: 0, length: 0) }

        let sourceLength = source.length
        let startOffset = min(selection.location, sourceLength)
        let endOffset: Int
        if selection.length == 0 {
            endOffset = startOffset
        } else {
            endOffset = min(max(startOffset, NSMaxRange(selection) - 1), sourceLength)
        }

        guard let startIndex = Line.index(containing: startOffset, in: lines),
              let endIndex = Line.index(containing: endOffset, in: lines) else {
            return NSRange(location: 0, length: sourceLength)
        }

        let firstUnit = unitRange(containing: startIndex, lines: lines)
        let lastUnit = unitRange(containing: endIndex, lines: lines)
        guard firstUnit == lastUnit else { return nil }
        return firstUnit
    }

    private static func unitRange(containing index: Int, lines: [Line]) -> NSRange {
        if let fencedRange = fencedBlock(containing: index, lines: lines) {
            return fencedRange
        }

        let current = lines[index]
        if current.isBlank {
            return current.range
        }

        if current.isListItem {
            return contiguousRange(containing: index, lines: lines) { line in
                !line.isBlank && (line.isListItem || line.isIndentedContinuation)
            }
        }

        if current.isBlockquote {
            return contiguousRange(containing: index, lines: lines) { line in
                line.isBlockquote
            }
        }

        if current.isHeading || current.isThematicBreak || current.fenceMarker != nil {
            return current.range
        }

        return contiguousRange(containing: index, lines: lines) { line in
            !line.isBlank
                && !line.isListItem
                && !line.isBlockquote
                && !line.isHeading
                && !line.isThematicBreak
                && line.fenceMarker == nil
        }
    }

    private static func fencedBlock(containing index: Int, lines: [Line]) -> NSRange? {
        var opening: (index: Int, marker: FenceMarker)?

        for lineIndex in lines.indices {
            guard let marker = lines[lineIndex].fenceMarker else { continue }

            if let active = opening {
                guard marker.character == active.marker.character,
                      marker.count >= active.marker.count else { continue }
                if index >= active.index && index <= lineIndex {
                    return union(lines[active.index].range, lines[lineIndex].range)
                }
                opening = nil
            } else {
                opening = (lineIndex, marker)
            }
        }

        if let active = opening, index >= active.index {
            return union(lines[active.index].range, lines[lines.count - 1].range)
        }
        return nil
    }

    private static func contiguousRange(
        containing index: Int,
        lines: [Line],
        includes: (Line) -> Bool
    ) -> NSRange {
        var lower = index
        var upper = index
        while lower > 0, includes(lines[lower - 1]) { lower -= 1 }
        while upper + 1 < lines.count, includes(lines[upper + 1]) { upper += 1 }
        return union(lines[lower].range, lines[upper].range)
    }

    private static func union(_ first: NSRange, _ last: NSRange) -> NSRange {
        NSRange(
            location: first.location,
            length: NSMaxRange(last) - first.location
        )
    }

    private static func textRange(
        for range: NSRange,
        contentStorage: NSTextContentStorage,
        documentLength: Int
    ) -> NSTextRange? {
        guard range.location <= documentLength,
              NSMaxRange(range) <= documentLength else { return nil }
        let documentRange = contentStorage.documentRange
        guard let start = contentStorage.location(
            documentRange.location,
            offsetBy: range.location
        ), let end = contentStorage.location(start, offsetBy: range.length) else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }
}

private struct FenceMarker {
    let character: Character
    let count: Int
}

private struct Line {
    let range: NSRange
    let content: String

    var trimmed: String {
        content.trimmingCharacters(in: .whitespaces)
    }

    var isBlank: Bool { trimmed.isEmpty }

    var isListItem: Bool {
        content.range(
            of: #"^\s*(?:[-+*]|\d+[.)])\s+"#,
            options: .regularExpression
        ) != nil
    }

    var isIndentedContinuation: Bool {
        guard !isBlank else { return false }
        return content.hasPrefix("  ") || content.hasPrefix("\t")
    }

    var isBlockquote: Bool {
        content.range(of: #"^\s{0,3}>"#, options: .regularExpression) != nil
    }

    var isHeading: Bool {
        content.range(of: #"^\s{0,3}#{1,6}(?:\s|$)"#, options: .regularExpression) != nil
    }

    var isThematicBreak: Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    var fenceMarker: FenceMarker? {
        let candidate = content.drop(while: { $0 == " " })
        let indentation = content.count - candidate.count
        guard indentation <= 3, let first = candidate.first,
              first == "`" || first == "~" else { return nil }
        let count = candidate.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        return FenceMarker(character: first, count: count)
    }

    static func records(in source: NSString) -> [Line] {
        guard source.length > 0 else {
            return [Line(range: NSRange(location: 0, length: 0), content: "")]
        }

        var result: [Line] = []
        var location = 0
        while location < source.length {
            let range = source.lineRange(for: NSRange(location: location, length: 0))
            var contentEnd = NSMaxRange(range)
            while contentEnd > range.location {
                let scalar = source.character(at: contentEnd - 1)
                guard scalar == 0x0A || scalar == 0x0D else { break }
                contentEnd -= 1
            }
            let contentRange = NSRange(
                location: range.location,
                length: contentEnd - range.location
            )
            result.append(Line(range: range, content: source.substring(with: contentRange)))
            location = NSMaxRange(range)
        }

        let finalScalar = source.character(at: source.length - 1)
        if finalScalar == 0x0A || finalScalar == 0x0D {
            result.append(
                Line(
                    range: NSRange(location: source.length, length: 0),
                    content: ""
                )
            )
        }
        return result
    }

    static func index(containing offset: Int, in lines: [Line]) -> Int? {
        for index in lines.indices {
            let range = lines[index].range
            if range.length == 0, offset == range.location { return index }
            if offset >= range.location, offset < NSMaxRange(range) { return index }
        }
        return lines.indices.last
    }
}
