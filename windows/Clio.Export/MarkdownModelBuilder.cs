using System.Globalization;
using System.Text;
using Markdig;
using Markdig.Extensions.EmphasisExtras;
using Markdig.Extensions.Footnotes;
using Markdig.Extensions.Tables;
using Markdig.Extensions.TaskLists;
using Markdig.Extensions.Yaml;
using Md = Markdig.Syntax;
using MdInl = Markdig.Syntax.Inlines;

namespace Clio.Export;

/// <summary>
/// Parses Markdown with Markdig and projects the result into <see cref="MarkdownDocument"/>. The pipeline enables
/// exactly the GFM surface Clio's macOS parser models: pipe tables, task lists, footnotes, strikethrough, autolinks
/// and YAML front matter. Footnote definitions come out where Markdig places them (end of document).
/// </summary>
public static class MarkdownModelBuilder
{
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .UsePipeTables()
        .UseTaskLists()
        .UseFootnotes()
        .UseEmphasisExtras(EmphasisExtraOptions.Strikethrough)
        .UseAutoLinks()
        .UseYamlFrontMatter()
        .Build();

    public static MarkdownDocument Build(string source, CancellationToken cancellationToken = default)
    {
        var parsed = Markdown.Parse(source, Pipeline);
        return new MarkdownDocument(Blocks(parsed, source, cancellationToken));
    }

    private static List<MarkdownBlock> Blocks(IEnumerable<Md.Block> blocks, string source, CancellationToken ct)
    {
        var result = new List<MarkdownBlock>();
        foreach (var block in blocks)
        {
            ct.ThrowIfCancellationRequested();
            switch (block)
            {
                case YamlFrontMatterBlock front:
                    result.Add(new FrontMatterBlock(FrontMatterSource(front, source)));
                    break;
                case Md.HeadingBlock heading:
                    result.Add(new HeadingBlock(Math.Clamp(heading.Level, 1, 6), Inlines(heading.Inline)));
                    break;
                case Md.ParagraphBlock paragraph:
                    result.Add(new ParagraphBlock(Inlines(paragraph.Inline)));
                    break;
                case Md.QuoteBlock quote:
                    result.Add(new BlockquoteBlock(Blocks(quote, source, ct)));
                    break;
                case Md.ListBlock list:
                    result.Add(new ListBlock(List(list, source, ct)));
                    break;
                case Md.FencedCodeBlock fence:
                    result.Add(new CodeFenceBlock(string.IsNullOrWhiteSpace(fence.Info) ? null : fence.Info, LeafText(fence)));
                    break;
                case Md.CodeBlock code:
                    result.Add(new CodeFenceBlock(null, LeafText(code)));
                    break;
                case Table table:
                    result.Add(new TableBlock(BuildTable(table)));
                    break;
                case Md.ThematicBreakBlock:
                    result.Add(new ThematicBreakBlock());
                    break;
                case Md.HtmlBlock html:
                    result.Add(new RawHtmlBlock(LeafText(html)));
                    break;
                case FootnoteGroup group:
                    foreach (var footnote in group.OfType<Footnote>())
                        result.Add(new FootnoteDefinitionBlock(FootnoteLabel(footnote.Label), Blocks(footnote, source, ct)));
                    break;
                case Md.LinkReferenceDefinitionGroup or Md.LinkReferenceDefinition:
                    break;
                case Md.LeafBlock { Inline: not null } leaf:
                    result.Add(new ParagraphBlock(Inlines(leaf.Inline)));
                    break;
                case Md.ContainerBlock container:
                    result.AddRange(Blocks(container, source, ct));
                    break;
            }
        }
        return result;
    }

    /// <summary>swift-markdown code text keeps the final line terminator; Markdig's joined lines do not.</summary>
    private static string LeafText(Md.LeafBlock block)
    {
        var text = block.Lines.ToString();
        return block.Lines.Count == 0 ? "" : text + "\n";
    }

    private static string FrontMatterSource(YamlFrontMatterBlock block, string source)
    {
        var start = Math.Clamp(block.Span.Start, 0, source.Length);
        var end = Math.Clamp(block.Span.End + 1, start, source.Length);
        // Include the closing fence's line terminator, as the macOS scanner does.
        if (end < source.Length && source[end] == '\r') end++;
        if (end < source.Length && source[end] == '\n') end++;
        return source[start..end];
    }

    private static MarkdownList List(Md.ListBlock list, string source, CancellationToken ct)
    {
        int? start = null;
        if (list.IsOrdered && int.TryParse(list.OrderedStart, NumberStyles.None, CultureInfo.InvariantCulture, out var parsedStart))
            start = parsedStart;
        var items = new List<ListItem>();
        foreach (var item in list.OfType<Md.ListItemBlock>())
        {
            ct.ThrowIfCancellationRequested();
            TaskState? task = null;
            var blocks = new List<MarkdownBlock>();
            foreach (var child in Blocks(item, source, ct, out task)) blocks.Add(child);
            items.Add(new ListItem(task, blocks));
        }
        return new MarkdownList(list.IsOrdered, list.IsOrdered ? start ?? 1 : null, !list.IsLoose, items);
    }

    private static List<MarkdownBlock> Blocks(Md.ListItemBlock item, string source, CancellationToken ct, out TaskState? task)
    {
        task = null;
        foreach (var child in item)
        {
            if (child is Md.ParagraphBlock { Inline.FirstChild: TaskList marker })
            {
                task = marker.Checked ? TaskState.Checked : TaskState.Unchecked;
                break;
            }
            break;
        }
        return Blocks(item, source, ct);
    }

