import Foundation

struct MarkdownHighlightUpdate: Equatable, Sendable {
    let sourceFingerprint: String
    let sourceUTF16Length: Int
    let mode: MarkdownHighlightingMode
    let invalidatedRange: UTF16Range
    let spans: [MarkdownSpan]
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

    init(documentID: DocumentID = DocumentID()) {
        self.documentID = documentID
    }

    func update(source newSource: String, edit: MarkdownTextEdit? = nil) async throws -> MarkdownHighlightUpdate {
        try Task.checkCancellation()
        let newMode = MarkdownHighlightingMode(
            sizeMode: .mode(forUTF8ByteCount: newSource.utf8.count)
        )
        let fingerprint = StableSourceFingerprint.make(newSource)
        guard newMode != .unsupported else {
            source = newSource
            spans = []
            mode = newMode
            revision &+= 1
            return MarkdownHighlightUpdate(
                sourceFingerprint: fingerprint,
                sourceUTF16Length: (newSource as NSString).length,
                mode: newMode,
                invalidatedRange: UTF16Range(location: 0, length: (newSource as NSString).length),
                spans: [],
                parsedUTF16Length: 0
            )
        }

        guard let edit,
              mode == newMode,
              applying(edit, to: source) == newSource else {
            let parsedSpans: [MarkdownSpan]
            if newMode == .reduced {
                parsedSpans = try SourcePreservingMarkdownParser
                    .reducedHighlightingSpans(in: newSource)
            } else {
                parsedSpans = try await parse(newSource, filename: "untitled.md").spans
            }
            source = newSource
            spans = parsedSpans
            mode = newMode
            revision &+= 1
            return MarkdownHighlightUpdate(
                sourceFingerprint: fingerprint,
                sourceUTF16Length: (newSource as NSString).length,
                mode: newMode,
                invalidatedRange: UTF16Range(location: 0, length: (newSource as NSString).length),
                spans: spans,
                parsedUTF16Length: (newSource as NSString).length
            )
        }

        let invalidation = MarkdownInvalidationPlanner.ranges(for: edit, in: source)
        let newText = newSource as NSString
        let fragmentRange = invalidation.newRange.clamped(toUTF16Length: newText.length)
        let fragment = newText.substring(with: fragmentRange.nsRange)
        let fragmentSpans: [MarkdownSpan]
        if newMode == .reduced {
            fragmentSpans = try SourcePreservingMarkdownParser
                .reducedHighlightingSpans(in: fragment)
        } else {
            fragmentSpans = try await parse(fragment, filename: "fragment.md").spans
        }
        let replacedLength = edit.replacedRange
            .clamped(toUTF16Length: (source as NSString).length)
            .length
        let delta = (edit.replacement as NSString).length - replacedLength
        var retained: [MarkdownSpan] = []
        retained.reserveCapacity(spans.count + fragmentSpans.count)
        for span in spans {
            if span.range.upperBound <= invalidation.oldRange.location {
                retained.append(span)
            } else if span.range.location >= invalidation.oldRange.upperBound {
                retained.append(MarkdownSpan(
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
        retained.append(contentsOf: fragmentSpans.map { span in
            MarkdownSpan(
                kind: span.kind,
                role: span.role,
                range: UTF16Range(
                    location: fragmentRange.location + span.range.location,
                    length: span.range.length
                ),
                level: span.level
            )
        })
        retained.sort {
            $0.range.location == $1.range.location
                ? $0.range.length > $1.range.length
                : $0.range.location < $1.range.location
        }
        source = newSource
        spans = retained
        mode = newMode
        revision &+= 1
        return MarkdownHighlightUpdate(
            sourceFingerprint: fingerprint,
            sourceUTF16Length: newText.length,
            mode: newMode,
            invalidatedRange: fragmentRange,
            spans: retained,
            parsedUTF16Length: fragmentRange.length
        )
    }

    func reset() {
        source = ""
        spans = []
        mode = .full
        revision = 0
    }

    private func parse(_ value: String, filename: String) async throws -> ParsedMarkdown {
        try await parser.parse(DocumentTextSnapshot(
            documentID: documentID,
            generation: BufferGeneration(bufferID: documentID.rawValue, revision: revision),
            filename: filename,
            source: value,
            sourceFingerprint: StableSourceFingerprint.make(value)
        ))
    }

    private func applying(_ edit: MarkdownTextEdit, to source: String) -> String {
        let text = NSMutableString(string: source)
        let safe = edit.replacedRange.clamped(toUTF16Length: text.length).nsRange
        text.replaceCharacters(in: safe, with: edit.replacement)
        return text as String
    }
}

private extension UTF16Range {
    var nsRange: NSRange { NSRange(location: location, length: length) }
}
