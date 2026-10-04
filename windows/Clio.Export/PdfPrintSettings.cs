using System.Globalization;

namespace Clio.Export;

public enum PaperOrientation { Portrait, Landscape }

/// <summary>Margins in points (1/72 in).</summary>
public sealed record PrintMargins(double Top, double Leading, double Bottom, double Trailing);

/// <summary>
/// Paper and margins for PDF export. Paper dimensions are stored portrait-normalised; orientation is applied when the
/// geometry is resolved. Serialises with System.Text.Json for the app's settings store.
/// </summary>
public sealed record PdfPrintSettings(
    string? PaperName,
    double? PaperWidthPoints,
    double? PaperHeightPoints,
    PrintMargins Margins,
    PaperOrientation Orientation)
{
    public bool IsValid
    {
        get
        {
            double[] margins = [Margins.Top, Margins.Leading, Margins.Bottom, Margins.Trailing];
            if (!margins.All(m => double.IsFinite(m) && m >= 0)) return false;
            if (PaperWidthPoints is null && PaperHeightPoints is null) return true;
            if (PaperWidthPoints is not { } w || PaperHeightPoints is not { } h) return false;
            if (!double.IsFinite(w) || !double.IsFinite(h) || w <= 0 || h <= 0) return false;
            var (width, height) = Oriented(w, h, Orientation);
            return width - Margins.Leading - Margins.Trailing > 0 && height - Margins.Top - Margins.Bottom > 0;
        }
    }

    internal static (double Width, double Height) Oriented(double w, double h, PaperOrientation orientation)
    {
        var portraitWidth = Math.Min(w, h);
        var portraitHeight = Math.Max(w, h);
        return orientation == PaperOrientation.Portrait ? (portraitWidth, portraitHeight) : (portraitHeight, portraitWidth);
    }

    private static readonly HashSet<string> LetterRegions = ["CA", "CL", "CO", "CR", "GT", "MX", "PA", "PH", "US", "VE"];

    /// <summary>US Letter in Letter regions, A4 elsewhere, 54 pt margins, portrait. Same table as macOS.</summary>
    public static PdfPrintSettings RegionalDefault(string? regionCode = null)
    {
        regionCode ??= RegionOrNull();
        var letter = regionCode is not null && LetterRegions.Contains(regionCode.ToUpperInvariant());
        return new PdfPrintSettings(
            letter ? "na-letter" : "iso-a4",
            letter ? 612 : 595.2756,
            letter ? 792 : 841.8898,
            new PrintMargins(54, 54, 54, 54),
            PaperOrientation.Portrait);
    }

    private static string? RegionOrNull()
    {
        try { return new RegionInfo(CultureInfo.CurrentCulture.Name).TwoLetterISORegionName; }
        catch (ArgumentException) { return null; }
    }
}

/// <summary>Page size and printable area (points, origin top-left) after header and footer bands are reserved.</summary>
public sealed record PdfPrintGeometry(double PageWidth, double PageHeight, double ContentX, double ContentY, double ContentWidth, double ContentHeight)
{
    public const double HeaderHeight = 22;
    public const double FooterHeight = 20;
    public const double MinimumContentWidth = 72;
    public const double MinimumContentHeight = 18;

    /// <exception cref="InvalidPrintSettingsException">The settings leave no printable area.</exception>
    public static PdfPrintGeometry Resolve(PdfPrintSettings settings, PdfPrintSettings fallback)
    {
        if (!settings.IsValid || !fallback.IsValid
            || (settings.PaperWidthPoints ?? fallback.PaperWidthPoints) is not { } sourceWidth
            || (settings.PaperHeightPoints ?? fallback.PaperHeightPoints) is not { } sourceHeight
            || !double.IsFinite(sourceWidth) || !double.IsFinite(sourceHeight))
            throw new InvalidPrintSettingsException();

        var (width, height) = PdfPrintSettings.Oriented(sourceWidth, sourceHeight, settings.Orientation);
        var m = settings.Margins;
        var contentWidth = width - m.Leading - m.Trailing;
        var contentHeight = height - m.Top - m.Bottom - HeaderHeight - FooterHeight;
        if (!double.IsFinite(contentWidth) || !double.IsFinite(contentHeight)
            || contentWidth < MinimumContentWidth || contentHeight < MinimumContentHeight)
            throw new InvalidPrintSettingsException();
        return new PdfPrintGeometry(width, height, m.Leading, m.Top + HeaderHeight, contentWidth, contentHeight);
    }
}
