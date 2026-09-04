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
        collisionResolution: ExportCollisionResolution?
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
        let reservation = try ExportDestination.resolve(
            requestedURL: request.destinationURL,
            resolution: collisionResolution,
            fileManager: fileManager
        )
        let temporaryURL = try reservation.url.clioExportStagingURL(
            format: .pdf,
            fileManager: fileManager
        )
        do {
            let attributedDocument = try PDFAttributedDocumentBuilder.build(
                parsed.document,
                contentWidth: geometry.contentRect.width
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
            guard size <= AtomicWriteTransactions.maximumRecoverableByteCount else {
                throw DocumentExportError.artifactTooLarge(
                    reservation.url,
                    byteCount: size,
                    maximumByteCount: AtomicWriteTransactions.maximumRecoverableByteCount
                )
            }
            return StagedDocumentExport(
                format: .pdf,
                temporaryURL: temporaryURL,
                reservation: reservation,
                byteCount: size,
                documentID: request.snapshot.documentID,
                generation: request.snapshot.generation,
                sourceFingerprint: request.snapshot.sourceFingerprint
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
            context.textPosition = .zero
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
                context.saveGState()
                context.textMatrix = .identity
                context.textPosition = .zero
                CTFrameDraw(frame, context)
                context.restoreGState()
                drawTableRules(in: frame, document: attributedDocument, context: context, contentRect: contentRect)
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
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        context.textPosition = .zero
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
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: pageSize.width - margins.trailing - pageWidth,
            y: margins.bottom + 6
        )
        CTLineDraw(page, context)
    }

    func drawTableRules(
        in frame: CTFrame,
        document: NSAttributedString,
        context: CGContext,
        contentRect: CGRect
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(0.5)
        for (index, line) in lines.enumerated() {
            let range = CTLineGetStringRange(line)
            guard range.location < document.length,
                  let rule = document.attribute(.clioTableRule, at: range.location, effectiveRange: nil) as? [CGFloat],
                  rule.count == 2 else { continue }
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, nil, &descent, nil)
            let y = max(contentRect.minY, contentRect.minY + origins[index].y - descent - 3)
            context.move(to: CGPoint(x: contentRect.minX + rule[0], y: y))
            context.addLine(to: CGPoint(x: contentRect.minX + rule[0] + rule[1], y: y))
            context.strokePath()
        }
    }
}

private extension NSAttributedString.Key {
    static let clioTableRule = Self("ClioPDFTableHeaderRule")
}

enum PDFAttributedDocumentBuilder {
    static func build(_ document: MarkdownDocumentModel, contentWidth: CGFloat = 500) throws -> NSAttributedString {
        let output = NSMutableAttributedString()
        for block in document.blocks {
            try Task.checkCancellation()
            try append(block: block, depth: 0, contentWidth: contentWidth, to: output)
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
        contentWidth: CGFloat,
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
            for nested in blocks { try append(block: nested, depth: depth + 1, contentWidth: contentWidth, to: output) }
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
                for nested in item.blocks { try append(block: nested, depth: depth + 1, contentWidth: contentWidth, to: output) }
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
            try appendTable(table, depth: depth, contentWidth: contentWidth, to: output)
        case .thematicBreak:
            try append("------------------------\n", style: bodyStyle(depth: depth), to: output)
        case .frontMatter(let source, _):
            let style = codeStyle(depth: depth)
            try append(source, style: style, to: output)
            if !source.hasSuffix("\n") { try append("\n", style: style, to: output) }
        case .footnoteDefinition(let label, let blocks, _):
            try append("[\(label)] ", style: bodyStyle(depth: depth), to: output)
            for nested in blocks { try append(block: nested, depth: depth + 1, contentWidth: contentWidth, to: output) }
        case .rawHTML(let source, _):
            let style = codeStyle(depth: depth)
            try append(source, style: style, to: output)
            if !source.hasSuffix("\n") { try append("\n", style: style, to: output) }
        }
    }

