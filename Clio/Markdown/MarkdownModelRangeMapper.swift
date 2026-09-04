import Foundation

/// Rehomes a parsed fragment's semantic ranges into the untouched document.
/// Values remain those decoded by swift-markdown; only source coordinates move.
enum MarkdownModelRangeMapper {
    static func map(
        _ blocks: [MarkdownBlock],
        using transform: (UTF16Range) -> UTF16Range
    ) -> [MarkdownBlock] {
        blocks.map { map($0, using: transform) }
    }

    private static func map(
        _ block: MarkdownBlock,
        using transform: (UTF16Range) -> UTF16Range
    ) -> MarkdownBlock {
        switch block {
        case .paragraph(let content, let range):
            return .paragraph(content: map(content, using: transform), range: transform(range))
        case .heading(let level, let content, let range):
            return .heading(level: level, content: map(content, using: transform), range: transform(range))
        case .blockquote(let blocks, let range):
            return .blockquote(blocks: map(blocks, using: transform), range: transform(range))
        case .list(let list):
            return .list(MarkdownList(
                isOrdered: list.isOrdered,
                start: list.start,
                isTight: list.isTight,
                items: list.items.map { item in
                    MarkdownListItem(
                        taskState: item.taskState,
                        blocks: map(item.blocks, using: transform),
                        range: transform(item.range)
                    )
                },
                range: transform(list.range)
            ))
        case .codeFence(let language, let source, let range):
            return .codeFence(language: language, source: source, range: transform(range))
        case .table(let table):
            return .table(MarkdownTable(
                alignments: table.alignments,
                header: table.header.map { map($0, using: transform) },
                rows: table.rows.map { $0.map { map($0, using: transform) } },
                range: transform(table.range)
            ))
        case .thematicBreak(let range):
            return .thematicBreak(range: transform(range))
        case .frontMatter(let source, let range):
            return .frontMatter(source: source, range: transform(range))
        case .footnoteDefinition(let label, let blocks, let range):
            return .footnoteDefinition(
                label: label,
                blocks: map(blocks, using: transform),
                range: transform(range)
            )
        case .rawHTML(let source, let range):
            return .rawHTML(source: source, range: transform(range))
        }
    }

    private static func map(
        _ cell: MarkdownTableCell,
        using transform: (UTF16Range) -> UTF16Range
    ) -> MarkdownTableCell {
        MarkdownTableCell(content: map(cell.content, using: transform), range: transform(cell.range))
    }

    private static func map(
        _ inlines: [MarkdownInline],
        using transform: (UTF16Range) -> UTF16Range
    ) -> [MarkdownInline] {
        inlines.map { inline in
            switch inline {
            case .text(let value, let range):
                return .text(value: value, range: transform(range))
            case .emphasis(let content, let range):
                return .emphasis(content: map(content, using: transform), range: transform(range))
            case .strong(let content, let range):
                return .strong(content: map(content, using: transform), range: transform(range))
            case .strikethrough(let content, let range):
                return .strikethrough(content: map(content, using: transform), range: transform(range))
            case .code(let value, let range):
                return .code(value: value, range: transform(range))
            case .link(let destination, let title, let content, let range):
                return .link(
                    destination: destination,
                    title: title,
                    content: map(content, using: transform),
                    range: transform(range)
                )
            case .image(let source, let title, let alt, let range):
                return .image(
                    source: source,
                    title: title,
                    alt: map(alt, using: transform),
                    range: transform(range)
                )
            case .autolink(let text, let destination, let range):
                return .autolink(text: text, destination: destination, range: transform(range))
            case .footnoteReference(let label, let range):
                return .footnoteReference(label: label, range: transform(range))
            case .softBreak(let range):
                return .softBreak(range: transform(range))
            case .hardBreak(let range):
                return .hardBreak(range: transform(range))
            case .rawHTML(let source, let range):
                return .rawHTML(source: source, range: transform(range))
            }
        }
    }
}
