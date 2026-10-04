using System.Globalization;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Wordprocessing;

namespace Clio.Export;

/// <summary>
/// Editable Word document (.docx, Open XML). Same content rules as the macOS editable export: native headings, bold,
/// italic, strikethrough, monospaced code, hyperlinks for safe links only, bordered tables, nested indentation.
/// Nothing is fetched and no HTML is imported.
/// </summary>
public static class DocxRenderer
{
    private const string BodyFont = "Calibri";
    private const string CodeFont = "Consolas";
    private const int TwipsPerLevel = 360; // 18 pt, as on macOS

    public static byte[] Render(MarkdownDocument document, string title, CancellationToken cancellationToken = default)
    {
        using var stream = new MemoryStream();
        using (var package = WordprocessingDocument.Create(stream, WordprocessingDocumentType.Document))
        {
            var main = package.AddMainDocumentPart();
            AddStyles(main);
            var body = new Body();
            main.Document = new Document(body);
            var context = new Context(main, cancellationToken);
            context.Blocks(body, document.Blocks, 0, null);
            body.Append(new SectionProperties(
                new PageSize { Width = 12240, Height = 15840 },
                new PageMargin { Top = 1440, Right = 1440, Bottom = 1440, Left = 1440, Header = 720, Footer = 720, Gutter = 0 }));
            package.PackageProperties.Title = title;
            package.PackageProperties.Creator = "Clio";
            main.Document.Save();
        }
        return stream.ToArray();
    }

    private static void AddStyles(MainDocumentPart main)
    {
        var part = main.AddNewPart<StyleDefinitionsPart>();
        var styles = new Styles(new DocDefaults(
            new RunPropertiesDefault(new RunPropertiesBaseStyle(
                new RunFonts { Ascii = BodyFont, HighAnsi = BodyFont, ComplexScript = BodyFont, EastAsia = BodyFont },
                new FontSize { Val = "24" }, new FontSizeComplexScript { Val = "24" })),
            new ParagraphPropertiesDefault(new ParagraphPropertiesBaseStyle(new SpacingBetweenLines { After = "160" }))));
        styles.Append(new Style(new StyleName { Val = "Normal" }, new PrimaryStyle())
        { Type = StyleValues.Paragraph, StyleId = "Normal", Default = true });
        for (var level = 1; level <= 6; level++)
        {
            var size = Math.Max(13, 26 - level * 2) * 2;
            styles.Append(new Style(
                new StyleName { Val = $"heading {level}" },
                new BasedOn { Val = "Normal" },
                new NextParagraphStyle { Val = "Normal" },
                new PrimaryStyle(),
                new StyleParagraphProperties(new KeepNext(), new SpacingBetweenLines { Before = "240", After = "120" }, new OutlineLevel { Val = level - 1 }),
                new StyleRunProperties(new Bold(), new BoldComplexScript(), new FontSize { Val = size.ToString(CultureInfo.InvariantCulture) }))
            { Type = StyleValues.Paragraph, StyleId = $"Heading{level}" });
        }
        styles.Append(new Style(
            new StyleName { Val = "Code" },
            new BasedOn { Val = "Normal" },
            new PrimaryStyle(),
            new StyleParagraphProperties(
                new Shading { Val = ShadingPatternValues.Clear, Color = "auto", Fill = "F2F2F7" },
                new SpacingBetweenLines { After = "160", Line = "260", LineRule = LineSpacingRuleValues.Auto }),
            new StyleRunProperties(
                new RunFonts { Ascii = CodeFont, HighAnsi = CodeFont, ComplexScript = CodeFont },
                new FontSize { Val = "22" }))
        { Type = StyleValues.Paragraph, StyleId = "Code" });
        styles.Append(new Style(
            new StyleName { Val = "Hyperlink" },
            new BasedOn { Val = "DefaultParagraphFont" },
            new StyleRunProperties(new Color { Val = "0066CC" }, new Underline { Val = UnderlineValues.Single }))
        { Type = StyleValues.Character, StyleId = "Hyperlink" });
        styles.Append(new Style(new StyleName { Val = "Default Paragraph Font" }, new UIPriority { Val = 1 }, new SemiHidden(), new UnhideWhenUsed())
        { Type = StyleValues.Character, StyleId = "DefaultParagraphFont", Default = true });
        part.Styles = styles;
    }

