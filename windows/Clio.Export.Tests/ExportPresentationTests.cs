using Xunit;

namespace Clio.Export.Tests;

public class ExportPresentationTests
{
    [Fact]
    public void EveryOfferedPaperAndMarginLeavesAPrintableArea()
    {
        var fallback = PdfPrintSettings.RegionalDefault("DE");
        foreach (var paper in PageSetupChoices.Papers)
        foreach (var margin in PageSetupChoices.Margins)
        foreach (var orientation in Enum.GetValues<PaperOrientation>())
        {
            var settings = PageSetupChoices.With(fallback, paper, margin, orientation);
            Assert.True(settings.IsValid, $"{paper.Name} {margin.Name} {orientation}");
            var geometry = PdfPrintGeometry.Resolve(settings, fallback);
            Assert.True(geometry.ContentWidth > 100 && geometry.ContentHeight > 100);
        }
    }

    [Fact]
    public void ChoicesAreRecognisedFromSettings()
    {
        var letter = PdfPrintSettings.RegionalDefault("US");
        Assert.Equal("Letter", PageSetupChoices.PaperFor(letter)?.Name);
        Assert.Equal("Normal", PageSetupChoices.MarginFor(letter)?.Name);
        var a4 = PdfPrintSettings.RegionalDefault("GB");
        Assert.Equal("A4", PageSetupChoices.PaperFor(a4)?.Name);
        // Landscape stores portrait-normalised paper, so recognition ignores orientation.
        Assert.Equal("A4", PageSetupChoices.PaperFor(a4 with { Orientation = PaperOrientation.Landscape })?.Name);
        Assert.Null(PageSetupChoices.MarginFor(a4 with { Margins = new PrintMargins(54, 36, 54, 54) }));
        Assert.Null(PageSetupChoices.PaperFor(a4 with { PaperWidthPoints = 500, PaperHeightPoints = 700 }));
    }

    [Fact]
    public void SummaryNamesPaperOrientationAndMargins()
    {
        Assert.Equal("A4 · Portrait · Normal", PageSetupChoices.Summary(PdfPrintSettings.RegionalDefault("GB")));
        var wide = PageSetupChoices.With(PdfPrintSettings.RegionalDefault("US"), margin: PageSetupChoices.Margins[2], orientation: PaperOrientation.Landscape);
        Assert.Equal("Letter · Landscape · Wide", PageSetupChoices.Summary(wide));
        Assert.EndsWith("Custom margins", PageSetupChoices.Summary(wide with { Margins = new PrintMargins(1, 2, 3, 4) }));
    }

    [Fact]
    public void WithChangesOnlyWhatWasAsked()
    {
        var start = PdfPrintSettings.RegionalDefault("GB");
        Assert.Equal(start with { Orientation = PaperOrientation.Landscape }, PageSetupChoices.With(start, orientation: PaperOrientation.Landscape));
        Assert.Equal(start, PageSetupChoices.With(start));
    }

    [Fact]
    public void StoredSettingsAreUsedOnlyWhenTheyLeaveAPrintableArea()
    {
        var good = PageSetupChoices.With(PdfPrintSettings.RegionalDefault("GB"), PageSetupChoices.Papers[1]);
        Assert.Equal(good, PageSetupChoices.Validated(good, "GB"));
        Assert.Equal(PdfPrintSettings.RegionalDefault("GB"), PageSetupChoices.Validated(null, "GB"));
        var broken = good with { Margins = new PrintMargins(1000, 1000, 1000, 1000) };
        Assert.Equal(PdfPrintSettings.RegionalDefault("GB"), PageSetupChoices.Validated(broken, "GB"));
        var nan = good with { Margins = new PrintMargins(double.NaN, 54, 54, 54) };
        Assert.Equal(PdfPrintSettings.RegionalDefault("US"), PageSetupChoices.Validated(nan, "US"));
    }

