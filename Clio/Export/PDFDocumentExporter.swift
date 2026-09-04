import AppKit
import CoreGraphics
import CoreText
import Foundation

actor PDFDocumentExporter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepare(
        parsed: ParsedMarkdown,
        request: ExportRequest,
        collisionChoice: CollisionChoice?
    ) async throws -> StagedDocumentExport {
        try Task.checkCancellation()
        guard request.format == .pdf else {
            throw DocumentExportError.unsupportedDestination(request.destinationURL)
        }
        guard parsed.canApply(to: request.snapshot) else {
            throw DocumentExportError.staleParse
        }

        let fallbackSettings = await PDFPrintSettingsStore.systemDefault()
        let settings = request.pdfSettings ?? fallbackSettings
        let geometry = try PDFPrintGeometry.resolve(settings, fallback: fallbackSettings)
        let destination = try ExportDestination.resolve(
            requestedURL: request.destinationURL,
            choice: collisionChoice,
            fileManager: fileManager
        )
        let temporaryURL = destination.clioTemporarySibling()
        do {
            let attributedDocument = try PDFAttributedDocumentBuilder.build(
                parsed.document,
                fallbackSource: request.snapshot.source
            )
            try render(
                attributedDocument,
                title: request.snapshot.filename,
                to: temporaryURL,
                settings: settings,
                geometry: geometry
            )
            try Task.checkCancellation()
            let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return StagedDocumentExport(
                format: .pdf,
                temporaryURL: temporaryURL,
                destinationURL: destination,
                byteCount: size,
                generation: request.snapshot.generation,
                sourceFingerprint: request.snapshot.sourceFingerprint,
                replacing: collisionChoice == .replace
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}

private extension PDFDocumentExporter {
    func render(
        _ attributedDocument: NSAttributedString,
        title: String,
        to url: URL,
        settings: PDFPrintSettings,
        geometry: PDFPrintGeometry
    ) throws {
        let dimensions = geometry.pageSize
        var mediaBox = CGRect(origin: .zero, size: dimensions)
        let metadata: [CFString: Any] = [
            kCGPDFContextTitle: title,
            kCGPDFContextCreator: "Clio",
        ]
        guard let context = CGContext(
            url as CFURL,
            mediaBox: &mediaBox,
            metadata as CFDictionary
        ) else {
            throw DocumentExportError.couldNotCreatePDF(url)
        }
        defer { context.closePDF() }

        let margins = settings.margins
        let contentRect = geometry.contentRect

        let framesetter = CTFramesetterCreateWithAttributedString(attributedDocument)
        var location = 0
        var pageNumber = 1
        repeat {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            drawHeader(title, pageNumber: pageNumber, context: context, pageSize: dimensions, margins: margins)

            if attributedDocument.length > 0 {
                let path = CGPath(rect: contentRect, transform: nil)
                let frame = CTFramesetterCreateFrame(
                    framesetter,
                    CFRange(location: location, length: 0),
                    path,
                    nil
                )
                CTFrameDraw(frame, context)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else {
                    context.endPDFPage()
                    throw DocumentExportError.emptyPDFPage
                }
                let nextLocation = visible.location + visible.length
                guard nextLocation > location else {
                    context.endPDFPage()
                    throw DocumentExportError.emptyPDFPage
                }
                location = nextLocation
            }

            context.endPDFPage()
            pageNumber += 1
        } while location < attributedDocument.length
    }

    func drawHeader(
        _ title: String,
        pageNumber: Int,
        context: CGContext,
        pageSize: CGSize,
        margins: PrintMargins
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.black,
        ]
        let header = CTLineCreateWithAttributedString(
            NSAttributedString(string: title, attributes: attributes)
        )
        let token = CTLineCreateWithAttributedString(
            NSAttributedString(string: "...", attributes: attributes)
        )
        let availableHeaderWidth = max(
            1,
            pageSize.width - margins.leading - margins.trailing
        )
        let visibleHeader = CTLineCreateTruncatedLine(
            header,
            availableHeaderWidth,
            .end,
            token
        ) ?? header
        context.textPosition = CGPoint(
            x: margins.leading,
            y: pageSize.height - margins.top - PDFPrintGeometry.headerHeight + 7
        )
        CTLineDraw(visibleHeader, context)

        let page = CTLineCreateWithAttributedString(
            NSAttributedString(string: "\(pageNumber)", attributes: attributes)
        )
        let pageWidth = CTLineGetTypographicBounds(page, nil, nil, nil)
        context.textPosition = CGPoint(
            x: pageSize.width - margins.trailing - pageWidth,
            y: margins.bottom + 6
        )
        CTLineDraw(page, context)
    }
}

enum PDFAttributedDocumentBuilder {
    static func build(
        _ document: MarkdownDocumentModel,
        fallbackSource: String
    ) throws -> NSAttributedString {
        let output = NSMutableAttributedString()
        if document.blocks.isEmpty, !fallbackSource.isEmpty {
            try append(fallbackSource, style: bodyStyle(depth: 0), to: output)
            return output
        }
        for block in document.blocks {
            try Task.checkCancellation()
            try append(block: block, depth: 0, to: output)
        }
        return output
    }
}

private extension PDFAttributedDocumentBuilder {
    static let textColor = NSColor.black

    static func bodyStyle(depth: Int) -> [NSAttributedString.Key: Any] {
        attributes(
            font: .systemFont(ofSize: 11.5),
            paragraphSpacing: 10,
            lineHeight: 1.45,
            headIndent: CGFloat(depth) * 18
        )
    }

    static func codeStyle(depth: Int) -> [NSAttributedString.Key: Any] {
        attributes(
            font: .monospacedSystemFont(ofSize: 10, weight: .regular),
            paragraphSpacing: 11,
            lineHeight: 1.35,
            headIndent: CGFloat(depth) * 18
        )
    }

    static func attributes(
        font: NSFont,
        paragraphSpacing: CGFloat,
        lineHeight: CGFloat,
        headIndent: CGFloat = 0,
        firstLineHeadIndent: CGFloat? = nil
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = paragraphSpacing
        paragraph.lineHeightMultiple = lineHeight
        paragraph.headIndent = headIndent
        paragraph.firstLineHeadIndent = firstLineHeadIndent ?? headIndent
        return [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
    }

    static func append(
        block: MarkdownBlock,
        depth: Int,
        to output: NSMutableAttributedString
    ) throws {
        switch block {
        case .paragraph(let content, _):
            let style = bodyStyle(depth: depth)
            try append(inlines: content, base: style, to: output)
            try append("\n", style: style, to: output)
        case .heading(let level, let content, _):
            let safeLevel = min(max(level, 1), 6)
            let sizes: [CGFloat] = [25, 20, 16.5, 14.5, 13, 12]
            let style = attributes(
                font: .systemFont(ofSize: sizes[safeLevel - 1], weight: .semibold),
                paragraphSpacing: safeLevel <= 2 ? 14 : 10,
                lineHeight: 1.18,
                headIndent: CGFloat(depth) * 18
            )
            try append(inlines: content, base: style, to: output)
            try append("\n", style: style, to: output)
        case .blockquote(let blocks, _):
            let quoteStyle = attributes(
                font: .systemFont(ofSize: 11.5),
                paragraphSpacing: 8,
                lineHeight: 1.45,
                headIndent: CGFloat(depth + 1) * 18,
                firstLineHeadIndent: CGFloat(depth) * 18
            )
            try append("> ", style: quoteStyle, to: output)
            for nested in blocks { try append(block: nested, depth: depth + 1, to: output) }
        case .list(let list):
            for (offset, item) in list.items.enumerated() {
                try Task.checkCancellation()
                let marker: String
                if let task = item.taskState {
                    marker = task == .checked ? "☑ " : "☐ "
                } else if list.isOrdered {
                    marker = "\((list.start ?? 1) + offset). "
                } else {
                    marker = "• "
                }
                let listStyle = attributes(
                    font: .systemFont(ofSize: 11.5),
                    paragraphSpacing: list.isTight ? 3 : 8,
                    lineHeight: 1.42,
                    headIndent: CGFloat(depth + 1) * 18,
                    firstLineHeadIndent: CGFloat(depth) * 18
                )
                try append(marker, style: listStyle, to: output)
                for nested in item.blocks { try append(block: nested, depth: depth + 1, to: output) }
                if item.blocks.isEmpty { try append("\n", style: listStyle, to: output) }
            }
        case .codeFence(let language, let source, _):
            let style = codeStyle(depth: depth)
            if let language, !language.isEmpty {
                try append("\(language)\n", style: style, to: output)
            }
            try append(source, style: style, to: output)
            if !source.hasSuffix("\n") { try append("\n", style: style, to: output) }
        case .table(let table):
            let tableStyle = attributes(
                font: .systemFont(ofSize: 10.5),
                paragraphSpacing: 4,
                lineHeight: 1.35,
                headIndent: CGFloat(depth) * 18
            )
            try appendTableRow(table.header, style: tableStyle, to: output)
            try append(String(repeating: "-", count: max(3, table.header.count * 7)) + "\n", style: tableStyle, to: output)
            for row in table.rows {
                try Task.checkCancellation()
                try appendTableRow(row, style: tableStyle, to: output)
            }
            try append("\n", style: tableStyle, to: output)
        case .thematicBreak:
            try append("------------------------\n", style: bodyStyle(depth: depth), to: output)
        case .frontMatter(let source, _):
            let style = codeStyle(depth: depth)
            try append(source, style: style, to: output)
            if !source.hasSuffix("\n") { try append("\n", style: style, to: output) }
        case .footnoteDefinition(let label, let blocks, _):
            try append("[\(label)] ", style: bodyStyle(depth: depth), to: output)
            for nested in blocks { try append(block: nested, depth: depth + 1, to: output) }
        case .rawHTML(let source, _):
            let style = codeStyle(depth: depth)
            try append(source, style: style, to: output)
            if !source.hasSuffix("\n") { try append("\n", style: style, to: output) }
        }
    }

    static func appendTableRow(
        _ row: [MarkdownTableCell],
        style: [NSAttributedString.Key: Any],
        to output: NSMutableAttributedString
    ) throws {
        for (offset, cell) in row.enumerated() {
            if offset > 0 { try append("  |  ", style: style, to: output) }
            try append(inlines: cell.content, base: style, to: output)
        }
        try append("\n", style: style, to: output)
    }

    static func append(
        inlines: [MarkdownInline],
        base: [NSAttributedString.Key: Any],
        to output: NSMutableAttributedString
    ) throws {
        for inline in inlines {
            try Task.checkCancellation()
            switch inline {
            case .text(let value, _): try append(value, style: base, to: output)
            case .emphasis(let content, _):
                try append(inlines: content, base: changingFont(base, trait: .italicFontMask), to: output)
            case .strong(let content, _):
                try append(inlines: content, base: changingFont(base, trait: .boldFontMask), to: output)
            case .strikethrough(let content, _):
                var style = base
                style[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                try append(inlines: content, base: style, to: output)
            case .code(let value, _):
                var style = base
                style[.font] = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
                try append(value, style: style, to: output)
            case .link(let destination, _, let content, _):
                var style = base
                style[.underlineStyle] = NSUnderlineStyle.single.rawValue
                try append(inlines: content, base: style, to: output)
                try append(" (\(destination))", style: base, to: output)
            case .image(_, _, let alt, _):
                try append("[Image: \(try plainText(alt))]", style: base, to: output)
            case .autolink(let text, _, _):
                var style = base
                style[.underlineStyle] = NSUnderlineStyle.single.rawValue
                try append(text, style: style, to: output)
            case .footnoteReference(let label, _):
                try append("[\(label)]", style: base, to: output)
            case .softBreak:
                try append(" ", style: base, to: output)
            case .hardBreak:
                try append("\n", style: base, to: output)
            case .rawHTML(let source, _):
                try append(source, style: base, to: output)
            }
        }
    }

    static func changingFont(
        _ base: [NSAttributedString.Key: Any],
        trait: NSFontTraitMask
    ) -> [NSAttributedString.Key: Any] {
        var result = base
        if let font = base[.font] as? NSFont {
            result[.font] = NSFontManager.shared.convert(font, toHaveTrait: trait)
        }
        return result
    }

    static func plainText(_ inlines: [MarkdownInline]) throws -> String {
        var result = ""
        for inline in inlines {
            try Task.checkCancellation()
            switch inline {
            case .text(let value, _), .code(let value, _): result += value
            case .emphasis(let content, _), .strong(let content, _), .strikethrough(let content, _): result += try plainText(content)
            case .link(_, _, let content, _): result += try plainText(content)
            case .image(_, _, let alt, _): result += try plainText(alt)
            case .autolink(let text, _, _): result += text
            case .footnoteReference(let label, _): result += "[\(label)]"
            case .softBreak: result += " "
            case .hardBreak: result += "\n"
            case .rawHTML(let source, _): result += source
            }
        }
        return result
    }

    static func append(
        _ string: String,
        style: [NSAttributedString.Key: Any],
        to output: NSMutableAttributedString
    ) throws {
        let source = string as NSString
        var location = 0
        let maximumChunkLength = 32 * 1_024
        while location < source.length {
            try Task.checkCancellation()
            let proposed = NSRange(
                location: location,
                length: min(maximumChunkLength, source.length - location)
            )
            let range = source.rangeOfComposedCharacterSequences(for: proposed)
            guard range.length > 0 else { break }
            output.append(
                NSAttributedString(
                    string: source.substring(with: range),
                    attributes: style
                )
            )
            location = NSMaxRange(range)
        }
    }
}
