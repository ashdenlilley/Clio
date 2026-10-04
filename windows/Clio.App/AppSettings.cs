using System.Text.Json;

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