    private static MarkdownTable BuildTable(Table table)
    {
        var alignments = table.ColumnDefinitions
            .Select(c => c.Alignment switch
            {
                TableColumnAlign.Left => TableAlignment.Leading,
                TableColumnAlign.Center => TableAlignment.Center,
                TableColumnAlign.Right => TableAlignment.Trailing,
                _ => TableAlignment.None,
            })
            .ToList();
        var header = new List<TableCell>();
        var rows = new List<IReadOnlyList<TableCell>>();
        foreach (var row in table.OfType<TableRow>())
        {
            var cells = row.OfType<Markdig.Extensions.Tables.TableCell>().Select(CellOf).ToList();
            if (row.IsHeader && header.Count == 0) header = cells;
            else rows.Add(cells);
        }
        return new MarkdownTable(alignments, header, rows);
    }

    private static TableCell CellOf(Markdig.Extensions.Tables.TableCell cell)
    {
        var inlines = new List<MarkdownInline>();
        foreach (var paragraph in cell.OfType<Md.ParagraphBlock>())
        {
            if (inlines.Count > 0) inlines.Add(new HardBreakInline());
            inlines.AddRange(Inlines(paragraph.Inline));
        }
        return new TableCell(inlines);
    }

    // ---- inlines ---------------------------------------------------------------------------------

    private static List<MarkdownInline> Inlines(MdInl.ContainerInline? container)
    {
        var result = new List<MarkdownInline>();
        if (container is null) return result;
        var afterTask = false;
        for (var node = container.FirstChild; node is not null; node = node.NextSibling)
        {
            if (afterTask && node is MdInl.LiteralInline literal)
            {
                // Markdig leaves the space that separates "[x]" from the item text.
                result.Add(new TextInline(literal.Content.ToString().TrimStart(' ')));
                afterTask = false;
                continue;
            }
            afterTask = node is TaskList;
            Append(node, result);
        }
        return result;
    }

    private static void Append(MdInl.Inline node, List<MarkdownInline> into)
    {
        switch (node)
        {
            case TaskList:
                break;
            case MdInl.LiteralInline literal:
                into.Add(new TextInline(literal.Content.ToString()));
                break;
            case MdInl.HtmlEntityInline entity:
                into.Add(new TextInline(entity.Transcoded.ToString()));
                break;
            case MdInl.CodeInline code:
                into.Add(new CodeInline(code.Content));
                break;
            case MdInl.EmphasisInline emphasis:
                var content = Inlines(emphasis);
                into.Add(emphasis.DelimiterChar == '~' ? new StrikethroughInline(content)
                    : emphasis.DelimiterCount >= 2 ? new StrongInline(content)
                    : new EmphasisInline(content));
                break;
            case MdInl.LinkInline { IsImage: true } image:
                into.Add(new ImageInline(image.Url ?? "", NullIfEmpty(image.Title), Inlines(image)));
                break;
            case MdInl.LinkInline { IsAutoLink: true } auto:
                into.Add(new AutolinkInline(PlainText(Inlines(auto)) is { Length: > 0 } label ? label : auto.Url ?? "", auto.Url ?? ""));
                break;
            case MdInl.LinkInline link:
                into.Add(new LinkInline(link.Url ?? "", NullIfEmpty(link.Title), Inlines(link)));
                break;
            case MdInl.AutolinkInline auto:
                into.Add(new AutolinkInline(auto.Url, auto.IsEmail ? "mailto:" + auto.Url : auto.Url));
                break;
            case MdInl.LineBreakInline lineBreak:
                into.Add(lineBreak.IsHard ? new HardBreakInline() : new SoftBreakInline());
                break;
            case MdInl.HtmlInline html:
                into.Add(new RawHtmlInline(html.Tag));
                break;
            case FootnoteLink { IsBackLink: false } footnote:
                into.Add(new FootnoteReferenceInline(FootnoteLabel(footnote.Footnote.Label)));
                break;
            case FootnoteLink:
                break;
            case MdInl.ContainerInline container:
                into.AddRange(Inlines(container));
                break;
        }
    }

    /// <summary>Markdig labels footnotes "^1"; the model carries the bare label "1".</summary>
    private static string FootnoteLabel(string? label) => (label ?? "").TrimStart('^');

    private static string? NullIfEmpty(string? value) => string.IsNullOrEmpty(value) ? null : value;

    /// <summary>Alt-text projection shared by every exporter: formatting dropped, breaks kept.</summary>
    internal static string PlainText(IEnumerable<MarkdownInline> inlines, string softBreak = " ")
    {
        var builder = new StringBuilder();
        foreach (var inline in inlines)
        {
            switch (inline)
            {
                case TextInline t: builder.Append(t.Value); break;
                case CodeInline c: builder.Append(c.Value); break;
                case EmphasisInline e: builder.Append(PlainText(e.Content, softBreak)); break;
                case StrongInline s: builder.Append(PlainText(s.Content, softBreak)); break;
                case StrikethroughInline s: builder.Append(PlainText(s.Content, softBreak)); break;
                case LinkInline l: builder.Append(PlainText(l.Content, softBreak)); break;
                case ImageInline i: builder.Append(PlainText(i.Alt, softBreak)); break;
                case AutolinkInline a: builder.Append(a.Text); break;
                case FootnoteReferenceInline f: builder.Append('[').Append(f.Label).Append(']'); break;
                case SoftBreakInline: builder.Append(softBreak); break;
                case HardBreakInline: builder.Append('\n'); break;
                case RawHtmlInline h: builder.Append(h.Source); break;
            }
        }
        return builder.ToString();
    }
}
