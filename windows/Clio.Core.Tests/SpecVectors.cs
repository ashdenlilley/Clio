using System.Text.Json;

namespace Clio.Core.Tests;

/// <summary>Locates the shared cross-platform spec (repo-root /spec) and the shared Markdown fixtures.</summary>
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

    public static byte[] Hex(string hex) => Convert.FromHexString(hex);
}
