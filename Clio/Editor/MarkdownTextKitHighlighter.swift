import AppKit

/// Applies presentation attributes only. The NSTextStorage characters are
/// never replaced, so selection offsets, copy, undo, and saved bytes remain the
/// exact Markdown source.
@MainActor
final class MarkdownTextKitHighlighter {
    private(set) var lastUpdate: MarkdownHighlightUpdate?

    func apply(
        _ update: MarkdownHighlightUpdate,
        to textView: NSTextView,
        configuration: EditorConfiguration
    ) {
        guard let storage = textView.textStorage,
              storage.length == update.sourceUTF16Length else { return }
        let invalidated = update.invalidatedRange
            .clamped(toUTF16Length: storage.length)
            .nsRange
        let baseFont = Typography.font(size: configuration.resolvedFontSize)
        let base: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: Palette.foreground,
            .strikethroughStyle: 0,
            .underlineStyle: 0,
            .baselineOffset: 0,
        ]

        storage.beginEditing()
        if invalidated.length > 0 { storage.addAttributes(base, range: invalidated) }
        for span in update.applicationSpans {
            let range = span.range.clamped(toUTF16Length: storage.length).nsRange
            guard range.length > 0 else { continue }
            let currentFont = storage.attribute(
                .font,
                at: range.location,
                effectiveRange: nil
            ) as? NSFont ?? baseFont
            storage.addAttributes(
                attributes(
                    for: span,
                    baseFont: currentFont,
                    fontSize: configuration.resolvedFontSize
                ),
                range: range
            )
        }
        storage.endEditing()
        lastUpdate = update
    }

    func clear(in textView: NSTextView, configuration: EditorConfiguration) {
        guard let storage = textView.textStorage, storage.length > 0 else {
            lastUpdate = nil
            return
        }
        let baseFont = Typography.font(size: configuration.resolvedFontSize)
        storage.beginEditing()
        storage.addAttributes([
            .font: baseFont,
            .foregroundColor: Palette.foreground,
            .strikethroughStyle: 0,
            .underlineStyle: 0,
            .baselineOffset: 0,
        ], range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        lastUpdate = nil
    }

    func reapply(to textView: NSTextView, configuration: EditorConfiguration) {
        guard let lastUpdate else { return }
        apply(MarkdownHighlightUpdate(
            sourceFingerprint: lastUpdate.sourceFingerprint,
            sourceUTF16Length: lastUpdate.sourceUTF16Length,
            mode: lastUpdate.mode,
            invalidatedRange: UTF16Range(
                location: 0,
                length: (textView.string as NSString).length
            ),
            spans: lastUpdate.spans,
            applicationSpans: lastUpdate.spans,
            parsedUTF16Length: lastUpdate.parsedUTF16Length,
            minimap: lastUpdate.minimap
        ), to: textView, configuration: configuration)
    }

    private func attributes(
        for span: MarkdownSpan,
        baseFont: NSFont,
        fontSize: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        if case .codeToken(let token) = span.role {
            return [.foregroundColor: tokenColor(token)]
        }
        switch span.role {
        case .marker, .blockRule:
            return [.foregroundColor: Palette.marker]
        case .destination:
            return [.foregroundColor: Palette.reference]
        case .infoString:
            return [.foregroundColor: Palette.meta]
        case .codeToken:
            return [:]
        case .content:
            break
        }

        switch span.kind {
        case .heading:
            let scale: CGFloat
            switch span.level ?? 6 {
            case 1: scale = 1.65
            case 2: scale = 1.4
            case 3: scale = 1.2
            default: scale = 1
            }
            return [
                .font: Typography.font(size: fontSize * scale, traits: .boldFontMask),
                .foregroundColor: Palette.emphasis,
            ]
        case .strong:
            return [.font: converted(baseFont, adding: .boldFontMask), .foregroundColor: Palette.emphasis]
        case .emphasis:
            return [.font: converted(baseFont, adding: .italicFontMask)]
        case .strikethrough:
            return [.strikethroughStyle: NSUnderlineStyle.single.rawValue]
        case .inlineCode, .codeFence:
            return [.foregroundColor: Palette.literal]
        case .link, .autolink:
            return [.foregroundColor: Palette.reference]
        case .frontMatter, .footnote, .table:
            return [.foregroundColor: Palette.meta]
        case .blockquote:
            return [.foregroundColor: Palette.muted]
        default:
            return [:]
        }
    }

    private func tokenColor(_ token: CodeTokenKind) -> NSColor {
        switch token {
        case .keyword, .type: return Palette.meta
        case .string, .number: return Palette.literal
        case .comment: return Palette.muted
        case .function, .property: return Palette.reference
        case .operatorSymbol, .punctuation: return Palette.marker
        }
    }

    private func converted(_ font: NSFont, adding traits: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: traits)
    }
}

private extension UTF16Range {
    var nsRange: NSRange { NSRange(location: location, length: length) }

    func intersects(_ other: UTF16Range) -> Bool {
        location < other.upperBound && other.location < upperBound
    }
}
