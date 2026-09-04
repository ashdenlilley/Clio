import AppKit

/// Applies focus mode as TextKit 2 rendering attributes. The underlying
/// attributed source remains untouched, so syntax highlighting and copied text
/// retain their own attributes and exact characters.
final class FocusDimmer {
    /// Bounds synchronous structural discovery when a pathological document has
    /// no nearby paragraph boundary. Full Markdown parsing remains off-main.
    static let maximumSynchronousScanLength = 64 * 1_024

    private var renderedRanges: [NSTextRange] = []
    private var lastFocusRange: NSRange?
    private var lastDocumentLength = -1
    private var lastOpacity: CGFloat = -1

    func apply(to textView: NSTextView, configuration: EditorConfiguration) {
        guard configuration.isFocusModeEnabled,
              let storage = textView.textStorage,
              let contentStorage = textView.textContentStorage,
              let layoutManager = textView.textLayoutManager else {
            clear(in: textView)
            return
        }

        let sourceLength = storage.length
        let opacity = configuration.resolvedFocusDimmingOpacity
        let selection = textView.selectedRange()
        if let lastFocusRange,
           sourceLength == lastDocumentLength,
           opacity == lastOpacity,
           selection.location >= lastFocusRange.location,
           selection.location < NSMaxRange(lastFocusRange),
           NSMaxRange(selection) <= NSMaxRange(lastFocusRange) {
            return
        }
        guard let focusRange = Self.focusRange(
            in: storage.mutableString,
            selection: selection
        ) else {
            clear(in: textView)
            return
        }

        clearRenderingRanges(using: layoutManager)
        let dimmedColor = Palette.foreground.withAlphaComponent(opacity)
        var nextRenderedRanges: [NSTextRange] = []

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
            nextRenderedRanges.append(leadingRange)
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
            nextRenderedRanges.append(trailingRange)
        }

