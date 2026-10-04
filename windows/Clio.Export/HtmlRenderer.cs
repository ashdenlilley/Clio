using System.Globalization;
using System.Text;

namespace Clio.Export;

/// <summary>
/// Self-contained, script-free HTML: strict Content-Security-Policy, no external fetches, raw HTML shown as text,
/// unsafe links reduced to their text, images reduced to alt text. Port of macOS <c>HTMLDocumentRenderer</c>.
/// </summary>
public static class HtmlRenderer
{
    public static string Render(MarkdownDocument document, string title, string? language = null, CancellationToken cancellationToken = default)
    {
        var lang = language ?? CultureInfo.CurrentUICulture.TwoLetterISOLanguageName;
        if (lang.Length == 0 || lang == "iv") lang = "en";
        var html = new StringBuilder();
        html.Append("<!doctype html>\n<html lang=\"");
        Escape(html, lang);
        html.Append("\">\n<head>\n  <meta charset=\"utf-8\">\n");
        html.Append("  <meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; object-src 'none'\">\n");
        html.Append("  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n  <title>");
        Escape(html, title);
        html.Append("</title>\n  <style>\n").Append(Stylesheet).Append("\n  </style>\n</head>\n<body>\n  <main class=\"document\">\n");
        var footnoteCounts = new Dictionary<string, int>();
        foreach (var block in document.Blocks)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Write(html, block, footnoteCounts, cancellationToken);
        }
        html.Append("\n  </main>\n</body>\n</html>");
        return html.ToString();
    }

    private const string Stylesheet = """
            :root { color-scheme: light; font-family: "Segoe UI", system-ui, -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
            * { box-sizing: border-box; }
            html { background: #fff; color: #000; font-size: 17px; line-height: 1.62; }
            body { margin: 0; }
            .document { max-width: 46rem; margin: 0 auto; padding: 4rem 2.25rem 6rem; overflow-wrap: anywhere; }
            h1, h2, h3, h4, h5, h6 { line-height: 1.18; margin: 1.8em 0 .65em; page-break-after: avoid; }
            h1 { font-size: 2.2rem; } h2 { font-size: 1.65rem; } h3 { font-size: 1.3rem; }
            p, ul, ol, blockquote, pre, table, hr { margin: 0 0 1.15rem; }
            blockquote { border-left: .2rem solid #8e8e93; margin-left: 0; padding-left: 1.15rem; color: #3a3a3c; }
            code, pre { font-family: ui-monospace, Consolas, SFMono-Regular, Menlo, monospace; }
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
        """;

    private static void Escape(StringBuilder html, string value) => ExportContentPolicy.AppendEscapedHtml(html, value);

    private static void Write(StringBuilder html, MarkdownBlock block, Dictionary<string, int> footnoteCounts, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        switch (block)
        {
            case ParagraphBlock p:
                html.Append("    <p>");
                Write(html, p.Content);
                html.Append("</p>\n");
                break;
            case HeadingBlock h:
                var level = Math.Clamp(h.Level, 1, 6);
                html.Append("    <h").Append(level).Append('>');
                Write(html, h.Content);
                html.Append("</h").Append(level).Append(">\n");
                break;
            case BlockquoteBlock q:
                html.Append("    <blockquote>");
                foreach (var nested in q.Blocks) Write(html, nested, footnoteCounts, ct);
                html.Append("</blockquote>\n");
                break;
            case ListBlock l:
                Write(html, l.List, footnoteCounts, ct);
                break;
            case CodeFenceBlock c:
                html.Append("    <pre><code");
                if (c.Language is not null)
                {
                    html.Append(" class=\"language-");
                    Escape(html, c.Language);
                    html.Append('"');
                }
                html.Append('>');
                Escape(html, c.Source);
                html.Append("</code></pre>\n");
                break;
            case TableBlock t:
                Write(html, t.Table);
                break;
            case ThematicBreakBlock:
                html.Append("    <hr>\n");
                break;
            case FrontMatterBlock f:
                html.Append("    <aside class=\"frontmatter\" aria-label=\"Document metadata\"><pre>");
                Escape(html, f.Source);
                html.Append("</pre></aside>\n");
                break;
            case FootnoteDefinitionBlock d:
                footnoteCounts.TryGetValue(d.Label, out var seen);
                footnoteCounts[d.Label] = ++seen;
                var baseId = ExportContentPolicy.SafeFootnoteId(d.Label);
                html.Append("    <section class=\"footnote\" id=\"");
                Escape(html, seen == 1 ? baseId : $"{baseId}-{seen}");
                html.Append("\" aria-label=\"Footnote ");
                Escape(html, d.Label);
                html.Append("\">");
                foreach (var nested in d.Blocks) Write(html, nested, footnoteCounts, ct);
                html.Append("</section>\n");
                break;
            case RawHtmlBlock r:
                html.Append("    <pre class=\"raw-html\" aria-label=\"Unrendered HTML\">");
                Escape(html, r.Source);
                html.Append("</pre>\n");
                break;
        }
    }

    private static void Write(StringBuilder html, MarkdownList list, Dictionary<string, int> footnoteCounts, CancellationToken ct)
    {
        var tag = list.IsOrdered ? "ol" : "ul";
        html.Append("    <").Append(tag);
        if (list.IsOrdered && list.Start is { } start && start != 1) html.Append(" start=\"").Append(start.ToString(CultureInfo.InvariantCulture)).Append('"');
        html.Append(">\n");
        foreach (var item in list.Items)
        {
            ct.ThrowIfCancellationRequested();
            html.Append("      <li");
            if (item.Task is not null) html.Append(" class=\"task\"");
            html.Append('>');
            switch (item.Task)
            {
                case TaskState.Checked: html.Append("<span class=\"task-marker\" aria-label=\"Completed\">☑</span>"); break;
                case TaskState.Unchecked: html.Append("<span class=\"task-marker\" aria-label=\"Not completed\">☐</span>"); break;
            }
            foreach (var nested in item.Blocks) Write(html, nested, footnoteCounts, ct);
            html.Append("</li>\n");
        }
        html.Append("    </").Append(tag).Append(">\n");
    }

    private static void Write(StringBuilder html, MarkdownTable table)
    {
        void Cell(TableCell cell, int index, string tag, string scope = "")
        {
            var alignment = index < table.Alignments.Count ? table.Alignments[index] : TableAlignment.None;
            var className = alignment switch
            {
                TableAlignment.Center => " class=\"align-center\"",
                TableAlignment.Trailing => " class=\"align-trailing\"",
                _ => "",
            };
            html.Append('<').Append(tag).Append(scope).Append(className).Append('>');
            Write(html, cell.Content);
            html.Append("</").Append(tag).Append('>');
        }

        html.Append("    <table>\n      <thead><tr>");
        for (var i = 0; i < table.Header.Count; i++) Cell(table.Header[i], i, "th", " scope=\"col\"");
        html.Append("</tr></thead>\n      <tbody>\n");
        foreach (var row in table.Rows)
        {
            html.Append("      <tr>");
            for (var i = 0; i < row.Count; i++) Cell(row[i], i, "td");
            html.Append("</tr>\n");
        }
        html.Append("      </tbody>\n    </table>\n");
    }

    private static void Write(StringBuilder html, IEnumerable<MarkdownInline> inlines)
    {
        foreach (var inline in inlines)
        {
            switch (inline)
            {
                case TextInline t: Escape(html, t.Value); break;
                case EmphasisInline e: html.Append("<em>"); Write(html, e.Content); html.Append("</em>"); break;
                case StrongInline s: html.Append("<strong>"); Write(html, s.Content); html.Append("</strong>"); break;
                case StrikethroughInline s: html.Append("<del>"); Write(html, s.Content); html.Append("</del>"); break;
                case CodeInline c: html.Append("<code>"); Escape(html, c.Value); html.Append("</code>"); break;
                case LinkInline l:
                    if (ExportContentPolicy.SafeLink(l.Destination) is not { } safe) { Write(html, l.Content); break; }
                    html.Append("<a href=\"");
                    Escape(html, safe);
                    html.Append('"');
                    if (l.Title is not null)
                    {
                        html.Append(" title=\"");
                        Escape(html, l.Title);
                        html.Append('"');
                    }
                    html.Append('>');
                    Write(html, l.Content);
                    html.Append("</a>");
                    break;
                case ImageInline i:
                    // Exports never read the filesystem or network: images become their alt text.
                    var alt = MarkdownModelBuilder.PlainText(i.Alt, "\n");
                    html.Append("<span role=\"img\" aria-label=\"");
                    Escape(html, alt);
                    html.Append("\">");
                    Escape(html, alt);
                    html.Append("</span>");
                    break;
                case AutolinkInline a:
                    if (ExportContentPolicy.SafeLink(a.Destination) is not { } safeAuto) { Escape(html, a.Text); break; }
                    html.Append("<a href=\"");
                    Escape(html, safeAuto);
                    html.Append("\">");
                    Escape(html, a.Text);
                    html.Append("</a>");
                    break;
                case FootnoteReferenceInline f:
                    html.Append("<sup><a href=\"#");
                    Escape(html, ExportContentPolicy.SafeFootnoteId(f.Label));
                    html.Append("\" aria-label=\"Footnote ");
                    Escape(html, f.Label);
                    html.Append("\">");
                    Escape(html, f.Label);
                    html.Append("</a></sup>");
                    break;
                case SoftBreakInline: html.Append('\n'); break;
                case HardBreakInline: html.Append("<br>\n"); break;
                case RawHtmlInline r: Escape(html, r.Source); break;
            }
        }
    }
}
