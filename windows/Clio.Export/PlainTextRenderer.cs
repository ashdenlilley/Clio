using System.Globalization;
using System.Text;

namespace Clio.Export;

/// <summary>
/// Plain-text export (macOS <c>EditableDocumentRenderer</c> with <c>plain: true</c>): no Markdown punctuation, links
/// as "text (destination)", images as "[Image: alt]", tables tab-separated, lists with "•", "n." or ☑/☐ markers.
/// </summary>
public static class PlainTextRenderer
{
    public static string Render(MarkdownDocument document, CancellationToken cancellationToken = default)
    {
        var output = new StringBuilder();
        Blocks(output, document.Blocks, 0, cancellationToken);
        return output.ToString();
    }

    private static void Blocks(StringBuilder output, IReadOnlyList<MarkdownBlock> blocks, int depth, CancellationToken ct)
    {
        foreach (var block in blocks)
        {
            ct.ThrowIfCancellationRequested();
            switch (block)
            {
                case ParagraphBlock p:
                    Inlines(output, p.Content);
                    output.Append('\n');
                    break;
                case HeadingBlock h:
                    Inlines(output, h.Content);
                    output.Append('\n');
                    break;
                case BlockquoteBlock q:
                    Blocks(output, q.Blocks, depth + 1, ct);
                    break;
                case ListBlock l:
                    for (var index = 0; index < l.List.Items.Count; index++)
                    {
                        var item = l.List.Items[index];
                        var marker = item.Task is { } task ? (task == TaskState.Checked ? "☑" : "☐")
                            : l.List.IsOrdered ? ((l.List.Start ?? 1) + index).ToString(CultureInfo.InvariantCulture) + "."
                            : "•";
                        output.Append(' ', depth * 2).Append(marker).Append(' ');
                        Blocks(output, item.Blocks, depth + 1, ct);
                    }
                    break;
                case CodeFenceBlock c:
                    output.Append(c.Source).Append('\n');
                    break;
                case FrontMatterBlock f:
                    output.Append(f.Source).Append('\n');
                    break;
                case RawHtmlBlock r:
                    output.Append(r.Source).Append('\n');
                    break;
                case ThematicBreakBlock:
                    output.Append("────────\n");
                    break;
                case FootnoteDefinitionBlock d:
                    output.Append('[').Append(d.Label).Append("] ");
                    Blocks(output, d.Blocks, depth, ct);
                    break;
                case TableBlock t:
                    foreach (var row in t.Table.Rows.Prepend(t.Table.Header))
                    {
                        for (var column = 0; column < row.Count; column++)
                        {
                            Inlines(output, row[column].Content);
                            output.Append(column < row.Count - 1 ? '\t' : '\n');
                        }
                    }
                    break;
            }
        }
    }

    private static void Inlines(StringBuilder output, IEnumerable<MarkdownInline> inlines)
    {
        foreach (var inline in inlines)
        {
            switch (inline)
            {
                case TextInline t: output.Append(t.Value); break;
                case RawHtmlInline r: output.Append(r.Source); break;
                case CodeInline c: output.Append(c.Value); break;
                case EmphasisInline e: Inlines(output, e.Content); break;
                case StrongInline s: Inlines(output, s.Content); break;
                case StrikethroughInline s: Inlines(output, s.Content); break;
                case LinkInline l:
                    Inlines(output, l.Content);
                    output.Append(" (").Append(l.Destination).Append(')');
                    break;
                case ImageInline i:
                    output.Append("[Image: ");
                    Inlines(output, i.Alt);
                    output.Append(']');
                    break;
                case AutolinkInline a: output.Append(a.Text); break;
                case FootnoteReferenceInline f: output.Append('[').Append(f.Label).Append(']'); break;
                case SoftBreakInline: output.Append(' '); break;
                case HardBreakInline: output.Append('\n'); break;
            }
        }
    }
}