    static func appendTable(
        _ table: MarkdownTable,
        depth: Int,
        contentWidth: CGFloat,
        to output: NSMutableAttributedString
    ) throws {
        let columns = max(1, table.header.count, table.rows.map(\.count).max() ?? 0)
        let inset = min(CGFloat(depth) * 18, max(0, contentWidth - 40))
        let width = max(1, contentWidth - inset)
        let columnWidth = width / CGFloat(columns)
        let padding = min(6, columnWidth * 0.1)
        let cellWidth = max(0.1, columnWidth - 2 * padding)
        let fontSize = min(10.5, cellWidth / 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.35
        paragraph.paragraphSpacing = 3
        paragraph.tabStops = (0..<columns).map { column in
            let alignment = column < table.alignments.count ? table.alignments[column] : .leading
            let start = inset + CGFloat(column) * columnWidth
            switch alignment {
            case .trailing:
                return NSTextTab(textAlignment: .right, location: start + columnWidth - padding)
            case .center:
                return NSTextTab(textAlignment: .center, location: start + columnWidth / 2)
            case .none, .leading:
                return NSTextTab(textAlignment: .left, location: start + padding)
            }
        }
        for rowIndex in 0...table.rows.count {
            try Task.checkCancellation()
            let row = rowIndex == 0 ? table.header : table.rows[rowIndex - 1]
            let style: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: rowIndex == 0 ? .semibold : .regular),
                .foregroundColor: textColor,
                .paragraphStyle: paragraph,
            ]
            let cells = try (0..<columns).map { column -> NSAttributedString in
                let value = NSMutableAttributedString()
                if column < row.count { try append(inlines: row[column].content, base: style, to: value) }
                // Cell-local tabs must not escape into an adjacent column.
                value.mutableString.replaceOccurrences(of: "\t", with: " ", range: NSRange(location: 0, length: value.length))
                return value
            }
            let typesetters = cells.map { CTTypesetterCreateWithAttributedString($0) }
            var offsets = [Int](repeating: 0, count: columns)
            repeat {
                try Task.checkCancellation()
                let lineStart = output.length
                for column in 0..<columns {
                    try Task.checkCancellation()
                    try append("\t", style: style, to: output)
                    let cell = cells[column]
                    guard offsets[column] < cell.length else { continue }
                    let count = CTTypesetterSuggestLineBreak(typesetters[column], offsets[column], Double(cellWidth))
                    let source = cell.string as NSString
                    let length = count > 0 ? count : source.rangeOfComposedCharacterSequence(at: offsets[column]).length
                    let range = NSRange(location: offsets[column], length: min(length, cell.length - offsets[column]))
                    let slice = NSMutableAttributedString(attributedString: cell.attributedSubstring(from: range))
                    // A hard break ends the cell line, not the surrounding row.
                    slice.mutableString.replaceOccurrences(of: "\n", with: " ", range: NSRange(location: 0, length: slice.length))
                    slice.mutableString.replaceOccurrences(of: "\r", with: " ", range: NSRange(location: 0, length: slice.length))
                    output.append(slice)
                    offsets[column] += range.length
                }
                try append("\n", style: style, to: output)
                if rowIndex == 0, zip(offsets, cells).allSatisfy({ $0.0 >= $0.1.length }) {
                    let headerParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
                    headerParagraph.paragraphSpacing = 9
                    let range = NSRange(location: lineStart, length: output.length - lineStart)
                    output.addAttribute(.paragraphStyle, value: headerParagraph, range: range)
                    output.addAttribute(.clioTableRule, value: [inset, width], range: range)
                }
            } while zip(offsets, cells).contains(where: { $0.0 < $0.1.length })
        }
        try append("\n", style: bodyStyle(depth: depth), to: output)
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
                if let safe = ExportContentPolicy.safeLink(destination) {
                    try append(" (\(safe))", style: base, to: output)
                }
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
