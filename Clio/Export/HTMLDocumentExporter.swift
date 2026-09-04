import Foundation

actor HTMLDocumentExporter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func export(
        parsed: ParsedMarkdown,
        request: ExportRequest,
        collisionChoice: CollisionChoice?
    ) throws -> ExportReceipt {
        try Task.checkCancellation()
        guard request.format == .html else {
            throw DocumentExportError.unsupportedDestination(request.destinationURL)
        }
        guard parsed.canApply(to: request.snapshot) else {
            throw DocumentExportError.staleParse
        }

        let destination = try ExportDestination.resolve(
            requestedURL: request.destinationURL,
            choice: collisionChoice,
            fileManager: fileManager
        )
        let html = try HTMLDocumentRenderer.render(
            document: parsed.document,
            title: request.snapshot.filename
        )
        try Task.checkCancellation()
        let temporaryURL = destination.clioTemporarySibling()
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try Data(html.utf8).write(to: temporaryURL, options: .atomic)
        try ExportDestination.install(
            temporaryURL: temporaryURL,
            at: destination,
            replacing: collisionChoice == .replace,
            fileManager: fileManager
        )
        let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return ExportReceipt(
            format: .html,
            destinationURL: destination,
            byteCount: Int64(size),
            completedAt: Date(),
            generation: request.snapshot.generation,
            sourceFingerprint: request.snapshot.sourceFingerprint
        )
    }
}

enum HTMLDocumentRenderer {
    static func render(document: MarkdownDocumentModel, title: String) throws -> String {
        var body = ""
        for block in document.blocks {
            try Task.checkCancellation()
            body += render(block: block)
        }
        let language = escape(Locale.current.language.languageCode?.identifier ?? "en")
        return """
        <!doctype html>
        <html lang="\(language)">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escape(title))</title>
          <style>
        \(stylesheet)
          </style>
        </head>
        <body>
          <main class="document">
        \(body)
          </main>
        </body>
        </html>
        """
    }
}

private extension HTMLDocumentRenderer {
    static let stylesheet = """
            :root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
            * { box-sizing: border-box; }
            html { background: #fff; color: #000; font-size: 17px; line-height: 1.62; }
            body { margin: 0; }
            .document { max-width: 46rem; margin: 0 auto; padding: 4rem 2.25rem 6rem; overflow-wrap: anywhere; }
            h1, h2, h3, h4, h5, h6 { line-height: 1.18; margin: 1.8em 0 .65em; page-break-after: avoid; }
            h1 { font-size: 2.2rem; } h2 { font-size: 1.65rem; } h3 { font-size: 1.3rem; }
            p, ul, ol, blockquote, pre, table, hr { margin: 0 0 1.15rem; }
            blockquote { border-left: .2rem solid #8e8e93; margin-left: 0; padding-left: 1.15rem; color: #3a3a3c; }
            code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
            code { background: #f2f2f7; border-radius: .25rem; padding: .08rem .28rem; font-size: .9em; }
            pre { background: #f2f2f7; border: 1px solid #d1d1d6; border-radius: .55rem; padding: 1rem; overflow-x: auto; white-space: pre-wrap; }
            pre code { background: transparent; padding: 0; }
            a { color: #0066cc; text-decoration-thickness: .08em; text-underline-offset: .15em; }
            table { width: 100%; border-collapse: collapse; }
            th, td { border-bottom: 1px solid #d1d1d6; padding: .45rem .55rem; text-align: left; vertical-align: top; }
            th { font-weight: 650; border-bottom-color: #8e8e93; }
            .align-center { text-align: center; } .align-trailing { text-align: right; }
            .task { list-style: none; margin-left: -1.4rem; }
            .task-marker { display: inline-block; width: 1.4rem; }
            .frontmatter, .raw-html { color: #48484a; font-size: .9rem; }
            .footnote { border-top: 1px solid #d1d1d6; padding-top: .7rem; font-size: .9rem; }
            img { max-width: 100%; height: auto; }
            @page { margin: 18mm; }
            @media print {
              html { font-size: 11pt; }
              .document { max-width: none; margin: 0; padding: 0; }
              a { color: #000; }
              pre, blockquote, table { break-inside: avoid; }
            }
        """

