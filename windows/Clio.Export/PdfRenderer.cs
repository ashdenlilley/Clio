using System.Globalization;
using MigraDoc.DocumentObjectModel;
using MigraDoc.DocumentObjectModel.Tables;
using MigraDoc.Rendering;
using PdfSharp.Fonts;
using PdfSharp.Pdf;

namespace Clio.Export;

/// <summary>
/// Paginated PDF built with PDFsharp/MigraDoc from the shared document model. Layout constants follow the macOS
/// exporter: 11.5 pt body, 1.45 line height, heading scale 25/20/16.5/14.5/13/12, 10 pt code, a title header and a page
/// number on every page, tables with a rule under the header row. Fonts are the Windows system fonts (Segoe UI,
/// Consolas); nothing is downloaded and no image is fetched.
/// </summary>
public static class PdfRenderer
{
    private const string BodyFont = "Segoe UI";
    private const string CodeFont = "Consolas";
    private const string SymbolFont = "Segoe UI Symbol";
    private const double Indent = 18;
    private static readonly double[] HeadingSizes = [25, 20, 16.5, 14.5, 13, 12];
    private static readonly Color Ink = Colors.Black;
    private static readonly object FontLock = new();
    private static bool _fontsConfigured;

    public static byte[] Render(MarkdownDocument document, string title, PdfPrintSettings? settings, CancellationToken cancellationToken = default)
    {
        var fallback = PdfPrintSettings.RegionalDefault();
        var effective = settings ?? fallback;
        var geometry = PdfPrintGeometry.Resolve(effective, fallback);
        ConfigureFonts();

        var doc = new Document();
        doc.Info.Title = title;
        doc.Info.Author = "Clio";
        var normal = doc.Styles[StyleNames.Normal]!;
        normal.Font.Name = BodyFont;
        normal.Font.Size = 11.5;
        normal.Font.Color = Ink;

        var section = doc.AddSection();
        var m = effective.Margins;
        section.PageSetup.PageWidth = Unit.FromPoint(geometry.PageWidth);
        section.PageSetup.PageHeight = Unit.FromPoint(geometry.PageHeight);
        section.PageSetup.LeftMargin = Unit.FromPoint(m.Leading);
        section.PageSetup.RightMargin = Unit.FromPoint(m.Trailing);
        section.PageSetup.TopMargin = Unit.FromPoint(m.Top + PdfPrintGeometry.HeaderHeight);
        section.PageSetup.BottomMargin = Unit.FromPoint(m.Bottom + PdfPrintGeometry.FooterHeight);
        section.PageSetup.HeaderDistance = Unit.FromPoint(m.Top);
        section.PageSetup.FooterDistance = Unit.FromPoint(m.Bottom);

        var header = section.Headers.Primary.AddParagraph(Truncate(title, geometry.ContentWidth));
        header.Format.Font.Size = 9;
        header.Format.Font.Color = Ink;
        var footer = section.Footers.Primary.AddParagraph();
        footer.Format.Alignment = ParagraphAlignment.Right;
        footer.Format.Font.Size = 9;
        footer.Format.Font.Color = Ink;
        footer.AddPageField();

        var builder = new Builder(section, geometry.ContentWidth, cancellationToken);
        builder.Blocks(document.Blocks, 0, null, tight: false);
        if (section.Elements.Count == 0) section.AddParagraph();

        var renderer = new PdfDocumentRenderer { Document = doc };
        renderer.RenderDocument();
        cancellationToken.ThrowIfCancellationRequested();
        if (renderer.PdfDocument.PageCount == 0) throw new EmptyPdfPageException();
        using var stream = new MemoryStream();
        renderer.PdfDocument.Save(stream, closeStream: false);
        return stream.ToArray();
    }

    private static void ConfigureFonts()
    {
        lock (FontLock)
        {
            if (_fontsConfigured) return;
            // Must be set before the first font is used; an app that installed its own resolver keeps it.
            GlobalFontSettings.FontResolver ??= new WindowsFontResolver();
            _fontsConfigured = true;
        }
    }

    /// <summary>The header shows the title on one line; a title too wide for the page ends in "...".</summary>
    private static string Truncate(string title, double width)
    {
        var clean = DocxRenderer.XmlSafe(title).Replace('\n', ' ').Replace('\r', ' ');
        var capacity = Math.Max(4, (int)(width / 4.7));
        return clean.Length <= capacity ? clean : clean[..(capacity - 3)].TrimEnd() + "...";
    }