    /// <summary>Characters XML 1.0 cannot carry (most C0 controls) become U+FFFD, as in the HTML export.</summary>
    internal static string XmlSafe(string value)
    {
        var needs = false;
        foreach (var c in value) if (c < 0x20 && c is not ('\t' or '\n' or '\r')) { needs = true; break; }
        if (!needs) return value;
        return string.Create(value.Length, value, static (span, source) =>
        {
            for (var i = 0; i < source.Length; i++)
                span[i] = source[i] < 0x20 && source[i] is not ('\t' or '\n' or '\r') ? '�' : source[i];
        });
    }

    private sealed record Fmt(bool Bold = false, bool Italic = false, bool Strike = false, bool Code = false, bool Link = false);

    private sealed class Context(MainDocumentPart main, CancellationToken ct)
    {
        public void Blocks(OpenXmlElement parent, IReadOnlyList<MarkdownBlock> blocks, int depth, IReadOnlyList<MarkdownInline>? lead)
        {
            // `lead` is a list marker or footnote label that shares the first paragraph with the first block.
            var pending = lead;
            foreach (var block in blocks)
            {
                ct.ThrowIfCancellationRequested();
                if (pending is not null && block is not (ParagraphBlock or HeadingBlock))
                {
                    parent.Append(ParagraphOf(depth, null, [], pending));
                    pending = null;
                }
                switch (block)
                {
                    case ParagraphBlock p:
                        parent.Append(ParagraphOf(depth, null, p.Content, pending));
                        pending = null;
                        break;
                    case HeadingBlock h:
                        parent.Append(ParagraphOf(depth, $"Heading{Math.Clamp(h.Level, 1, 6)}", h.Content, pending));
                        pending = null;
                        break;
                    case BlockquoteBlock q:
                        QuoteBlocks(parent, q.Blocks, depth + 1);
                        break;
                    case ListBlock l:
                        for (var index = 0; index < l.List.Items.Count; index++)
                        {
                            var item = l.List.Items[index];
                            var marker = item.Task is { } task ? (task == TaskState.Checked ? "☑" : "☐")
                                : l.List.IsOrdered ? ((l.List.Start ?? 1) + index).ToString(CultureInfo.InvariantCulture) + "."
                                : "•";
                            Blocks(parent, item.Blocks, depth + 1, [new TextInline(marker + " ")]);
                            if (item.Blocks.Count == 0) parent.Append(ParagraphOf(depth + 1, null, [], [new TextInline(marker + " ")]));
                        }
                        break;
                    case CodeFenceBlock c:
                        parent.Append(CodeParagraph(c.Source, depth));
                        break;
                    case FrontMatterBlock f:
                        parent.Append(CodeParagraph(f.Source, depth));
                        break;
                    case RawHtmlBlock r:
                        parent.Append(CodeParagraph(r.Source, depth));
                        break;
                    case ThematicBreakBlock:
                        parent.Append(new Paragraph(
                            new ParagraphProperties(
                                new ParagraphBorders(new BottomBorder { Val = BorderValues.Single, Size = 6, Space = 1, Color = "8E8E93" }),
                                Indent(depth))));
                        break;
                    case FootnoteDefinitionBlock d:
                        Blocks(parent, d.Blocks, depth, [new TextInline($"[{d.Label}] ")]);
                        if (d.Blocks.Count == 0) parent.Append(ParagraphOf(depth, null, [], [new TextInline($"[{d.Label}] ")]));
                        break;
                    case TableBlock t:
                        parent.Append(TableOf(t.Table, depth));
                        parent.Append(new Paragraph());
                        break;
                }
            }
            if (pending is not null) parent.Append(ParagraphOf(depth, null, [], pending));
        }