    static func render(block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let content, _):
            return "    <p>\(render(inlines: content))</p>\n"
        case .heading(let level, let content, _):
            let safeLevel = min(max(level, 1), 6)
            return "    <h\(safeLevel)>\(render(inlines: content))</h\(safeLevel)>\n"
        case .blockquote(let blocks, _):
            return "    <blockquote>\(blocks.map(render(block:)).joined())</blockquote>\n"
        case .list(let list):
            return render(list: list)
        case .codeFence(let language, let source, _):
            let languageAttribute = language.map {
                " class=\"language-\(escapeAttribute($0))\""
            } ?? ""
            return "    <pre><code\(languageAttribute)>\(escape(source))</code></pre>\n"
        case .table(let table):
            return render(table: table)
        case .thematicBreak:
            return "    <hr>\n"
        case .frontMatter(let source, _):
            return "    <aside class=\"frontmatter\" aria-label=\"Document metadata\"><pre>\(escape(source))</pre></aside>\n"
        case .footnoteDefinition(let label, let blocks, _):
            return "    <section class=\"footnote\" id=\"fn-\(escapeAttribute(label))\" aria-label=\"Footnote \(escapeAttribute(label))\">\(blocks.map(render(block:)).joined())</section>\n"
        case .rawHTML(let source, _):
            return "    <pre class=\"raw-html\" aria-label=\"Unrendered HTML\">\(escape(source))</pre>\n"
        }
    }

    static func render(list: MarkdownList) -> String {
        let tag = list.isOrdered ? "ol" : "ul"
        let start = list.isOrdered && list.start != nil && list.start != 1
            ? " start=\"\(list.start!)\""
            : ""
        let items = list.items.map { item in
            let taskClass = item.taskState == nil ? "" : " class=\"task\""
            let marker: String
            switch item.taskState {
            case .checked: marker = "<span class=\"task-marker\" aria-label=\"Completed\">☑</span>"
            case .unchecked: marker = "<span class=\"task-marker\" aria-label=\"Not completed\">☐</span>"
            case nil: marker = ""
            }
            return "      <li\(taskClass)>\(marker)\(item.blocks.map(render(block:)).joined())</li>\n"
        }.joined()
        return "    <\(tag)\(start)>\n\(items)    </\(tag)>\n"
    }

    static func render(table: MarkdownTable) -> String {
        func cell(_ cell: MarkdownTableCell, index: Int, tag: String) -> String {
            let alignment = index < table.alignments.count ? table.alignments[index] : .none
            let className: String
            switch alignment {
            case .center: className = " class=\"align-center\""
            case .trailing: className = " class=\"align-trailing\""
            case .none, .leading: className = ""
            }
            return "<\(tag)\(className)>\(render(inlines: cell.content))</\(tag)>"
        }
        let header = table.header.enumerated().map { cell($0.element, index: $0.offset, tag: "th") }.joined()
        let rows = table.rows.map { row in
            "      <tr>\(row.enumerated().map { cell($0.element, index: $0.offset, tag: "td") }.joined())</tr>\n"
        }.joined()
        return "    <table>\n      <thead><tr>\(header)</tr></thead>\n      <tbody>\n\(rows)      </tbody>\n    </table>\n"
    }

    static func render(inlines: [MarkdownInline]) -> String {
        inlines.map(render(inline:)).joined()
    }

    static func render(inline: MarkdownInline) -> String {
        switch inline {
        case .text(let value, _): return escape(value)
        case .emphasis(let content, _): return "<em>\(render(inlines: content))</em>"
        case .strong(let content, _): return "<strong>\(render(inlines: content))</strong>"
        case .strikethrough(let content, _): return "<del>\(render(inlines: content))</del>"
        case .code(let value, _): return "<code>\(escape(value))</code>"
        case .link(let destination, let title, let content, _):
            guard let safe = safeLink(destination) else { return render(inlines: content) }
            let titleAttribute = title.map { " title=\"\(escapeAttribute($0))\"" } ?? ""
            return "<a href=\"\(escapeAttribute(safe))\"\(titleAttribute)>\(render(inlines: content))</a>"
        case .image(let source, _, let alt, _):
            let alternative = plainText(alt)
            guard let safe = safeEmbeddedImage(source) else {
                return "<span role=\"img\" aria-label=\"\(escapeAttribute(alternative))\">\(escape(alternative))</span>"
            }
            return "<img src=\"\(escapeAttribute(safe))\" alt=\"\(escapeAttribute(alternative))\">"
        case .autolink(let text, let destination, _):
            guard let safe = safeLink(destination) else { return escape(text) }
            return "<a href=\"\(escapeAttribute(safe))\">\(escape(text))</a>"
        case .footnoteReference(let label, _):
            return "<sup><a href=\"#fn-\(escapeAttribute(label))\" aria-label=\"Footnote \(escapeAttribute(label))\">\(escape(label))</a></sup>"
        case .softBreak: return "\n"
        case .hardBreak: return "<br>\n"
        case .rawHTML(let source, _): return escape(source)
        }
    }

    static func plainText(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let value, _), .code(let value, _): value
            case .emphasis(let content, _), .strong(let content, _), .strikethrough(let content, _): plainText(content)
            case .link(_, _, let content, _): plainText(content)
            case .image(_, _, let alt, _): plainText(alt)
            case .autolink(let text, _, _): text
            case .footnoteReference(let label, _): "[\(label)]"
            case .softBreak, .hardBreak: "\n"
            case .rawHTML(let source, _): source
            }
        }.joined()
    }

    static func safeLink(_ value: String) -> String? {
        guard let components = URLComponents(string: value) else { return nil }
        guard let scheme = components.scheme?.lowercased() else {
            return value.hasPrefix("//") ? nil : value
        }
        return ["http", "https", "mailto"].contains(scheme) ? value : nil
    }

    static func safeEmbeddedImage(_ value: String) -> String? {
        let normalized = value.lowercased()
        return [
            "data:image/png;",
            "data:image/jpeg;",
            "data:image/gif;",
            "data:image/webp;",
            "data:image/avif;",
        ].contains(where: normalized.hasPrefix) ? value : nil
    }

    static func escapeAttribute(_ value: String) -> String { escape(value) }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