        renderedRanges = nextRenderedRanges
        lastFocusRange = focusRange
        lastDocumentLength = sourceLength
        lastOpacity = opacity
    }

    func clear(in textView: NSTextView) {
        if let layoutManager = textView.textLayoutManager {
            clearRenderingRanges(using: layoutManager)
        }
        lastFocusRange = nil
        lastDocumentLength = -1
        lastOpacity = -1
    }

    /// Returns the current unit of thought, or `nil` when a selection crosses
    /// units and focus mode should be suppressed.
    static func focusRange(in string: String, selection: NSRange) -> NSRange? {
        focusRange(in: string as NSString, selection: selection)
    }

    static func focusRange(in source: NSString, selection: NSRange) -> NSRange? {
        guard source.length > 0 else { return NSRange(location: 0, length: 0) }
        let startOffset = min(selection.location, source.length)
        let endOffset = selection.length == 0
            ? startOffset
            : min(max(startOffset, NSMaxRange(selection) - 1), source.length)
        let firstUnit = unitRange(containing: startOffset, in: source)
        let lastUnit = unitRange(containing: endOffset, in: source)
        guard firstUnit == lastUnit else { return nil }
        return firstUnit
    }

    private func clearRenderingRanges(using layoutManager: NSTextLayoutManager) {
        for range in renderedRanges {
            layoutManager.invalidateRenderingAttributes(for: range)
        }
        renderedRanges.removeAll(keepingCapacity: true)
    }

    private static func unitRange(containing offset: Int, in source: NSString) -> NSRange {
        if let fencedRange = fencedBlock(containing: offset, in: source) {
            return fencedRange
        }

        let current = Line(at: offset, in: source)
        if current.isBlank || current.isHeading || current.isThematicBreak
            || current.fenceMarker != nil {
            return current.range
        }
        if current.isListItem {
            return contiguousRange(around: current, in: source) {
                !$0.isBlank && ($0.isListItem || $0.isIndentedContinuation)
            }
        }
        if current.isBlockquote {
            return contiguousRange(around: current, in: source) { $0.isBlockquote }
        }
        return contiguousRange(around: current, in: source) {
            !$0.isBlank
                && !$0.isListItem
                && !$0.isBlockquote
                && !$0.isHeading
                && !$0.isThematicBreak
                && $0.fenceMarker == nil
        }
    }

    private static func fencedBlock(containing offset: Int, in source: NSString) -> NSRange? {
        let target = Line(at: offset, in: source)
        let scanStart = max(0, target.range.location - maximumSynchronousScanLength)
        var cursor = scanStart == 0
            ? 0
            : source.lineRange(for: NSRange(location: scanStart, length: 0)).location
        var opening: (line: Line, marker: FenceMarker)?

        while cursor <= target.range.location, cursor < source.length {
            let line = Line(at: cursor, in: source)
            if let marker = line.fenceMarker {
                if let active = opening,
                   marker.character == active.marker.character,
                   marker.count >= active.marker.count,
                   marker.hasInfoString == false {
                    if target.range.location <= line.range.location {
                        return union(active.line.range, line.range)
                    }
                    opening = nil
                } else if opening == nil {
                    opening = (line, marker)
                }
            }
            let next = NSMaxRange(line.range)
            guard next > cursor else { break }
            cursor = next
        }

        guard let active = opening,
              target.range.location >= active.line.range.location else { return nil }
        let scanEnd = min(source.length, target.range.location + maximumSynchronousScanLength)
        cursor = max(NSMaxRange(target.range), NSMaxRange(active.line.range))
        while cursor < scanEnd {
            let line = Line(at: cursor, in: source)
            if let marker = line.fenceMarker,
               marker.character == active.marker.character,
               marker.count >= active.marker.count,
               marker.hasInfoString == false {
                return union(active.line.range, line.range)
            }
            let next = NSMaxRange(line.range)
            guard next > cursor else { break }
            cursor = next
        }
        let boundedEnd = min(source.length, max(NSMaxRange(target.range), scanEnd))
        return NSRange(
            location: active.line.range.location,
            length: boundedEnd - active.line.range.location
        )
    }

    private static func contiguousRange(
        around current: Line,
        in source: NSString,
        includes: (Line) -> Bool
    ) -> NSRange {
        let lowerBound = max(0, current.range.location - maximumSynchronousScanLength)
        let upperBound = min(source.length, NSMaxRange(current.range) + maximumSynchronousScanLength)
        var lower = current.range.location
        var upper = NSMaxRange(current.range)

        while lower > lowerBound {
            let previous = Line(at: lower - 1, in: source)
            guard includes(previous) else { break }
            lower = previous.range.location
        }
        while upper < upperBound {
            let next = Line(at: upper, in: source)
            guard includes(next) else { break }
            let nextUpper = NSMaxRange(next.range)
            guard nextUpper > upper else { break }
            upper = nextUpper
        }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func union(_ first: NSRange, _ last: NSRange) -> NSRange {
        NSRange(location: first.location, length: NSMaxRange(last) - first.location)
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
    let hasInfoString: Bool
}

private struct Line {
    let range: NSRange
    let content: String

    init(at offset: Int, in source: NSString) {
        if source.length == 0 {
            range = NSRange(location: 0, length: 0)
            content = ""
            return
        }
        if offset >= source.length {
            range = NSRange(location: source.length, length: 0)
            content = ""
            return
        }
        range = source.lineRange(for: NSRange(
            location: min(max(0, offset), source.length - 1),
            length: 0
        ))
        var contentEnd = NSMaxRange(range)
        while contentEnd > range.location {
            let scalar = source.character(at: contentEnd - 1)
            guard scalar == 0x0A || scalar == 0x0D else { break }
            contentEnd -= 1
        }
        content = source.substring(with: NSRange(
            location: range.location,
            length: contentEnd - range.location
        ))
    }

    var trimmed: String { content.trimmingCharacters(in: .whitespaces) }
    var isBlank: Bool { trimmed.isEmpty }

    var isListItem: Bool {
        content.range(
            of: #"^\s*(?:[-+*]|\d+[.)])\s+"#,
            options: .regularExpression
        ) != nil
    }

    var isIndentedContinuation: Bool {
        !isBlank && (content.hasPrefix("  ") || content.hasPrefix("\t"))
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
        return FenceMarker(
            character: first,
            count: count,
            hasInfoString: candidate.dropFirst(count)
                .contains(where: { !$0.isWhitespace })
        )
    }
}