        private void QuoteBlocks(OpenXmlElement parent, IReadOnlyList<MarkdownBlock> blocks, int depth)
        {
            var start = parent.ChildElements.Count;
            Blocks(parent, blocks, depth, null);
            // Quoted paragraphs get a left rule; nested containers (lists, tables) keep their own structure.
            foreach (var paragraph in parent.ChildElements.Skip(start).OfType<Paragraph>())
            {
                var props = paragraph.GetFirstChild<ParagraphProperties>() ?? paragraph.PrependChild(new ParagraphProperties());
                props.ParagraphBorders ??= new ParagraphBorders(new LeftBorder { Val = BorderValues.Single, Size = 12, Space = 8, Color = "8E8E93" });
            }
        }

        private static Indentation Indent(int depth) => new() { Left = (depth * TwipsPerLevel).ToString(CultureInfo.InvariantCulture) };

        private Paragraph ParagraphOf(int depth, string? style, IReadOnlyList<MarkdownInline> content, IReadOnlyList<MarkdownInline>? lead, TableAlignment alignment = TableAlignment.None, bool boldAll = false)
        {
            var props = new ParagraphProperties();
            if (style is not null) props.ParagraphStyleId = new ParagraphStyleId { Val = style };
            if (depth > 0) props.Indentation = Indent(depth);
            var justify = alignment switch
            {
                TableAlignment.Center => JustificationValues.Center,
                TableAlignment.Trailing => JustificationValues.Right,
                _ => (JustificationValues?)null,
            };
            if (justify is { } j) props.Justification = new Justification { Val = j };
            var paragraph = new Paragraph(props);
            var baseStyle = new Fmt(Bold: boldAll);
            if (lead is not null) Inlines(paragraph, lead, baseStyle);
            Inlines(paragraph, content, baseStyle);
            return paragraph;
        }

        private static Paragraph CodeParagraph(string source, int depth)
        {
            var props = new ParagraphProperties(new ParagraphStyleId { Val = "Code" });
            if (depth > 0) props.Indentation = Indent(depth);
            var paragraph = new Paragraph(props);
            var lines = source.TrimEnd('\n').Split('\n');
            for (var i = 0; i < lines.Length; i++)
            {
                if (i > 0) paragraph.Append(new Run(new Break()));
                paragraph.Append(TextRun(lines[i].TrimEnd('\r'), new Fmt(Code: true)));
            }
            return paragraph;
        }

        private Table TableOf(MarkdownTable table, int depth)
        {
            var columns = Math.Max(1, Math.Max(table.Header.Count, table.Rows.Count == 0 ? 0 : table.Rows.Max(r => r.Count)));
            var border = (Func<BorderType>[])[
                () => new TopBorder(), () => new LeftBorder(), () => new BottomBorder(), () => new RightBorder(),
                () => new InsideHorizontalBorder(), () => new InsideVerticalBorder()];
            var borders = new TableBorders();
            foreach (var make in border)
            {
                var b = make();
                b.Val = BorderValues.Single;
                b.Size = 4;
                b.Space = 0;
                b.Color = "8E8E93";
                borders.Append(b);
            }
            var properties = new TableProperties(
                new TableWidth { Width = "5000", Type = TableWidthUnitValues.Pct },
                borders,
                new TableCellMarginDefault(
                    new TopMargin { Width = "40", Type = TableWidthUnitValues.Dxa },
                    new LeftMargin { Width = "100", Type = TableWidthUnitValues.Dxa },
                    new BottomMargin { Width = "40", Type = TableWidthUnitValues.Dxa },
                    new RightMargin { Width = "100", Type = TableWidthUnitValues.Dxa }));
            if (depth > 0) properties.Append(new TableIndentation { Width = depth * TwipsPerLevel, Type = TableWidthUnitValues.Dxa });
            var result = new Table(properties, new TableGrid(Enumerable.Range(0, columns).Select(_ => new GridColumn())));

            TableRow Row(IReadOnlyList<TableCell> cells, bool header)
            {
                var row = new TableRow();
                if (header) row.Append(new TableRowProperties(new TableHeader()));
                for (var column = 0; column < columns; column++)
                {
                    ct.ThrowIfCancellationRequested();
                    var alignment = column < table.Alignments.Count ? table.Alignments[column] : TableAlignment.None;
                    var content = column < cells.Count ? cells[column].Content : [];
                    row.Append(new DocumentFormat.OpenXml.Wordprocessing.TableCell(ParagraphOf(0, null, content, null, alignment, header)));
                }
                return row;
            }

            result.Append(Row(table.Header, header: true));
            foreach (var row in table.Rows) result.Append(Row(row, header: false));
            return result;
        }

