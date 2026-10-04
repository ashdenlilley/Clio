using System.Text.Json;

namespace Clio.Export.Tests;

/// <summary>Locates the shared cross-platform spec (repo-root /spec).</summary>
internal static class SpecVectors
{
    public static string RepoRoot { get; } = FindRepoRoot();

    private static string FindRepoRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (Directory.Exists(Path.Combine(dir.FullName, "spec", "vectors"))) return dir.FullName;
        throw new DirectoryNotFoundException("spec/vectors not found above " + AppContext.BaseDirectory);
    }

    public static JsonElement Load(string name) =>
        JsonDocument.Parse(File.ReadAllText(Path.Combine(RepoRoot, "spec", "vectors", name))).RootElement;
}

internal sealed class TempDirectory : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "clio-export-" + Guid.NewGuid().ToString("N"));

    public TempDirectory() => Directory.CreateDirectory(Path);

    public string File(string name) => System.IO.Path.Combine(Path, name);

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