    private sealed record Fmt(bool Bold = false, bool Italic = false, bool Strike = false, bool Code = false, bool Underline = false);

    private sealed class Builder(Section section, double contentWidth, CancellationToken ct)
    {
        public void Blocks(IReadOnlyList<MarkdownBlock> blocks, int depth, IReadOnlyList<MarkdownInline>? lead, bool tight, ListLead? marker = null)
        {
            // `lead` text (footnote label) or `marker` (list bullet) shares the first paragraph with the first block.
            var pending = lead;
            var pendingMarker = marker;
            foreach (var block in blocks)
            {
                ct.ThrowIfCancellationRequested();
                if ((pending is not null || pendingMarker is not null) && block is not (ParagraphBlock or HeadingBlock))
                {
                    var holder = NewParagraph(depth, 11.5, 8, 1.42, hanging: pendingMarker is not null);
                    AppendLead(holder, pending, pendingMarker);
                    pending = null;
                    pendingMarker = null;
                }
                switch (block)
                {
                    case ParagraphBlock p:
                        var paragraph = pendingMarker is not null
                            ? NewParagraph(depth, 11.5, tight ? 3 : 8, 1.42, hanging: true)
                            : NewParagraph(depth, 11.5, 10, 1.45);
                        AppendLead(paragraph, pending, pendingMarker);
                        pending = null;
                        pendingMarker = null;
                        Inlines(paragraph, p.Content, new Fmt());
                        break;
                    case HeadingBlock h:
                        var level = Math.Clamp(h.Level, 1, 6);
                        var heading = NewParagraph(depth, HeadingSizes[level - 1], level <= 2 ? 14 : 10, 1.18, bold: true);
                        heading.Format.KeepWithNext = true;
                        heading.Format.OutlineLevel = (OutlineLevel)level;
                        AppendLead(heading, pending, pendingMarker);
                        pending = null;
                        pendingMarker = null;
                        Inlines(heading, h.Content, new Fmt(Bold: true));
                        break;
                    case BlockquoteBlock q:
                        var quote = NewParagraph(depth, 11.5, 8, 1.45);
                        quote.AddText("> ");
                        Blocks(q.Blocks, depth + 1, null, tight: false);
                        break;
                    case ListBlock l:
                        for (var index = 0; index < l.List.Items.Count; index++)
                        {
                            ct.ThrowIfCancellationRequested();
                            var item = l.List.Items[index];
                            var text = item.Task is { } task ? null
                                : l.List.IsOrdered ? ((l.List.Start ?? 1) + index).ToString(CultureInfo.InvariantCulture) + ". "
                                : "• ";
                            var symbol = item.Task is { } t ? (t == TaskState.Checked ? "☑ " : "☐ ") : null;
                            var leadMarker = new ListLead(text, symbol);
                            Blocks(item.Blocks, depth + 1, null, l.List.IsTight, leadMarker);
                            if (item.Blocks.Count == 0)
                                AppendLead(NewParagraph(depth + 1, 11.5, l.List.IsTight ? 3 : 8, 1.42, hanging: true), null, leadMarker);
                        }
                        break;
                    case CodeFenceBlock c:
                        var code = NewCode(depth);
                        if (!string.IsNullOrEmpty(c.Language))
                        {
                            code.AddText(c.Language);
                            code.AddLineBreak();
                        }
                        CodeText(code, c.Source);
                        break;
                    case FrontMatterBlock f:
                        CodeText(NewCode(depth), f.Source);
                        break;
                    case RawHtmlBlock r:
                        CodeText(NewCode(depth), r.Source);
                        break;
                    case ThematicBreakBlock:
                        NewParagraph(depth, 11.5, 10, 1.45).AddText("------------------------");
                        break;
                    case FootnoteDefinitionBlock d:
                        Blocks(d.Blocks, depth + 1, [new TextInline($"[{d.Label}] ")], tight: false);
                        if (d.Blocks.Count == 0) Inlines(NewParagraph(depth, 11.5, 10, 1.45), [new TextInline($"[{d.Label}] ")], new Fmt());
                        break;
                    case TableBlock t:
                        Table(t.Table, depth);
                        break;
                }
            }
            if (pending is not null || pendingMarker is not null)
                AppendLead(NewParagraph(depth, 11.5, 8, 1.42, hanging: pendingMarker is not null), pending, pendingMarker);
        }

        public sealed record ListLead(string? Text, string? Symbol);

