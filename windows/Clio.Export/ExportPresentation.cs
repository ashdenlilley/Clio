
namespace Clio.Export;

/// <summary>A paper size the page-setup control offers. Dimensions are portrait points (1/72 in).</summary>
public sealed record PaperSize(string Id, string Name, double WidthPoints, double HeightPoints);

/// <summary>A margin choice. <see cref="Points"/> applies to all four sides.</summary>
public sealed record MarginPreset(string Id, string Name, double Points);

/// <summary>
/// The page setup choices Clio offers for PDF export. macOS shows the system Page Layout panel; WinUI has no
/// equivalent, so Windows offers a short list of common papers and margins instead. Anything stored in settings that
/// is not on these lists (a custom size from macOS-style defaults) is kept and shown as "Custom".
/// </summary>
public static class PageSetupChoices
{
    public static IReadOnlyList<PaperSize> Papers { get; } =
    [
        new("iso-a4", "A4", 595.2756, 841.8898),
        new("na-letter", "Letter", 612, 792),
        new("na-legal", "Legal", 612, 1008),
        new("iso-a3", "A3", 841.8898, 1190.5512),
        new("iso-a5", "A5", 419.5276, 595.2756),
    ];

    public static IReadOnlyList<MarginPreset> Margins { get; } =
    [
        new("narrow", "Narrow", 36),
        new("normal", "Normal", 54),
        new("wide", "Wide", 72),
    ];

    private const double Tolerance = 0.5;

    public static PaperSize? PaperFor(PdfPrintSettings settings) =>
        settings.PaperWidthPoints is { } w && settings.PaperHeightPoints is { } h
            ? Papers.FirstOrDefault(p => Math.Abs(p.WidthPoints - Math.Min(w, h)) < Tolerance && Math.Abs(p.HeightPoints - Math.Max(w, h)) < Tolerance)
            : null;

    /// <summary>The preset when all four margins are equal and match one; otherwise null (custom).</summary>
    public static MarginPreset? MarginFor(PdfPrintSettings settings)
    {
        var m = settings.Margins;
        if (Math.Abs(m.Top - m.Leading) > 0.01 || Math.Abs(m.Top - m.Bottom) > 0.01 || Math.Abs(m.Top - m.Trailing) > 0.01) return null;
        return Margins.FirstOrDefault(p => Math.Abs(p.Points - m.Top) < 0.01);
    }

    public static PdfPrintSettings With(PdfPrintSettings current, PaperSize? paper = null, MarginPreset? margin = null, PaperOrientation? orientation = null)
    {
        var next = current;
        if (paper is not null) next = next with { PaperName = paper.Id, PaperWidthPoints = paper.WidthPoints, PaperHeightPoints = paper.HeightPoints };
        if (margin is not null) next = next with { Margins = new PrintMargins(margin.Points, margin.Points, margin.Points, margin.Points) };
        if (orientation is { } o) next = next with { Orientation = o };
        return next;
    }

    /// <summary>"A4 · Portrait" style summary, like the macOS options sheet.</summary>
    public static string Summary(PdfPrintSettings settings)
    {
        var name = PaperFor(settings)?.Name ?? settings.PaperName ?? "Custom";
        var margin = MarginFor(settings)?.Name ?? "Custom margins";
        return $"{name} · {(settings.Orientation == PaperOrientation.Portrait ? "Portrait" : "Landscape")} · {margin}";
    }

    /// <summary>
    /// Settings read back from disk are used only when they leave a printable area; anything else falls back to the
    /// regional default so a damaged settings file can never break export.
    /// </summary>
    public static PdfPrintSettings Validated(PdfPrintSettings? stored, string? regionCode = null)
    {
        var fallback = PdfPrintSettings.RegionalDefault(regionCode);
        if (stored is null) return fallback;
        try
        {
            PdfPrintGeometry.Resolve(stored, fallback);
            return stored;
        }
        catch (InvalidPrintSettingsException) { return fallback; }
    }
}

/// <summary>What the user is told when an export fails.</summary>
public sealed record ExportFailure(string Title, string Message, bool CanRetry);

/// <summary>Windows port of macOS <c>ExportFailureMapper</c>: classifies the failure by its Win32 cause, not by message text.</summary>
public static class ExportFailureMapper
{
    private const int ErrorSharingViolation = 0x20;
    private const int ErrorLockViolation = 0x21;
    private const int ErrorHandleDiskFull = 0x27;
    private const int ErrorDiskFull = 0x70;
    private const int ErrorFileNotFound = 0x2;
    private const int ErrorPathNotFound = 0x3;
    private const int ErrorAccessDenied = 0x5;
    private const int ErrorWriteProtect = 0x13;
    private const int ErrorNotReady = 0x15;
    private const int ErrorBadNetPath = 0x35;

