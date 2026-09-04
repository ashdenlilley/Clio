import Foundation

struct MarkdownHighlightUpdate: Equatable, Sendable {
    let sourceFingerprint: String
    let sourceUTF16Length: Int
    let mode: MarkdownHighlightingMode
    let invalidatedRange: UTF16Range
    let spans: [MarkdownSpan]
    /// Pre-filtered on the Markdown actor so TextKit never scans every span on
    /// the main actor for a single-block edit.
    let applicationSpans: [MarkdownSpan]
    let parsedUTF16Length: Int
}

/// Keeps highlighting incremental without making an incremental AST a data
/// integrity boundary. Export requests always ask the canonical parser for a
/// complete model; live edits reparse only the affected block island.
actor IncrementalMarkdownHighlighter {
    private let parser = SourcePreservingMarkdownParser()
    private let documentID: DocumentID
    private var source = ""
    private var spans: [MarkdownSpan] = []
    private var mode: MarkdownHighlightingMode = .full
    private var revision: UInt64 = 0
    private var sourceUTF8ByteCount = 0

    init(documentID: DocumentID = DocumentID()) {
        self.documentID = documentID
    }

    /// Applies a captured NSTextView delta to the actor-owned mirror. No full
    /// editor snapshot crosses the main actor for a normal keystroke.
    func update(edit: MarkdownTextEdit) async throws -> MarkdownHighlightUpdate {
        try await update(edits: [edit])
    }

    /// Materializes a queued burst once. A single/coalesced edit retains the
    /// incremental island path; disjoint edits conservatively reparse the one
    /// final snapshot rather than copying the whole source per keystroke.
    func update(edits: [MarkdownTextEdit]) async throws -> MarkdownHighlightUpdate {
        guard !edits.isEmpty,
              let newSource = MarkdownTextEditApplier.applying(edits, to: source) else {
            throw MarkdownIncrementalError.invalidEdit
        }
        return try await update(
            source: newSource,
            edit: edits.count == 1 ? edits[0] : nil
        )
    }

    func update(source newSource: String, edit: MarkdownTextEdit? = nil) async throws -> MarkdownHighlightUpdate {
        try Task.checkCancellation()
        let oldText = source as NSString
        let newText = newSource as NSString
        let isContinuous = edit.map {
            MarkdownIncrementalPolicy.isContinuous(
                $0,
                oldSource: source,
                newSource: newSource
            )
        } ?? false
        let newByteCount: Int
        if let edit, isContinuous {
            let removed = oldText.substring(with: edit.replacedRange.nsRange)
            newByteCount = sourceUTF8ByteCount - removed.utf8.count + edit.replacement.utf8.count
        } else {
            newByteCount = newSource.utf8.count
        }
        let newMode = MarkdownHighlightingMode(sizeMode: .mode(forUTF8ByteCount: newByteCount))
        let fingerprint = "live-\(revision &+ 1)-\(newText.length)-\(newByteCount)"
        guard newMode != .unsupported else {
            source = newSource
            sourceUTF8ByteCount = newByteCount
            spans = []
            mode = newMode
            revision &+= 1
            return MarkdownHighlightUpdate(
                sourceFingerprint: fingerprint,
                sourceUTF16Length: newText.length,
                mode: newMode,
                invalidatedRange: UTF16Range(location: 0, length: newText.length),
                spans: [],
                applicationSpans: [],
                parsedUTF16Length: 0
            )
        }

        guard let edit,
              mode == newMode,
              newMode == .full,
              isContinuous,
              !MarkdownIncrementalPolicy.requiresFullReparse(
                edit,
                oldSource: source,
                newSource: newSource
              ) else {
            let parsedSpans: [MarkdownSpan]
            let parsedLength: Int
            if newMode == .reduced {
                parsedSpans = try SourcePreservingMarkdownParser
                    .reducedHighlightingSpans(in: newSource)
                parsedLength = min(
                    newText.length,
                    SourcePreservingMarkdownParser.reducedHighlightUTF16Limit
                )
            } else {
                parsedSpans = try await parse(newSource, filename: "untitled.md").spans
                parsedLength = newText.length
            }
            source = newSource
            sourceUTF8ByteCount = newByteCount
            spans = parsedSpans
            mode = newMode
            revision &+= 1
            return MarkdownHighlightUpdate(
                sourceFingerprint: fingerprint,
                sourceUTF16Length: newText.length,
                mode: newMode,
                invalidatedRange: UTF16Range(location: 0, length: newText.length),
                spans: spans,
                applicationSpans: spans,
                parsedUTF16Length: parsedLength
            )
        }

        let invalidation = MarkdownInvalidationPlanner.ranges(
            for: edit,
            oldSource: source,
            newSource: newSource
        )
        let replacedLength = edit.replacedRange.length
        let delta = (edit.replacement as NSString).length - replacedLength
        let mappedOld = UTF16Range(
            location: min(invalidation.oldRange.location, newText.length),
            length: max(0, invalidation.oldRange.length + delta)
        ).clamped(toUTF16Length: newText.length)
        let fragmentRange = invalidation.newRange
            .union(mappedOld)
            .clamped(toUTF16Length: newText.length)
        let fragment = newText.substring(with: fragmentRange.nsRange)
        let fragmentSpans: [MarkdownSpan]
        if newMode == .reduced {
            fragmentSpans = try SourcePreservingMarkdownParser
                .reducedHighlightingSpans(in: fragment)
        } else {
            fragmentSpans = try await parse(fragment, filename: "fragment.md").spans
        }
        var prefixSpans: [MarkdownSpan] = []
        var suffixSpans: [MarkdownSpan] = []
        prefixSpans.reserveCapacity(spans.count / 2)
        suffixSpans.reserveCapacity(spans.count / 2)
        for (index, span) in spans.enumerated() {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            if span.range.upperBound <= invalidation.oldRange.location {
                prefixSpans.append(span)
            } else if span.range.location >= invalidation.oldRange.upperBound {
                suffixSpans.append(MarkdownSpan(
                    kind: span.kind,
                    role: span.role,
                    range: UTF16Range(
                        location: max(0, span.range.location + delta),
                        length: span.range.length
                    ),
                    level: span.level
                ))
            }
        }
        let mappedFragment = fragmentSpans.map { span in
            MarkdownSpan(
                kind: span.kind,
                role: span.role,
                range: UTF16Range(
                    location: fragmentRange.location + span.range.location,
                    length: span.range.length
                ),
                level: span.level
            )
        }
        // Prefix, reparsed island, and translated suffix are individually
        // sorted and non-overlapping, so concatenation preserves canonical
        // order without a whole-document Set/sort on every keystroke.
        let retained = prefixSpans + mappedFragment + suffixSpans
        let applicationSpans = retained.filter {
            $0.range.intersects(fragmentRange)
        }
        source = newSource
        sourceUTF8ByteCount = newByteCount
        spans = retained
        mode = newMode
        revision &+= 1
        return MarkdownHighlightUpdate(
            sourceFingerprint: fingerprint,
            sourceUTF16Length: newText.length,
            mode: newMode,
            invalidatedRange: fragmentRange,
            spans: retained,
            applicationSpans: applicationSpans,
            parsedUTF16Length: fragmentRange.length
        )
    }

    func reset() {
        source = ""
        spans = []
        mode = .full
        revision = 0
        sourceUTF8ByteCount = 0
    }

    private func parse(_ value: String, filename: String) async throws -> ParsedMarkdown {
        try await parser.parse(DocumentTextSnapshot(
            documentID: documentID,
            generation: BufferGeneration(bufferID: documentID.rawValue, revision: revision),
            filename: filename,
            source: value,
            sourceFingerprint: "live-\(revision)-\((value as NSString).length)"
        ))
    }
}

private enum MarkdownIncrementalError: Error {
    case invalidEdit
}

private extension UTF16Range {
    var nsRange: NSRange { NSRange(location: location, length: length) }

    func union(_ other: UTF16Range) -> UTF16Range {
        let lower = min(location, other.location)
        let upper = max(upperBound, other.upperBound)
        return UTF16Range(location: lower, length: upper - lower)
    }

    func intersects(_ other: UTF16Range) -> Bool {
        location < other.upperBound && other.location < upperBound
    }
}