        private void AppendLead(Paragraph paragraph, IReadOnlyList<MarkdownInline>? lead, ListLead? marker)
        {
            if (marker is not null)
            {
                if (marker.Symbol is not null) paragraph.AddFormattedText(marker.Symbol, new Font(SymbolFont));
                if (marker.Text is not null) paragraph.AddText(marker.Text);
            }
            if (lead is not null) Inlines(paragraph, lead, new Fmt());
        }

        private Paragraph NewParagraph(int depth, double size, double after, double lineHeight, bool bold = false, bool hanging = false)
        {
            var p = section.AddParagraph();
            p.Format.Font.Size = size;
            p.Format.Font.Bold = bold;
            p.Format.SpaceAfter = Unit.FromPoint(after);
            p.Format.LineSpacingRule = LineSpacingRule.Multiple;
            p.Format.LineSpacing = Unit.FromPoint(lineHeight);
            // MigraDoc counts FirstLineIndent from LeftIndent: a hanging marker sits one level to the left.
            p.Format.LeftIndent = Unit.FromPoint(depth * Indent);
            if (hanging) p.Format.FirstLineIndent = Unit.FromPoint(-Indent);
            return p;
        }

        private Paragraph NewCode(int depth)
        {
            var p = NewParagraph(depth, 10, 11, 1.35);
            p.Format.Font.Name = CodeFont;
            return p;
        }

        private void CodeText(Paragraph paragraph, string source)
        {
            var lines = DocxRenderer.XmlSafe(source).TrimEnd('\n').Split('\n');
            for (var i = 0; i < lines.Length; i++)
            {
                if (i > 0) paragraph.AddLineBreak();
                var line = lines[i].TrimEnd('\r').Replace("\t", "    ");
                if (line.Length > 0) paragraph.AddText(line);
            }
        }

        private void Table(MarkdownTable table, int depth)
        {
            var columns = Math.Max(1, Math.Max(table.Header.Count, table.Rows.Count == 0 ? 0 : table.Rows.Max(r => r.Count)));
            var inset = Math.Min(depth * Indent, Math.Max(0, contentWidth - 40));
            var width = Math.Max(1, contentWidth - inset);
            var columnWidth = width / columns;
            var padding = Math.Min(6, columnWidth * 0.1);
            var cellWidth = Math.Max(0.1, columnWidth - 2 * padding);
            var fontSize = Math.Min(10.5, cellWidth / 2);

            var t = section.AddTable();
            t.Borders.Visible = false;
            t.Borders.Color = Colors.Gray;
            t.Borders.Width = 0.5;
            t.LeftPadding = Unit.FromPoint(padding);
            t.RightPadding = Unit.FromPoint(padding);
            t.TopPadding = 1.5;
            t.BottomPadding = 1.5;
            t.Rows.LeftIndent = Unit.FromPoint(inset);
            for (var c = 0; c < columns; c++) t.AddColumn(Unit.FromPoint(columnWidth));

            for (var rowIndex = 0; rowIndex <= table.Rows.Count; rowIndex++)
            {
                ct.ThrowIfCancellationRequested();
                var cells = rowIndex == 0 ? table.Header : table.Rows[rowIndex - 1];
                var row = t.AddRow();
                row.HeadingFormat = rowIndex == 0;
                row.Format.Font.Size = fontSize;
                row.Format.Font.Bold = rowIndex == 0;
                row.Format.SpaceAfter = Unit.FromPoint(1);
                row.Format.LineSpacingRule = LineSpacingRule.Multiple;
                row.Format.LineSpacing = Unit.FromPoint(1.35);
                if (rowIndex == 0)
                {
                    row.Borders.Bottom.Visible = true;
                    row.Borders.Bottom.Color = Ink;
                    row.Borders.Bottom.Width = 0.5;
                }
                for (var c = 0; c < columns; c++)
                {
                    var alignment = c < table.Alignments.Count ? table.Alignments[c] : TableAlignment.Leading;
                    var cell = row.Cells[c];
                    cell.Format.Alignment = alignment switch
                    {
                        TableAlignment.Trailing => ParagraphAlignment.Right,
                        TableAlignment.Center => ParagraphAlignment.Center,
                        _ => ParagraphAlignment.Left,
                    };
                    var paragraph = cell.AddParagraph();
                    if (c < cells.Count) Inlines(paragraph, cells[c].Content, new Fmt(Bold: rowIndex == 0), inTable: true);
                }
            }
            // Space after the table, as the macOS builder appends a trailing body paragraph.
            NewParagraph(depth, 11.5, 10, 1.45);
        }

