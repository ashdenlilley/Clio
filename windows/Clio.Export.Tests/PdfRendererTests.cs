using System.Text;
using UglyToad.PdfPig;
using Xunit;

namespace Clio.Export.Tests;

public class PdfRendererTests
{
    private static readonly PdfPrintSettings Letter = new("na-letter", 612, 792, new PrintMargins(54, 54, 54, 54), PaperOrientation.Portrait);

    private static byte[] Pdf(string markdown, PdfPrintSettings? settings = null, string title = "Notes.md") =>
        DocumentExporter.Render(ExportFormat.Pdf, markdown, title, settings ?? Letter);

    private static string PageText(PdfDocument document, int page) =>
        string.Join(" ", document.GetPage(page).GetWords().Select(w => w.Text));

    [Fact]
    public void ProducesExtractableTextWithRequestedPaper()
    {
        var data = Pdf("# Notes\n\nA paragraph with **bold** text.\n\n- first\n- second\n");

        Assert.Equal("%PDF", Encoding.ASCII.GetString(data, 0, 4));
        using var document = PdfDocument.Open(data);
        var page = document.GetPage(1);
        Assert.Equal(612, page.Width, 1);
        Assert.Equal(792, page.Height, 1);
        var text = PageText(document, 1);
        Assert.Contains("Notes", text);
        Assert.Contains("paragraph", text);
        Assert.Contains("bold", text);
        Assert.Contains("first", text);
        Assert.DoesNotContain("**", text);
    }

    [Fact]
    public void EveryPageCarriesTitleHeaderAndPageNumber()
    {
        var markdown = string.Join("\n\n", Enumerable.Range(1, 120).Select(i => $"Paragraph number {i} with enough words to occupy a line of the page."));
        using var document = PdfDocument.Open(Pdf(markdown, title: "Long document.md"));

        Assert.True(document.NumberOfPages >= 3, $"pages: {document.NumberOfPages}");
        for (var page = 1; page <= document.NumberOfPages; page++)
        {
            var text = PageText(document, page);
            Assert.Contains("Long document.md", text);
            Assert.EndsWith(page.ToString(), text);
        }
        Assert.Contains("Paragraph number 1 ", PageText(document, 1));
        Assert.Contains("Paragraph number 120", PageText(document, document.NumberOfPages));
    }

    [Fact]
    public void LandscapeSwapsPageDimensions()
    {
        using var document = PdfDocument.Open(Pdf("Hello", Letter with { Orientation = PaperOrientation.Landscape }));

        Assert.Equal(792, document.GetPage(1).Width, 1);
        Assert.Equal(612, document.GetPage(1).Height, 1);
    }

    [Fact]
    public void UnprintablePageIsRejected()
    {
        var tooWide = Letter with { Margins = new PrintMargins(54, 300, 54, 300) };

        Assert.Throws<InvalidPrintSettingsException>(() => Pdf("Hello", tooWide));
    }

    [Fact]
    public void DefaultsToTheRegionalPaperWhenNoSettingsAreGiven()
    {
        var data = DocumentExporter.Render(ExportFormat.Pdf, "Hello", "t");
        var expected = PdfPrintSettings.RegionalDefault();

        using var document = PdfDocument.Open(data);
        Assert.Equal(expected.PaperWidthPoints!.Value, document.GetPage(1).Width, 0);
        Assert.Equal(expected.PaperHeightPoints!.Value, document.GetPage(1).Height, 0);
    }

    [Fact]
    public void TablesKeepColumnsAndWrapLongCells()
    {
        var longCell = string.Join(" ", Enumerable.Repeat("wrapping", 40));
        using var document = PdfDocument.Open(Pdf($"| Name | Value |\n| --- | ---: |\n| alpha | 1 |\n| beta | {longCell} |\n"));
        var words = document.GetPage(1).GetWords().ToList();

        var name = words.Single(w => w.Text == "Name");
        var alpha = words.Single(w => w.Text == "alpha");
        var beta = words.Single(w => w.Text == "beta");
        Assert.Equal(name.BoundingBox.Left, alpha.BoundingBox.Left, 1);
        Assert.Equal(alpha.BoundingBox.Left, beta.BoundingBox.Left, 1);
        Assert.True(name.BoundingBox.Bottom > alpha.BoundingBox.Bottom, "header sits above the first row");
        Assert.True(words.Count(w => w.Text == "wrapping") == 40);
        var wrapped = words.Where(w => w.Text == "wrapping").Select(w => Math.Round(w.BoundingBox.Bottom)).Distinct().Count();
        Assert.True(wrapped > 1, "a long cell wraps onto several lines");
    }

    [Fact]
    public void LinksOnlySurviveWhenSafe()
    {
        using var document = PdfDocument.Open(Pdf("[Example](https://example.com) and [bad](javascript:alert(1))\n"));
        var page = document.GetPage(1);
        var annotationUris = page.GetHyperlinks().Select(h => h.Uri).ToList();

        Assert.Equal(["https://example.com"], annotationUris.Select(u => u!.TrimEnd('/')).ToList());
        var text = PageText(document, 1);
        Assert.Contains("(https://example.com)", text);
        Assert.DoesNotContain("javascript", text);
        Assert.Contains("bad", text);
    }

    [Fact]
    public void ImagesBecomeAltText()
    {
        using var document = PdfDocument.Open(Pdf("![a diagram](http://example.com/x.png)\n"));

        Assert.Contains("[Image: a diagram]", string.Join(" ", document.GetPage(1).GetWords().Select(w => w.Text)));
    }

    [Fact]
    public void EmptyDocumentStillMakesOnePage()
    {
        using var document = PdfDocument.Open(Pdf(""));

        Assert.Equal(1, document.NumberOfPages);
    }

    [Fact]
    public void LongTitleIsTruncatedInTheHeader()
    {
        var title = new string('x', 400) + ".md";
        using var document = PdfDocument.Open(Pdf("body", title: title));

        var header = document.GetPage(1).GetWords().First(w => w.Text.StartsWith("xxx"));
        Assert.EndsWith("...", header.Text);
        Assert.True(header.BoundingBox.Right < 612 - 54 + 1, "title stays inside the margins");
    }

    [Fact]
    public void NestedStructureAndCodeAreRendered()
    {
        using var document = PdfDocument.Open(Pdf("> quoted line\n\n1. one\n   - nested\n\n```csharp\nvar x = 1;\n```\n\n---\n\nend\n"));
        var text = PageText(document, 1);

        Assert.Contains("quoted line", text);
        Assert.Contains("nested", text);
        Assert.Contains("csharp", text);
        Assert.Contains("var x = 1;", string.Join(" ", document.GetPage(1).GetWords().Select(w => w.Text)).Replace("  ", " "));
        Assert.Contains("end", text);
    }

    [Fact]
    public void CancellationStopsBeforeRendering()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        Assert.Throws<OperationCanceledException>(() => DocumentExporter.Render(ExportFormat.Pdf, "x", "t", Letter, cts.Token));
    }
}