    [Fact]
    public void SettingsRoundTripThroughJson()
    {
        var settings = PageSetupChoices.With(PdfPrintSettings.RegionalDefault("GB"), PageSetupChoices.Papers[2], PageSetupChoices.Margins[0], PaperOrientation.Landscape);
        var json = System.Text.Json.JsonSerializer.Serialize(settings);
        Assert.Equal(settings, System.Text.Json.JsonSerializer.Deserialize<PdfPrintSettings>(json));
    }

    [Theory]
    [InlineData(unchecked((int)0x80070070), "Not enough disk space")]
    [InlineData(unchecked((int)0x80070027), "Not enough disk space")]
    [InlineData(unchecked((int)0x80070020), "Destination is in use")]
    [InlineData(unchecked((int)0x80070021), "Destination is in use")]
    [InlineData(unchecked((int)0x80070005), "Destination is not writable")]
    [InlineData(unchecked((int)0x80070013), "Destination is not writable")]
    [InlineData(unchecked((int)0x80070003), "Destination is unavailable")]
    [InlineData(unchecked((int)0x80070015), "Destination is unavailable")]
    [InlineData(unchecked((int)0x80004005), "Export failed")]
    public void IoFailuresAreClassifiedByWin32Cause(int hresult, string title)
    {
        var error = new IOException("Something low level said this", hresult);
        var failure = ExportFailureMapper.Failure(error);
        Assert.Equal(title, failure.Title);
        Assert.True(failure.CanRetry);
        if (title != "Export failed") Assert.DoesNotContain("low level", failure.Message);
    }

    [Fact]
    public void TheCauseIsFoundThroughInnerExceptions()
    {
        var inner = new IOException("disk", unchecked((int)0x80070070));
        Assert.Equal("Not enough disk space", ExportFailureMapper.Failure(new InvalidOperationException("wrapped", inner)).Title);
        Assert.Equal("Destination is not writable", ExportFailureMapper.Failure(new UnauthorizedAccessException()).Title);
        Assert.Equal("Destination is unavailable", ExportFailureMapper.Failure(new DirectoryNotFoundException()).Title);
    }

    [Fact]
    public void OtherFailuresKeepTheirOwnMessageAndCancellationIsNotRetryable()
    {
        var failure = ExportFailureMapper.Failure(new InvalidPrintSettingsException());
        Assert.Equal("Export failed", failure.Title);
        Assert.Equal(new InvalidPrintSettingsException().Message, failure.Message);
        Assert.False(ExportFailureMapper.Failure(new OperationCanceledException()).CanRetry);
    }

    [Fact]
    public void ExportCommandArgumentsRoute()
    {
        Assert.Null(ExportCommandRoute.Format([]));
        Assert.Equal(ExportFormat.Docx, ExportCommandRoute.Format(["DOCX"]));
        Assert.Equal(ExportFormat.Pdf, ExportCommandRoute.Format(["pdf"]));
        var tooMany = Assert.Throws<ArgumentException>(() => ExportCommandRoute.Format(["pdf", "html"]));
        Assert.Contains("pdf, html, docx or txt", tooMany.Message);
        Assert.Throws<ArgumentException>(() => ExportCommandRoute.Format(["rtf"]));
    }

    [Fact]
    public void FormatsHaveNamesDescriptionsAndFileTypes()
    {
        foreach (var format in Enum.GetValues<ExportFormat>())
        {
            Assert.NotEmpty(ExportCommandRoute.DisplayName(format));
            Assert.NotEmpty(ExportCommandRoute.Description(format));
            Assert.NotEmpty(ExportCommandRoute.StatusText(format));
            Assert.Equal(DocumentExporter.Extension(format), ExportCommandRoute.FileType(format).Extension);
            Assert.True(ExportCommandRoute.TryParse(ExportCommandRoute.RawValue(format), out var roundTrip));
            Assert.Equal(format, roundTrip);
        }
    }
}
