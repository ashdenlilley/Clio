using Xunit;

namespace Clio.Core.Tests;

public sealed class FileNamesTests
{
    [Fact]
    public void SafeNamesMatchSharedVectors()
    {
        var root = SpecVectors.Load("file-names.json");
        Assert.Equal(FileNames.DefaultName, root.GetProperty("defaultName").GetString());
        foreach (var group in new[] { "all", "windows" })
            foreach (var v in root.GetProperty(group).EnumerateArray())
                Assert.Equal(v.GetProperty("safe").GetString(), FileNames.Safe(v.GetProperty("input").GetString()!));
    }

    [Fact]
    public void LongNamesAreCappedAndKeepTheExtension()
    {
        var spec = SpecVectors.Load("file-names.json");
        var long_ = spec.GetProperty("windowsLongName");
        var ext = long_.GetProperty("extension").GetString()!;
        var safe = FileNames.Safe(new string('a', long_.GetProperty("stemLength").GetInt32()) + ext);
        Assert.Equal(long_.GetProperty("expectedLength").GetInt32(), safe.Length);
        Assert.Equal(FileNames.MaximumLength, spec.GetProperty("windowsMaximumLength").GetInt32());
        Assert.EndsWith(ext, safe);
    }

    [Fact]
    public void TruncationNeverSplitsASurrogatePair()
    {
        // 254 BMP letters then an emoji (2 units) would straddle the 253-unit stem budget.
        var safe = FileNames.Safe(new string('a', 252) + "\U0001F600\U0001F600.md");
        Assert.True(safe.Length <= FileNames.MaximumLength);
        Assert.False(char.IsHighSurrogate(safe[^4]), "stem must not end on a lone high surrogate");
    }

    [Fact]
    public void SafeNamesAreAcceptedByTheFileSystem()
    {
        using var dir = new TempDir();
        foreach (var input in new[] { "CON", "name.", "what?.md", "NUL.txt", "a:b", "tab\tx", "  lead.md" })
        {
            var path = dir[FileNames.Safe(input)];
            File.WriteAllText(path, "x");
            Assert.True(File.Exists(path), input);
        }
    }

    [Fact]
    public void AvailableMatchesCollisionVectors()
    {
        foreach (var v in SpecVectors.Load("recovery-store.json").GetProperty("collisions").EnumerateArray())
        {
            // Case folding is Windows behaviour; this suite runs on Windows only.
            var existing = v.GetProperty("existing").EnumerateArray().Select(e => e.GetString()!).ToList();
            var taken = new HashSet<string>(existing, StringComparer.OrdinalIgnoreCase);
            Assert.Equal(v.GetProperty("available").GetString(), FileNames.Available(v.GetProperty("name").GetString()!, taken.Contains));
        }
    }

    [Fact]
    public void FoldIgnoresCaseAndSlashDirection() =>
        Assert.Equal(FileNames.Fold("C:\\W\\Notes.md"), FileNames.Fold("c:/w/NOTES.MD"));
}
