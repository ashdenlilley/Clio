using System.Text.Json;
using Clio.Export;
using Clio.Intelligence;

namespace Clio.App;

public sealed record WorkspaceRecord(Guid Id, string Root);

/// <summary>User settings persisted as JSON under %LOCALAPPDATA%\Clio. Unreadable files fall back to defaults.</summary>
public sealed class AppSettings
{
    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Clio", "settings.json");

    public List<WorkspaceRecord> Workspaces { get; set; } = [];

    /// <summary>Also track and search <c>.txt</c> documents (the scanner's text-file policy).</summary>
    public bool IncludeTextFiles { get; set; }

    /// <summary>
    /// Assisted commands (TypeSafe). Off on a fresh install and after an upgrade, so an update never starts making
    /// network requests. Preferences only: the API key lives in Windows Credential Manager, never in this file.
    /// </summary>
    public bool AssistedCommandsEnabled { get; set; }

    /// <summary>Whether a long plain-text paste may be offered as formatted Markdown. Only ever runs behind <see cref="AssistedCommandsEnabled"/>.</summary>
    public bool FormatPastes { get; set; } = true;

    /// <summary>Paper and margins for PDF export. Null means the regional default; invalid values are ignored on read.</summary>
    public PdfPrintSettings? PdfPrint { get; set; }

    /// <summary>The format the export dialog opens on, as its slash name (<c>pdf</c>, <c>html</c>, <c>docx</c>, <c>txt</c>).</summary>
    public string LastExportFormat { get; set; } = "pdf";

    public static AppSettings Load(string? path = null)
    {
        try { return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path ?? DefaultPath)) ?? new(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return new(); }
    }

    public void Save(string? path = null)
    {
        path ??= DefaultPath;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temp = path + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temp, path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// <summary>Persists the two assisted-command switches through <see cref="AppSettings"/> as they change.</summary>
public sealed class PersistedIntelligenceSettings(AppSettings settings) : IIntelligenceSettings
{
    public bool Enabled
    {
        get => settings.AssistedCommandsEnabled;
        set { settings.AssistedCommandsEnabled = value; settings.Save(); }
    }

    public bool FormatPastes
    {
        get => settings.FormatPastes;
        set { settings.FormatPastes = value; settings.Save(); }
    }
}

/// <summary>
/// PDF page setup, kept valid at all times (macOS <c>PDFPrintSettingsStore</c>): a stored value that leaves no
/// printable area is replaced by the regional default instead of breaking export.
/// </summary>
public sealed class PdfPrintSettingsStore(AppSettings settings)
{
    public PdfPrintSettings Current => PageSetupChoices.Validated(settings.PdfPrint);

    /// <exception cref="InvalidPrintSettingsException">The settings leave no printable area.</exception>
    public void Update(PdfPrintSettings next)
    {
        PdfPrintGeometry.Resolve(next, PdfPrintSettings.RegionalDefault());
        settings.PdfPrint = next;
        settings.Save();
    }

    public void ResetToRegionalDefault()
    {
        settings.PdfPrint = null;
        settings.Save();
    }
}
