import Foundation

actor HTMLDocumentExporter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepare(
        parsed: ParsedMarkdown,
        request: ExportRequest,
        collisionResolution: ExportCollisionResolution?
    ) throws -> StagedDocumentExport {
        try Task.checkCancellation()
        guard request.format == .html else {
            throw DocumentExportError.unsupportedDestination(request.destinationURL)
        }
        guard parsed.canApply(to: request.snapshot) else {
            throw DocumentExportError.staleParse
        }

        let reservation = try ExportDestination.resolve(
            requestedURL: request.destinationURL,
            resolution: collisionResolution,
            fileManager: fileManager
        )
        let temporaryURL = try reservation.url.clioExportStagingURL(
            format: .html,
            fileManager: fileManager
        )
        do {
            let size = try HTMLDocumentStreamRenderer.write(
                document: parsed.document,
                title: request.snapshot.filename,
                to: temporaryURL,
                reportingDestination: reservation.url
            )
            try Task.checkCancellation()
            return StagedDocumentExport(
                format: .html,
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
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; object-src 'none'">
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

fileprivate extension HTMLDocumentRenderer {
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
            guard let safe = ExportContentPolicy.safeLink(destination) else { return try render(inlines: content) }
            let titleAttribute: String
            if let title {
                titleAttribute = " title=\"\(try escapeAttribute(title))\""
            } else {
                titleAttribute = ""
            }
            return "<a href=\"\(try escapeAttribute(safe))\"\(titleAttribute)>\(try render(inlines: content))</a>"
        case .image(_, _, let alt, _):
            let alternative = try plainText(alt)
            // Exports never initiate filesystem or network reads. Images use
            // the same safe alt-only projection as PDF, including data URLs.
            return "<span role=\"img\" aria-label=\"\(try escapeAttribute(alternative))\">\(try escape(alternative))</span>"
        case .autolink(let text, let destination, _):
            guard let safe = ExportContentPolicy.safeLink(destination) else { return try escape(text) }
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

/// Production rendering writes bounded UTF-8 chunks directly to the staging
/// file. `HTMLDocumentRenderer.render` remains a convenient in-memory oracle
/// for focused semantic tests, but is never used by the export workflow.
enum HTMLDocumentStreamRenderer {
    @discardableResult
    static func write(
        document: MarkdownDocumentModel,
        title: String,
        to url: URL,
        reportingDestination destinationURL: URL,
        maximumByteCount: Int64 = AtomicWriteTransactions.maximumRecoverableByteCount
    ) throws -> Int64 {
        let sink = try HTMLFileSink(
            url: url,
            reportingDestination: destinationURL,
            maximumByteCount: maximumByteCount
        )
        do {
            try sink.raw("<!doctype html>\n<html lang=\"")
            try sink.escaped(
                Locale.current.language.languageCode?.identifier ?? "en"
            )
            try sink.raw("\">\n<head>\n  <meta charset=\"utf-8\">\n")
            try sink.raw("  <meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; object-src 'none'\">\n")
            try sink.raw("  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n  <title>")
            try sink.escaped(title)
            try sink.raw("</title>\n  <style>\n")
            try sink.raw(HTMLDocumentRenderer.stylesheet)
            try sink.raw("\n  </style>\n</head>\n<body>\n  <main class=\"document\">\n")
            var footnoteDefinitionCounts: [String: Int] = [:]
            for block in document.blocks {
                try Task.checkCancellation()
                try write(
                    block: block,
                    footnoteDefinitionCounts: &footnoteDefinitionCounts,
                    to: sink
                )
            }
            try sink.raw("\n  </main>\n</body>\n</html>")
            return try sink.finish()
        } catch {
            sink.abort()
            throw error
        }
    }
}

private extension HTMLDocumentStreamRenderer {
    static func write(
        block: MarkdownBlock,
        footnoteDefinitionCounts: inout [String: Int],
        to sink: HTMLFileSink
    ) throws {
        switch block {
        case .paragraph(let content, _):
            try sink.raw("    <p>")
            try write(inlines: content, to: sink)
            try sink.raw("</p>\n")
        case .heading(let level, let content, _):
            let safeLevel = min(max(level, 1), 6)
            try sink.raw("    <h\(safeLevel)>")
            try write(inlines: content, to: sink)
            try sink.raw("</h\(safeLevel)>\n")
        case .blockquote(let blocks, _):
            try sink.raw("    <blockquote>")
            for nested in blocks {
                try Task.checkCancellation()
                try write(
                    block: nested,
                    footnoteDefinitionCounts: &footnoteDefinitionCounts,
                    to: sink
                )
            }
            try sink.raw("</blockquote>\n")
        case .list(let list):
            try write(
                list: list,
                footnoteDefinitionCounts: &footnoteDefinitionCounts,
                to: sink
            )
        case .codeFence(let language, let source, _):
            try sink.raw("    <pre><code")
            if let language {
                try sink.raw(" class=\"language-")
                try sink.escaped(language)
                try sink.raw("\"")
            }
            try sink.raw(">")
            try sink.escaped(source)
            try sink.raw("</code></pre>\n")
        case .table(let table):
            try write(table: table, to: sink)
        case .thematicBreak:
            try sink.raw("    <hr>\n")
        case .frontMatter(let source, _):
            try sink.raw("    <aside class=\"frontmatter\" aria-label=\"Document metadata\"><pre>")
            try sink.escaped(source)
            try sink.raw("</pre></aside>\n")
        case .footnoteDefinition(let label, let blocks, _):
            let occurrence = (footnoteDefinitionCounts[label] ?? 0) + 1
            footnoteDefinitionCounts[label] = occurrence
            let baseID = try HTMLDocumentRenderer.safeFootnoteID(label)
            let definitionID = occurrence == 1 ? baseID : "\(baseID)-\(occurrence)"
            try sink.raw("    <section class=\"footnote\" id=\"")
            try sink.escaped(definitionID)
            try sink.raw("\" aria-label=\"Footnote ")
            try sink.escaped(label)
            try sink.raw("\">")
            for nested in blocks {
                try Task.checkCancellation()
                try write(
                    block: nested,
                    footnoteDefinitionCounts: &footnoteDefinitionCounts,
                    to: sink
                )
            }
            try sink.raw("</section>\n")
        case .rawHTML(let source, _):
            try sink.raw("    <pre class=\"raw-html\" aria-label=\"Unrendered HTML\">")
            try sink.escaped(source)
            try sink.raw("</pre>\n")
        }
    }

    static func write(
        list: MarkdownList,
        footnoteDefinitionCounts: inout [String: Int],
        to sink: HTMLFileSink
    ) throws {
        let tag = list.isOrdered ? "ol" : "ul"
        try sink.raw("    <\(tag)")
        if list.isOrdered, let start = list.start, start != 1 {
            try sink.raw(" start=\"\(start)\"")
        }
        try sink.raw(">\n")
        for item in list.items {
            try Task.checkCancellation()
            try sink.raw("      <li")
            if item.taskState != nil { try sink.raw(" class=\"task\"") }
            try sink.raw(">")
            switch item.taskState {
            case .checked:
                try sink.raw("<span class=\"task-marker\" aria-label=\"Completed\">☑</span>")
            case .unchecked:
                try sink.raw("<span class=\"task-marker\" aria-label=\"Not completed\">☐</span>")
            case nil:
                break
            }
            for nested in item.blocks {
                try write(
                    block: nested,
                    footnoteDefinitionCounts: &footnoteDefinitionCounts,
                    to: sink
                )
            }
            try sink.raw("</li>\n")
        }
        try sink.raw("    </\(tag)>\n")
    }

    static func write(table: MarkdownTable, to sink: HTMLFileSink) throws {
        func writeCell(
            _ cell: MarkdownTableCell,
            index: Int,
            tag: String,
            scope: String = ""
        ) throws {
            let alignment = index < table.alignments.count
                ? table.alignments[index]
                : .none
            let className: String
            switch alignment {
            case .center: className = " class=\"align-center\""
            case .trailing: className = " class=\"align-trailing\""
            case .none, .leading: className = ""
            }
            try sink.raw("<\(tag)\(scope)\(className)>")
            try write(inlines: cell.content, to: sink)
            try sink.raw("</\(tag)>")
        }

        try sink.raw("    <table>\n      <thead><tr>")
        for (index, cell) in table.header.enumerated() {
            try Task.checkCancellation()
            try writeCell(cell, index: index, tag: "th", scope: " scope=\"col\"")
        }
        try sink.raw("</tr></thead>\n      <tbody>\n")
        for row in table.rows {
            try Task.checkCancellation()
            try sink.raw("      <tr>")
            for (index, cell) in row.enumerated() {
                try writeCell(cell, index: index, tag: "td")
            }
            try sink.raw("</tr>\n")
        }
        try sink.raw("      </tbody>\n    </table>\n")
    }

    static func write(inlines: [MarkdownInline], to sink: HTMLFileSink) throws {
        for inline in inlines {
            try Task.checkCancellation()
            switch inline {
            case .text(let value, _):
                try sink.escaped(value)
            case .emphasis(let content, _):
                try sink.raw("<em>")
                try write(inlines: content, to: sink)
                try sink.raw("</em>")
            case .strong(let content, _):
                try sink.raw("<strong>")
                try write(inlines: content, to: sink)
                try sink.raw("</strong>")
            case .strikethrough(let content, _):
                try sink.raw("<del>")
                try write(inlines: content, to: sink)
                try sink.raw("</del>")
            case .code(let value, _):
                try sink.raw("<code>")
                try sink.escaped(value)
                try sink.raw("</code>")
            case .link(let destination, let title, let content, _):
                guard let safe = ExportContentPolicy.safeLink(destination) else {
                    try write(inlines: content, to: sink)
                    continue
                }
                try sink.raw("<a href=\"")
                try sink.escaped(safe)
                try sink.raw("\"")
                if let title {
                    try sink.raw(" title=\"")
                    try sink.escaped(title)
                    try sink.raw("\"")
                }
                try sink.raw(">")
                try write(inlines: content, to: sink)
                try sink.raw("</a>")
            case .image(_, _, let alt, _):
                try sink.raw("<span role=\"img\" aria-label=\"")
                try writePlainText(alt, to: sink)
                try sink.raw("\">")
                try writePlainText(alt, to: sink)
                try sink.raw("</span>")
            case .autolink(let text, let destination, _):
                guard let safe = ExportContentPolicy.safeLink(destination) else {
                    try sink.escaped(text)
                    continue
                }
                try sink.raw("<a href=\"")
                try sink.escaped(safe)
                try sink.raw("\">")
                try sink.escaped(text)
                try sink.raw("</a>")
            case .footnoteReference(let label, _):
                try sink.raw("<sup><a href=\"#")
                try sink.escaped(HTMLDocumentRenderer.safeFootnoteID(label))
                try sink.raw("\" aria-label=\"Footnote ")
                try sink.escaped(label)
                try sink.raw("\">")
                try sink.escaped(label)
                try sink.raw("</a></sup>")
            case .softBreak:
                try sink.raw("\n")
            case .hardBreak:
                try sink.raw("<br>\n")
            case .rawHTML(let source, _):
                try sink.escaped(source)
            }
        }
    }

    static func writePlainText(
        _ inlines: [MarkdownInline],
        to sink: HTMLFileSink
    ) throws {
        for inline in inlines {
            try Task.checkCancellation()
            switch inline {
            case .text(let value, _), .code(let value, _):
                try sink.escaped(value)
            case .emphasis(let content, _),
                 .strong(let content, _),
                 .strikethrough(let content, _):
                try writePlainText(content, to: sink)
            case .link(_, _, let content, _):
                try writePlainText(content, to: sink)
            case .image(_, _, let alt, _):
                try writePlainText(alt, to: sink)
            case .autolink(let text, _, _):
                try sink.escaped(text)
            case .footnoteReference(let label, _):
                try sink.raw("[")
                try sink.escaped(label)
                try sink.raw("]")
            case .softBreak, .hardBreak:
                try sink.raw("\n")
            case .rawHTML(let source, _):
                try sink.escaped(source)
            }
        }
    }
}

private final class HTMLFileSink {
    private static let escapeBufferByteCount = 16 * 1_024

    private let url: URL
    private let reportingDestination: URL
    private let maximumByteCount: Int64
    private let handle: FileHandle
    private(set) var byteCount: Int64 = 0
    private var isClosed = false

    init(
        url: URL,
        reportingDestination: URL,
        maximumByteCount: Int64
    ) throws {
        self.url = url
        self.reportingDestination = reportingDestination
        self.maximumByteCount = maximumByteCount
        try Data().write(to: url, options: .withoutOverwriting)
        handle = try FileHandle(forWritingTo: url)
    }

    func raw(_ value: String) throws {
        try write(Data(value.utf8))
    }

    func escaped(_ value: String) throws {
        var buffer = ""
        buffer.reserveCapacity(Self.escapeBufferByteCount)
        for (offset, scalar) in value.unicodeScalars.enumerated() {
            if offset.isMultiple(of: 2_048) { try Task.checkCancellation() }
            switch scalar.value {
            case 0x26: buffer += "&amp;"
            case 0x3c: buffer += "&lt;"
            case 0x3e: buffer += "&gt;"
            case 0x22: buffer += "&quot;"
            case 0x27: buffer += "&#39;"
            case let value where HTMLDocumentRenderer.isDisallowedControl(value):
                buffer += "�"
            default:
                buffer.unicodeScalars.append(scalar)
            }
            if buffer.utf8.count >= Self.escapeBufferByteCount {
                try raw(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try raw(buffer) }
    }

    func finish() throws -> Int64 {
        guard !isClosed else { return byteCount }
        try handle.synchronize()
        try handle.close()
        isClosed = true
        return byteCount
    }

    func abort() {
        if !isClosed {
            try? handle.close()
            isClosed = true
        }
        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        if !isClosed { try? handle.close() }
    }

    private func write(_ data: Data) throws {
        try Task.checkCancellation()
        let nextCount = byteCount + Int64(data.count)
        guard nextCount <= maximumByteCount else {
            throw DocumentExportError.artifactTooLarge(
                reportingDestination,
                byteCount: nextCount,
                maximumByteCount: maximumByteCount
            )
        }
        try handle.write(contentsOf: data)
        byteCount = nextCount
    }
}
