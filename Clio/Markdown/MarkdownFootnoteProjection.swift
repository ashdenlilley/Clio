import Foundation

/// A de-indented footnote body plus an exact map back to the canonical source.
/// The projection contains only copied source units; it never synthesizes text.
struct MarkdownFootnoteProjection {
    struct Segment {
        let local: UTF16Range
        let original: UTF16Range
    }

    private(set) var text = ""
    private(set) var segments: [Segment] = []
    private var length = 0

    mutating func append(_ range: NSRange, from source: NSString) {
        guard range.length > 0 else { return }
        text += source.substring(with: range)
        segments.append(Segment(
            local: UTF16Range(location: length, length: range.length),
            original: UTF16Range(location: range.location, length: range.length)
        ))
        length += range.length
    }

    func originalRange(for local: UTF16Range) -> UTF16Range {
        let lower = originalOffset(for: local.location, preferPrevious: false)
        let upper = originalOffset(for: local.upperBound, preferPrevious: true)
        return UTF16Range(location: lower, length: max(0, upper - lower))
    }

    private func originalOffset(for offset: Int, preferPrevious: Bool) -> Int {
        if preferPrevious {
            for segment in segments.reversed() where containsPrevious(offset, in: segment) {
                return mapped(offset, in: segment)
            }
        } else {
            for segment in segments where containsNext(offset, in: segment) {
                return mapped(offset, in: segment)
            }
        }
        if let first = segments.first, offset <= first.local.location {
            return first.original.location
        }
        return segments.last?.original.upperBound ?? 0
    }

    private func containsPrevious(_ offset: Int, in segment: Segment) -> Bool {
        offset > segment.local.location && offset <= segment.local.upperBound
    }

    private func containsNext(_ offset: Int, in segment: Segment) -> Bool {
        offset >= segment.local.location && offset < segment.local.upperBound
    }

    private func mapped(_ offset: Int, in segment: Segment) -> Int {
        segment.original.location
            + min(max(0, offset - segment.local.location), segment.original.length)
    }
}
