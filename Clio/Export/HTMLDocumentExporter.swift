import Foundation

actor HTMLDocumentExporter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepare(
        parsed: ParsedMarkdown,
        request: ExportRequest,
        collisionChoice: CollisionChoice?
    ) throws -> StagedDocumentExport {
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
        do {
            try Data(html.utf8).write(to: temporaryURL, options: .atomic)
            try Task.checkCancellation()
            let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return StagedDocumentExport(
                format: .html,
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

enum HTMLDocumentRenderer {
    static func render(document: MarkdownDocumentModel, title: String) throws -> String {
        var bodyParts: [String] = []
        bodyParts.reserveCapacity(document.blocks.count)
        var footnoteDefinitionCounts: [String: Int] = [:]
        for block in document.blocks {
            try Task.checkCancellation()
            bodyParts.append(
                try render(
                    block: block,
                    footnoteDefinitionCounts: &footnoteDefinitionCounts
                )
            )
        }
        let body = bodyParts.joined()
        try Task.checkCancellation()
        let language = try escape(Locale.current.language.languageCode?.identifier ?? "en")
        let safeTitle = try escape(title)
        return """
        <!doctype html>
        <html lang="\(language)">
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; object-src 'none'">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(safeTitle)</title>
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

    static func render(
        block: MarkdownBlock,
        footnoteDefinitionCounts: inout [String: Int]
    ) throws -> String {
        switch block {
        case .paragraph(let content, _):
            return "    <p>\(try render(inlines: content))</p>\n"
        case .heading(let level, let content, _):
            let safeLevel = min(max(level, 1), 6)
            return "    <h\(safeLevel)>\(try render(inlines: content))</h\(safeLevel)>\n"
        case .blockquote(let blocks, _):
            var nested = ""
            for block in blocks {
                try Task.checkCancellation()
                nested += try render(
                    block: block,
                    footnoteDefinitionCounts: &footnoteDefinitionCounts
                )
            }
            return "    <blockquote>\(nested)</blockquote>\n"
        case .list(let list):
            return try render(
                list: list,
                footnoteDefinitionCounts: &footnoteDefinitionCounts
            )
        case .codeFence(let language, let source, _):
            let languageAttribute: String
            if let language {
                languageAttribute = " class=\"language-\(try escapeAttribute(language))\""
            } else {
                languageAttribute = ""
            }
            return "    <pre><code\(languageAttribute)>\(try escape(source))</code></pre>\n"
        case .table(let table):
            return try render(table: table)
        case .thematicBreak:
            return "    <hr>\n"
        case .frontMatter(let source, _):
            return "    <aside class=\"frontmatter\" aria-label=\"Document metadata\"><pre>\(try escape(source))</pre></aside>\n"
        case .footnoteDefinition(let label, let blocks, _):
            let occurrence = (footnoteDefinitionCounts[label] ?? 0) + 1
            footnoteDefinitionCounts[label] = occurrence
            let baseID = try safeFootnoteID(label)
            let definitionID = occurrence == 1 ? baseID : "\(baseID)-\(occurrence)"
            var nested = ""
            for block in blocks {
                try Task.checkCancellation()
                nested += try render(
                    block: block,
                    footnoteDefinitionCounts: &footnoteDefinitionCounts
                )
            }
            return "    <section class=\"footnote\" id=\"\(definitionID)\" aria-label=\"Footnote \(try escapeAttribute(label))\">\(nested)</section>\n"
        case .rawHTML(let source, _):
            return "    <pre class=\"raw-html\" aria-label=\"Unrendered HTML\">\(try escape(source))</pre>\n"
        }
    }

    static func render(
        list: MarkdownList,
        footnoteDefinitionCounts: inout [String: Int]
    ) throws -> String {
        let tag = list.isOrdered ? "ol" : "ul"
        let start = list.isOrdered && list.start != nil && list.start != 1
            ? " start=\"\(list.start!)\""
            : ""
        var items = ""
        for item in list.items {
            try Task.checkCancellation()
            let taskClass = item.taskState == nil ? "" : " class=\"task\""
            let marker: String
            switch item.taskState {
            case .checked: marker = "<span class=\"task-marker\" aria-label=\"Completed\">☑</span>"
            case .unchecked: marker = "<span class=\"task-marker\" aria-label=\"Not completed\">☐</span>"
            case nil: marker = ""
            }
            var blocks = ""
            for block in item.blocks {
                blocks += try render(
                    block: block,
                    footnoteDefinitionCounts: &footnoteDefinitionCounts
                )
            }
            items += "      <li\(taskClass)>\(marker)\(blocks)</li>\n"
        }
        return "    <\(tag)\(start)>\n\(items)    </\(tag)>\n"
    }

    static func render(table: MarkdownTable) throws -> String {
        func cell(
            _ cell: MarkdownTableCell,
            index: Int,
            tag: String,
            scope: String = ""
        ) throws -> String {
            let alignment = index < table.alignments.count ? table.alignments[index] : .none
            let className: String
            switch alignment {
            case .center: className = " class=\"align-center\""
            case .trailing: className = " class=\"align-trailing\""
            case .none, .leading: className = ""
            }
            return "<\(tag)\(scope)\(className)>\(try render(inlines: cell.content))</\(tag)>"
        }
        var header = ""
        for (index, headerCell) in table.header.enumerated() {
            try Task.checkCancellation()
            header += try cell(headerCell, index: index, tag: "th", scope: " scope=\"col\"")
        }
        var rows = ""
        for row in table.rows {
            try Task.checkCancellation()
            var cells = ""
            for (index, bodyCell) in row.enumerated() {
                cells += try cell(bodyCell, index: index, tag: "td")
            }
            rows += "      <tr>\(cells)</tr>\n"
        }
        return "    <table>\n      <thead><tr>\(header)</tr></thead>\n      <tbody>\n\(rows)      </tbody>\n    </table>\n"
    }

    static func render(inlines: [MarkdownInline]) throws -> String {
        var result = ""
        for inline in inlines {
            try Task.checkCancellation()
            result += try render(inline: inline)
        }
        return result
    }

    static func render(inline: MarkdownInline) throws -> String {
        switch inline {
        case .text(let value, _): return try escape(value)
        case .emphasis(let content, _): return "<em>\(try render(inlines: content))</em>"
        case .strong(let content, _): return "<strong>\(try render(inlines: content))</strong>"
        case .strikethrough(let content, _): return "<del>\(try render(inlines: content))</del>"
        case .code(let value, _): return "<code>\(try escape(value))</code>"
        case .link(let destination, let title, let content, _):
            guard let safe = safeLink(destination) else { return try render(inlines: content) }
            let titleAttribute: String
            if let title {
                titleAttribute = " title=\"\(try escapeAttribute(title))\""
            } else {
                titleAttribute = ""
            }
            return "<a href=\"\(try escapeAttribute(safe))\"\(titleAttribute)>\(try render(inlines: content))</a>"
        case .image(let source, _, let alt, _):
            let alternative = try plainText(alt)
            guard let safe = safeEmbeddedImage(source) else {
                return "<span role=\"img\" aria-label=\"\(try escapeAttribute(alternative))\">\(try escape(alternative))</span>"
            }
            return "<img src=\"\(try escapeAttribute(safe))\" alt=\"\(try escapeAttribute(alternative))\">"
        case .autolink(let text, let destination, _):
            guard let safe = safeLink(destination) else { return try escape(text) }
            return "<a href=\"\(try escapeAttribute(safe))\">\(try escape(text))</a>"
        case .footnoteReference(let label, _):
            return "<sup><a href=\"#\(try safeFootnoteID(label))\" aria-label=\"Footnote \(try escapeAttribute(label))\">\(try escape(label))</a></sup>"
        case .softBreak: return "\n"
        case .hardBreak: return "<br>\n"
        case .rawHTML(let source, _): return try escape(source)
        }
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
            case .softBreak, .hardBreak: result += "\n"
            case .rawHTML(let source, _): result += source
            }
        }
        return result
    }

    static func safeLink(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: {
                  $0.value <= 0x20 || (0x7f...0x9f).contains($0.value)
              }) else {
            return nil
        }
        guard let components = URLComponents(string: value) else { return nil }
        guard let scheme = components.scheme?.lowercased() else {
            return value.hasPrefix("//") || value.hasPrefix("\\\\") ? nil : value
        }
        return ["http", "https", "mailto"].contains(scheme) ? value : nil
    }

    static func safeEmbeddedImage(_ value: String) -> String? {
        let normalized = String(value.prefix(64)).lowercased()
        return [
            "data:image/png;base64,",
            "data:image/jpeg;base64,",
            "data:image/gif;base64,",
            "data:image/webp;base64,",
            "data:image/avif;base64,",
        ].contains(where: normalized.hasPrefix) ? value : nil
    }

    static func safeFootnoteID(_ label: String) throws -> String {
        var result = "fn-"
        result.reserveCapacity(3 + label.utf8.count * 2)
        let hexadecimal = Array("0123456789abcdef".utf8)
        for (offset, byte) in label.utf8.enumerated() {
            if offset.isMultiple(of: 2_048) { try Task.checkCancellation() }
            result.unicodeScalars.append(UnicodeScalar(hexadecimal[Int(byte >> 4)]))
            result.unicodeScalars.append(UnicodeScalar(hexadecimal[Int(byte & 0x0f)]))
        }
        return label.isEmpty ? "fn-empty" : result
    }

    static func escapeAttribute(_ value: String) throws -> String { try escape(value) }

    static func escape(_ value: String) throws -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for (offset, scalar) in value.unicodeScalars.enumerated() {
            if offset.isMultiple(of: 2_048) { try Task.checkCancellation() }
            switch scalar.value {
            case 0x26: result += "&amp;"
            case 0x3c: result += "&lt;"
            case 0x3e: result += "&gt;"
            case 0x22: result += "&quot;"
            case 0x27: result += "&#39;"
            case let value where isDisallowedControl(value):
                result += "�"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func isDisallowedControl(_ value: UInt32) -> Bool {
        (value < 0x20 && value != 0x09 && value != 0x0a && value != 0x0d)
            || (0x7f...0x9f).contains(value)
    }
}