        private void Inlines(Paragraph paragraph, IEnumerable<MarkdownInline> inlines, Fmt style, bool inTable = false)
        {
            foreach (var inline in inlines)
            {
                ct.ThrowIfCancellationRequested();
                switch (inline)
                {
                    case TextInline t: Text(paragraph, t.Value, style); break;
                    case RawHtmlInline r: Text(paragraph, r.Source, style); break;
                    case CodeInline c: Text(paragraph, c.Value, style with { Code = true }); break;
                    case StrongInline s: Inlines(paragraph, s.Content, style with { Bold = true }, inTable); break;
                    case EmphasisInline e: Inlines(paragraph, e.Content, style with { Italic = true }, inTable); break;
                    case StrikethroughInline s:
                        // MigraDoc has no line-through: struck text is muted and delimited so the meaning survives.
                        Text(paragraph, "~~", style with { Strike = true });
                        Inlines(paragraph, s.Content, style with { Strike = true }, inTable);
                        Text(paragraph, "~~", style with { Strike = true });
                        break;
                    case LinkInline l:
                        var safe = ExportContentPolicy.SafeLink(l.Destination);
                        var target = safe is not null && IsAbsolute(safe) ? paragraph.AddHyperlink(safe, HyperlinkType.Url) : null;
                        if (target is not null) Inlines(target, l.Content, style with { Underline = true });
                        else Inlines(paragraph, l.Content, style with { Underline = true }, inTable);
                        if (safe is not null) Text(paragraph, $" ({safe})", style);
                        break;
                    case AutolinkInline a:
                        var autoSafe = ExportContentPolicy.SafeLink(a.Destination);
                        if (autoSafe is not null && IsAbsolute(autoSafe))
                            Text(paragraph.AddHyperlink(autoSafe, HyperlinkType.Url), a.Text, style with { Underline = true });
                        else Text(paragraph, a.Text, style with { Underline = true });
                        break;
                    case ImageInline i: Text(paragraph, "[Image: " + MarkdownModelBuilder.PlainText(i.Alt) + "]", style); break;
                    case FootnoteReferenceInline f: Text(paragraph, $"[{f.Label}]", style); break;
                    case SoftBreakInline: Text(paragraph, " ", style); break;
                    case HardBreakInline: if (inTable) Text(paragraph, " ", style); else paragraph.AddLineBreak(); break;
                }
            }
        }

        // Hyperlink is a different container type from Paragraph in MigraDoc; these overloads cover both.
        private void Inlines(Hyperlink link, IEnumerable<MarkdownInline> inlines, Fmt style)
        {
            foreach (var inline in inlines)
            {
                switch (inline)
                {
                    case TextInline t: Text(link, t.Value, style); break;
                    case CodeInline c: Text(link, c.Value, style with { Code = true }); break;
                    case StrongInline s: Inlines(link, s.Content, style with { Bold = true }); break;
                    case EmphasisInline e: Inlines(link, e.Content, style with { Italic = true }); break;
                    case StrikethroughInline s: Inlines(link, s.Content, style with { Strike = true }); break;
                    case LinkInline l: Inlines(link, l.Content, style); break;
                    case ImageInline i: Text(link, "[Image: " + MarkdownModelBuilder.PlainText(i.Alt) + "]", style); break;
                    case AutolinkInline a: Text(link, a.Text, style); break;
                    case FootnoteReferenceInline f: Text(link, $"[{f.Label}]", style); break;
                    case SoftBreakInline or HardBreakInline: Text(link, " ", style); break;
                    case RawHtmlInline r: Text(link, r.Source, style); break;
                }
            }
        }

        private static bool IsAbsolute(string url) => url.Contains(':');

        private void Text(Paragraph paragraph, string value, Fmt style) => Append(paragraph.AddFormattedText(), value, style);

        private void Text(Hyperlink link, string value, Fmt style) => Append(link.AddFormattedText(), value, style);

        private static void Append(FormattedText run, string value, Fmt style)
        {
            run.Bold = style.Bold;
            run.Italic = style.Italic;
            if (style.Underline) run.Underline = Underline.Single;
            if (style.Strike) run.Color = Colors.Gray;
            if (style.Code)
            {
                run.Font.Name = CodeFont;
                run.Font.Size = 10.5;
            }
            run.AddText(DocxRenderer.XmlSafe(value));
        }
    }
}
