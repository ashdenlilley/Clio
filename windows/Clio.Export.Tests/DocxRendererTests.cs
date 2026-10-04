using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Validation;
using DocumentFormat.OpenXml.Wordprocessing;
using Xunit;

namespace Clio.Export.Tests;

public class DocxRendererTests
{
    private const string Sample = "# Notes\n\n**Bold** and *italic* 🙂 and ~~gone~~\n\n[Example](https://example.com) and [bad](javascript:alert(1))\n\n| Name | Value |\n| ---: | --- |\n| First | Second |\n\n- one\n- [x] done\n\n1. first\n\n> quoted\n\n```\ncode line\n```\n";

    private static byte[] Docx(string markdown, string title = "Notes.md") =>
        DocumentExporter.Render(ExportFormat.Docx, markdown, title);

    private static WordprocessingDocument Open(byte[] data) => WordprocessingDocument.Open(new MemoryStream(data), false);

    [Fact]
    public void IsAnOpenXmlPackageThatValidates()
    {
        var data = Docx(Sample);

        Assert.Equal([0x50, 0x4b], data.Take(2));
        using var doc = Open(data);
        var errors = new OpenXmlValidator().Validate(doc).ToList();
        Assert.True(errors.Count == 0, string.Join("\n", errors.Select(e => e.Description + " @ " + e.Path?.XPath)));
        Assert.Equal("Notes.md", doc.PackageProperties.Title);
    }

    [Fact]
    public void KeepsReadableTextAndRunFormatting()
    {
        using var doc = Open(Docx(Sample));
        var body = doc.MainDocumentPart!.Document!.Body!;
        var text = string.Join("\n", body.Descendants<Paragraph>().Select(p => p.InnerText));

        Assert.Contains("Bold and italic 🙂 and gone", text);
        Assert.Contains("First", text);
        Assert.Contains("code line", text);
        Assert.DoesNotContain("**Bold**", text);
        Assert.DoesNotContain("# Notes", text);

        var bold = body.Descendants<Run>().Single(r => r.InnerText == "Bold");
        Assert.NotNull(bold.RunProperties?.Bold);
        var italic = body.Descendants<Run>().Single(r => r.InnerText == "italic");
        Assert.NotNull(italic.RunProperties?.Italic);
        var struck = body.Descendants<Run>().Single(r => r.InnerText == "gone");
        Assert.NotNull(struck.RunProperties?.Strike);
    }

    [Fact]
    public void HeadingsUseNativeStylesWithOutlineLevels()
    {
        using var doc = Open(Docx("# One\n\n### Three\n"));
        var paragraphs = doc.MainDocumentPart!.Document!.Body!.Descendants<Paragraph>().ToList();

        Assert.Equal("Heading1", paragraphs[0].ParagraphProperties!.ParagraphStyleId!.Val!.Value);
        Assert.Equal("Heading3", paragraphs[1].ParagraphProperties!.ParagraphStyleId!.Val!.Value);
        var styles = doc.MainDocumentPart.StyleDefinitionsPart!.Styles!.Elements<Style>().ToDictionary(s => s.StyleId!.Value!);
        Assert.Equal(2, styles["Heading3"].StyleParagraphProperties!.OutlineLevel!.Val!.Value);
    }

    [Fact]
    public void OnlySafeLinksBecomeHyperlinks()
    {
        using var doc = Open(Docx(Sample));
        var main = doc.MainDocumentPart!;
        var links = main.Document!.Body!.Descendants<Hyperlink>().ToList();

        var link = Assert.Single(links);
        Assert.Equal("Example", link.InnerText);
        var relationship = Assert.Single(main.HyperlinkRelationships);
        Assert.Equal(link.Id!.Value, relationship.Id);
        Assert.Equal("https://example.com/", relationship.Uri.ToString());
        Assert.Contains("bad", main.Document.Body.InnerText);
        Assert.DoesNotContain(main.HyperlinkRelationships, r => r.Uri.ToString().Contains("javascript"));
    }

    [Fact]
    public void TablesCarryBordersHeaderRowAndAlignment()
    {
        using var doc = Open(Docx(Sample));
        var table = Assert.Single(doc.MainDocumentPart!.Document!.Body!.Descendants<Table>());
        var rows = table.Elements<TableRow>().ToList();

        Assert.Equal(2, rows.Count);
        Assert.NotNull(rows[0].TableRowProperties?.GetFirstChild<TableHeader>());
        Assert.NotNull(table.GetFirstChild<TableProperties>()!.TableBorders);
        var headerRun = rows[0].Descendants<Run>().First();
        Assert.NotNull(headerRun.RunProperties?.Bold);
        var firstCell = rows[1].Elements<DocumentFormat.OpenXml.Wordprocessing.TableCell>().First();
        Assert.Equal(JustificationValues.Right, firstCell.Descendants<Paragraph>().First().ParagraphProperties!.Justification!.Val!.Value);
    }

    [Fact]
    public void ListMarkersQuotesAndCodeKeepTheirShape()
    {
        using var doc = Open(Docx(Sample));
        var paragraphs = doc.MainDocumentPart!.Document!.Body!.Descendants<Paragraph>().Select(p => p.InnerText).ToList();

        Assert.Contains("• one", paragraphs);
        Assert.Contains("☑ done", paragraphs);
        Assert.Contains("1. first", paragraphs);
        var quote = doc.MainDocumentPart.Document.Body.Descendants<Paragraph>().Single(p => p.InnerText == "quoted");
        Assert.NotNull(quote.ParagraphProperties!.ParagraphBorders!.LeftBorder);
        var code = doc.MainDocumentPart.Document.Body.Descendants<Paragraph>().Single(p => p.InnerText == "code line");
        Assert.Equal("Code", code.ParagraphProperties!.ParagraphStyleId!.Val!.Value);
    }

    [Fact]
    public void HostileTextCannotBreakTheXmlPackage()
    {
        var data = Docx("Control \u0001 char and <b>markup</b> & more\n\n[x](https://exa mple.com)\n");

        using var doc = Open(data);
        var text = doc.MainDocumentPart!.Document!.Body!.InnerText;
        Assert.Contains("Control � char", text);
        Assert.Contains("<b>markup</b> & more", text);
    }

    [Fact]
    public void EmptyAndTitleOnlyDocumentsAreValid()
    {
        using var empty = Open(Docx(""));
        Assert.Empty(new OpenXmlValidator().Validate(empty));
    }

    [Fact]
    public void NestedListsAndFootnotesIndent()
    {
        using var doc = Open(Docx("- a\n  - b\n\nNote[^n]\n\n[^n]: Body\n"));
        var paragraphs = doc.MainDocumentPart!.Document!.Body!.Descendants<Paragraph>().ToList();

        var nested = paragraphs.Single(p => p.InnerText == "• b");
        Assert.Equal("720", nested.ParagraphProperties!.Indentation!.Left!.Value);
        Assert.Contains(paragraphs, p => p.InnerText == "[n] Body");
        Assert.Contains(paragraphs, p => p.InnerText == "Note[n]");
    }
}
