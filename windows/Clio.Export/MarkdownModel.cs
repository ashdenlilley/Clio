namespace Clio.Export;

/// <summary>
/// Semantic document model the exporters render. Mirrors the macOS <c>MarkdownDocumentModel</c> minus source
/// ranges: exports never map back into the editor buffer.
/// </summary>
public sealed record MarkdownDocument(IReadOnlyList<MarkdownBlock> Blocks);

public enum TableAlignment { None, Leading, Center, Trailing }

public enum TaskState { Unchecked, Checked }

public abstract record MarkdownInline;
public sealed record TextInline(string Value) : MarkdownInline;
public sealed record EmphasisInline(IReadOnlyList<MarkdownInline> Content) : MarkdownInline;
public sealed record StrongInline(IReadOnlyList<MarkdownInline> Content) : MarkdownInline;
public sealed record StrikethroughInline(IReadOnlyList<MarkdownInline> Content) : MarkdownInline;
public sealed record CodeInline(string Value) : MarkdownInline;
public sealed record LinkInline(string Destination, string? Title, IReadOnlyList<MarkdownInline> Content) : MarkdownInline;
public sealed record ImageInline(string Source, string? Title, IReadOnlyList<MarkdownInline> Alt) : MarkdownInline;
public sealed record AutolinkInline(string Text, string Destination) : MarkdownInline;
public sealed record FootnoteReferenceInline(string Label) : MarkdownInline;
public sealed record SoftBreakInline : MarkdownInline;
public sealed record HardBreakInline : MarkdownInline;
public sealed record RawHtmlInline(string Source) : MarkdownInline;

public sealed record ListItem(TaskState? Task, IReadOnlyList<MarkdownBlock> Blocks);
public sealed record MarkdownList(bool IsOrdered, int? Start, bool IsTight, IReadOnlyList<ListItem> Items);
public sealed record TableCell(IReadOnlyList<MarkdownInline> Content);
public sealed record MarkdownTable(
    IReadOnlyList<TableAlignment> Alignments,
    IReadOnlyList<TableCell> Header,
    IReadOnlyList<IReadOnlyList<TableCell>> Rows);

public abstract record MarkdownBlock;
public sealed record ParagraphBlock(IReadOnlyList<MarkdownInline> Content) : MarkdownBlock;
public sealed record HeadingBlock(int Level, IReadOnlyList<MarkdownInline> Content) : MarkdownBlock;
public sealed record BlockquoteBlock(IReadOnlyList<MarkdownBlock> Blocks) : MarkdownBlock;
public sealed record ListBlock(MarkdownList List) : MarkdownBlock;
public sealed record CodeFenceBlock(string? Language, string Source) : MarkdownBlock;
public sealed record TableBlock(MarkdownTable Table) : MarkdownBlock;
public sealed record ThematicBreakBlock : MarkdownBlock;
public sealed record FrontMatterBlock(string Source) : MarkdownBlock;
public sealed record FootnoteDefinitionBlock(string Label, IReadOnlyList<MarkdownBlock> Blocks) : MarkdownBlock;
public sealed record RawHtmlBlock(string Source) : MarkdownBlock;