        private void Inlines(OpenXmlCompositeElement paragraph, IEnumerable<MarkdownInline> inlines, Fmt style)
        {
            foreach (var inline in inlines)
            {
                ct.ThrowIfCancellationRequested();
                switch (inline)
                {
                    case TextInline t: paragraph.Append(TextRun(t.Value, style)); break;
                    case RawHtmlInline r: paragraph.Append(TextRun(r.Source, style)); break;
                    case CodeInline c: paragraph.Append(TextRun(c.Value, style with { Code = true })); break;
                    case StrongInline s: Inlines(paragraph, s.Content, style with { Bold = true }); break;
                    case EmphasisInline e: Inlines(paragraph, e.Content, style with { Italic = true }); break;
                    case StrikethroughInline s: Inlines(paragraph, s.Content, style with { Strike = true }); break;
                    case LinkInline l: AppendLink(paragraph, l.Destination, style, p => Inlines(p, l.Content, style with { Link = true })); break;
                    case AutolinkInline a: AppendLink(paragraph, a.Destination, style, p => p.Append(TextRun(a.Text, style with { Link = true }))); break;
                    case ImageInline i:
                        paragraph.Append(TextRun("[Image: " + MarkdownModelBuilder.PlainText(i.Alt) + "]", style));
                        break;
                    case FootnoteReferenceInline f: paragraph.Append(TextRun($"[{f.Label}]", style)); break;
                    case SoftBreakInline: paragraph.Append(TextRun(" ", style)); break;
                    case HardBreakInline: paragraph.Append(new Run(new Break())); break;
                }
            }
        }

        private void AppendLink(OpenXmlCompositeElement paragraph, string destination, Fmt style, Action<OpenXmlCompositeElement> content)
        {
            if (ExportContentPolicy.SafeLink(destination) is { } safe && Uri.TryCreate(safe, UriKind.RelativeOrAbsolute, out var uri))
            {
                var relationship = main.AddHyperlinkRelationship(uri, isExternal: true);
                var link = new Hyperlink { Id = relationship.Id, History = true };
                content(link);
                paragraph.Append(link);
            }
            else
            {
                var holder = new Paragraph();
                content(holder);
                foreach (var child in holder.ChildElements.ToList()) paragraph.Append(child.CloneNode(true));
            }
        }

        /// <summary>A run for <paramref name="text"/>; embedded line feeds become Word line breaks.</summary>
        private static Run TextRun(string text, Fmt style)
        {
            var run = new Run();
            var props = new RunProperties();
            if (style.Link) props.Append(new DocumentFormat.OpenXml.Wordprocessing.RunStyle { Val = "Hyperlink" });
            if (style.Code) props.Append(new RunFonts { Ascii = CodeFont, HighAnsi = CodeFont, ComplexScript = CodeFont }, new FontSize { Val = "22" });
            if (style.Bold) props.Append(new Bold(), new BoldComplexScript());
            if (style.Italic) props.Append(new Italic(), new ItalicComplexScript());
            if (style.Strike) props.Append(new Strike());
            if (props.HasChildren) run.Append(props);
            var lines = XmlSafe(text).Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
            for (var i = 0; i < lines.Length; i++)
            {
                if (i > 0) run.Append(new Break());
                if (lines[i].Length > 0) run.Append(new Text(lines[i]) { Space = SpaceProcessingModeValues.Preserve });
            }
            return run;
        }

    }
}
