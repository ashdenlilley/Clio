using System.Text.Json;
using Xunit;

namespace Clio.Export.Tests;

public class ExportPolicyVectorTests
{
    private static readonly JsonElement Vectors = SpecVectors.Load("export-policy.json");

    private static string? NullableString(JsonElement e) => e.ValueKind == JsonValueKind.Null ? null : e.GetString();

    [Fact]
    public void SafeLinkMatchesVectors()
    {
        foreach (var c in Vectors.GetProperty("safeLink").EnumerateArray())
        {
            var input = c.GetProperty("input").GetString()!;
            Assert.True(NullableString(c.GetProperty("output")) == ExportContentPolicy.SafeLink(input), $"safeLink({input})");
        }
    }

    [Fact]
    public void EscapeHtmlMatchesVectors()
    {
        foreach (var c in Vectors.GetProperty("escapeHtml").EnumerateArray())
            Assert.Equal(c.GetProperty("output").GetString(), ExportContentPolicy.EscapeHtml(c.GetProperty("input").GetString()!));
    }

    [Fact]
    public void FootnoteIdsMatchVectors()
    {
        foreach (var c in Vectors.GetProperty("footnoteId").EnumerateArray())
            Assert.Equal(c.GetProperty("id").GetString(), ExportContentPolicy.SafeFootnoteId(c.GetProperty("label").GetString()!));
    }

    [Fact]
    public void RegionalDefaultsMatchVectors()
    {
        foreach (var c in Vectors.GetProperty("regionalDefault").EnumerateArray())
        {
            var settings = PdfPrintSettings.RegionalDefault(NullableString(c.GetProperty("region")) ?? "ZZ");
            Assert.Equal(c.GetProperty("paper").GetString(), settings.PaperName);
            Assert.Equal(c.GetProperty("width").GetDouble(), settings.PaperWidthPoints!.Value, 4);
            Assert.Equal(c.GetProperty("height").GetDouble(), settings.PaperHeightPoints!.Value, 4);
            Assert.Equal(new PrintMargins(54, 54, 54, 54), settings.Margins);
            Assert.True(settings.IsValid);
        }
    }

    [Fact]
    public void PrintGeometryMatchesVectors()
    {
        var geometry = Vectors.GetProperty("printGeometry");
        var fallback = PdfPrintSettings.RegionalDefault(geometry.GetProperty("fallbackRegion").GetString());
        Assert.Equal(PdfPrintGeometry.HeaderHeight, geometry.GetProperty("headerHeight").GetDouble());
        Assert.Equal(PdfPrintGeometry.FooterHeight, geometry.GetProperty("footerHeight").GetDouble());

        foreach (var c in geometry.GetProperty("cases").EnumerateArray())
        {
            var name = c.GetProperty("name").GetString();
            var s = c.GetProperty("settings");
            double? Number(string key) => s.GetProperty(key).ValueKind == JsonValueKind.Null ? null : s.GetProperty(key).GetDouble();
            var m = s.GetProperty("margins").EnumerateArray().Select(x => x.GetDouble()).ToArray();
            var settings = new PdfPrintSettings(null, Number("width"), Number("height"), new PrintMargins(m[0], m[1], m[2], m[3]),
                s.GetProperty("orientation").GetString() == "landscape" ? PaperOrientation.Landscape : PaperOrientation.Portrait);

            if (!c.GetProperty("valid").GetBoolean())
            {
                Assert.Throws<InvalidPrintSettingsException>(() => PdfPrintGeometry.Resolve(settings, fallback));
                continue;
            }
            var resolved = PdfPrintGeometry.Resolve(settings, fallback);
            Assert.True(Math.Abs(c.GetProperty("pageWidth").GetDouble() - resolved.PageWidth) < 1e-6, name);
            Assert.True(Math.Abs(c.GetProperty("pageHeight").GetDouble() - resolved.PageHeight) < 1e-6, name);
            Assert.True(Math.Abs(c.GetProperty("contentWidth").GetDouble() - resolved.ContentWidth) < 1e-6, name);
            Assert.True(Math.Abs(c.GetProperty("contentHeight").GetDouble() - resolved.ContentHeight) < 1e-6, name);
        }
    }

    [Fact]
    public void PlainTextMatchesVectors()
    {
        foreach (var c in Vectors.GetProperty("plainText").EnumerateArray())
        {
            var document = MarkdownModelBuilder.Build(c.GetProperty("markdown").GetString()!);
            Assert.True(c.GetProperty("text").GetString() == PlainTextRenderer.Render(document), c.GetProperty("name").GetString());
        }
    }
}