    public static ExportFailure Failure(Exception error)
    {
        var chain = Chain(error).ToList();
        if (chain.Any(IsOutOfSpace))
            return new("Not enough disk space", "Clio left the existing file untouched. Free space on the destination drive, then retry.", true);
        if (chain.Any(IsInUse))
            return new("Destination is in use", "Another program has that file open. Clio left it untouched. Close it, then retry.", true);
        if (chain.Any(IsPermission))
            return new("Destination is not writable", "Clio left the existing file untouched. Restore folder access or choose another destination, then retry.", true);
        if (chain.Any(IsMissing))
            return new("Destination is unavailable", "Clio left the existing file untouched. Reconnect the drive or restore folder access, then retry.", true);
        return new("Export failed", error.Message, error is not OperationCanceledException);
    }

    private static IEnumerable<Exception> Chain(Exception error)
    {
        for (Exception? cursor = error; cursor is not null; cursor = cursor.InnerException)
            yield return cursor;
    }

    private static int Win32(Exception e) => e.HResult & 0xFFFF;

    private static bool IsWin32(Exception e) => (e.HResult & unchecked((int)0xFFFF0000)) == unchecked((int)0x80070000);

    private static bool IsOutOfSpace(Exception e) => IsWin32(e) && Win32(e) is ErrorDiskFull or ErrorHandleDiskFull;

    private static bool IsInUse(Exception e) => e is IOException && IsWin32(e) && Win32(e) is ErrorSharingViolation or ErrorLockViolation;

    private static bool IsPermission(Exception e) =>
        e is UnauthorizedAccessException || (IsWin32(e) && Win32(e) is ErrorAccessDenied or ErrorWriteProtect);

    private static bool IsMissing(Exception e) =>
        e is DirectoryNotFoundException or DriveNotFoundException or FileNotFoundException
        || (IsWin32(e) && Win32(e) is ErrorFileNotFound or ErrorPathNotFound or ErrorNotReady or ErrorBadNetPath);
}

/// <summary>How the app routes <c>/export</c> arguments (macOS <c>ExportCommandRoute</c>).</summary>
public static class ExportCommandRoute
{
    /// <summary>Null means "ask": no argument opens the options dialog.</summary>
    /// <exception cref="ArgumentException">More than one argument, or a format Clio does not export.</exception>
    public static ExportFormat? Format(IReadOnlyList<string> arguments)
    {
        if (arguments.Count == 0) return null;
        if (arguments.Count == 1 && TryParse(arguments[0], out var format)) return format;
        throw new ArgumentException($"Unknown export format “{string.Join(' ', arguments)}”. Use /export with pdf, html, docx or txt.");
    }

    public static bool TryParse(string raw, out ExportFormat format)
    {
        switch (raw.ToLowerInvariant())
        {
            case "pdf": format = ExportFormat.Pdf; return true;
            case "html": format = ExportFormat.Html; return true;
            case "docx": format = ExportFormat.Docx; return true;
            case "txt": format = ExportFormat.Txt; return true;
            default: format = default; return false;
        }
    }

    public static string RawValue(ExportFormat format) => format.ToString().ToLowerInvariant();

    /// <summary>One line under the format choice, as in the macOS options sheet.</summary>
    public static string Description(ExportFormat format) => format switch
    {
        ExportFormat.Txt => "UTF-8 text without Markdown formatting markers; tables use tabs and links retain destinations.",
        ExportFormat.Docx => "Editable Word formatting. Images use descriptions; raw HTML is preserved as literal text.",
        ExportFormat.Pdf => "PDF uses black text on white paper.",
        _ => "HTML uses a white reading surface and print stylesheet.",
    };

    public static string DisplayName(ExportFormat format) => format switch
    {
        ExportFormat.Pdf => "PDF",
        ExportFormat.Html => "HTML",
        ExportFormat.Docx => "Word (.docx)",
        _ => "Plain Text (.txt)",
    };

    public static string StatusText(ExportFormat format) => format switch
    {
        ExportFormat.Pdf => "Laying out PDF pages…",
        ExportFormat.Html => "Rendering HTML…",
        ExportFormat.Docx => "Creating Word document…",
        _ => "Creating plain text…",
    };

    /// <summary>The file picker label and extension filter for a format.</summary>
    public static (string Label, string Extension) FileType(ExportFormat format) => format switch
    {
        ExportFormat.Pdf => ("PDF document", ".pdf"),
        ExportFormat.Html => ("HTML page", ".html"),
        ExportFormat.Docx => ("Word document", ".docx"),
        _ => ("Plain text", ".txt"),
    };

}
