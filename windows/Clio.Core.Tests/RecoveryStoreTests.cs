using System.Text;
using Xunit;

namespace Clio.Core.Tests;

public sealed class RecoveryStoreTests
{
    [Fact]
    public void NamesMatchSharedVectors()
    {
        var root = SpecVectors.Load("recovery-store.json");
        Assert.Equal(root.GetProperty("retentionSeconds").GetInt32(), (int)RecoveryStore.Retention.TotalSeconds);
        foreach (var v in root.GetProperty("names").EnumerateArray())
        {
            var stamp = DateTimeOffset.Parse(v.GetProperty("stampUtc").GetString()!, null, System.Globalization.DateTimeStyles.AssumeUniversal);
            Assert.Equal(
                v.GetProperty("recovered").GetString(),
                RecoveryStore.RecoveredName(v.GetProperty("filename").GetString()!, stamp, Guid.Parse(v.GetProperty("documentId").GetString()!)));
        }
    }

    [Fact]
    public void PreserveWritesTheBytesAndNumbersCollisions()
    {
        using var dir = new TempDir();
        var now = DateTimeOffset.Parse("2026-05-06T07:08:09Z");
        var store = new RecoveryStore(dir.Path, () => now);
        var id = Guid.NewGuid();
        var a = store.Preserve(id, "Note.md", "first", now);
        var b = store.Preserve(id, "Note.md", "second", now);
        var c = store.Preserve(id, "note.MD", "third", now);

        Assert.Equal("first", File.ReadAllText(a.RecoveryPath));
        Assert.Equal("second", File.ReadAllText(b.RecoveryPath));
        Assert.Equal("third", File.ReadAllText(c.RecoveryPath));
        Assert.Equal(3, new HashSet<string>(new[] { a, b, c }.Select(r => r.RecoveryPath), StringComparer.OrdinalIgnoreCase).Count);
        Assert.Contains("(2)", Path.GetFileName(b.RecoveryPath));
        Assert.Contains("(3)", Path.GetFileName(c.RecoveryPath));
    }

    [Fact]
    public void PreserveStoresBinaryAndUnicodeBytesExactly()
    {
        using var dir = new TempDir();
        var store = new RecoveryStore(dir.Path);
        byte[] data = [0xEF, 0xBB, 0xBF, 0x00, 0xFF, .. Encoding.UTF8.GetBytes("naïve \U0001F600\r\n")];
        var receipt = store.Preserve(Guid.NewGuid(), "x.md", data);
        Assert.Equal(data, File.ReadAllBytes(receipt.RecoveryPath));
    }

    [Fact]
    public void RetentionBoundaryMatchesSharedVectors()
    {
        var now = DateTimeOffset.Parse("2026-05-06T07:08:09Z");
        foreach (var v in SpecVectors.Load("recovery-store.json").GetProperty("retention").EnumerateArray())
        {
            using var dir = new TempDir();
            var store = new RecoveryStore(dir.Path, () => now);
            var path = dir["old.md"];
            File.WriteAllText(path, "x");
            File.SetLastWriteTimeUtc(path, (now - TimeSpan.FromSeconds(v.GetProperty("ageSeconds").GetInt32())).UtcDateTime);
            store.PruneExpired(now);
            Assert.Equal(!v.GetProperty("pruned").GetBoolean(), File.Exists(path));
        }
    }

    [Fact]
    public void PreserveUsesTheCreationClockAndPrunesOldCopies()
    {
        using var dir = new TempDir();
        var final = DateTimeOffset.Parse("2030-01-01T00:00:00Z");
        var clock = final - RecoveryStore.Retention - TimeSpan.FromSeconds(10);
        var store = new RecoveryStore(dir.Path, () => clock);
        var old = store.Preserve(Guid.NewGuid(), "old.md", "old", DateTimeOffset.FromUnixTimeSeconds(100));
        clock = final;
        var recent = store.Preserve(Guid.NewGuid(), "recent.md", "recent", DateTimeOffset.FromUnixTimeSeconds(200));

        Assert.False(File.Exists(old.RecoveryPath));
        Assert.True(File.Exists(recent.RecoveryPath));
        Assert.Equal(final, recent.CreatedAt);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(200), recent.SourceModified);
        Assert.Equal(final.UtcDateTime, File.GetLastWriteTimeUtc(recent.RecoveryPath));
    }

    [Fact]
    public void PruneSkipsHiddenFilesDirectoriesAndLockedFiles()
    {
        using var dir = new TempDir();
        var now = DateTimeOffset.Parse("2026-05-06T07:08:09Z");
        var store = new RecoveryStore(dir.Path, () => now);
        var old = (now - TimeSpan.FromDays(30)).UtcDateTime;

        var hidden = dir[".hidden.md"];
        File.WriteAllText(hidden, "h");
        File.SetLastWriteTimeUtc(hidden, old);
        var sub = dir.Sub("folder");
        Directory.SetLastWriteTimeUtc(sub, old);
        var locked = dir["locked.md"];
        File.WriteAllText(locked, "l");
        File.SetLastWriteTimeUtc(locked, old);

        using (new FileStream(locked, FileMode.Open, FileAccess.Read, FileShare.None))
            store.PruneExpired(now); // must not throw on the locked file

        Assert.True(File.Exists(hidden));
        Assert.True(Directory.Exists(sub));
        Assert.True(File.Exists(locked));
        store.PruneExpired(now);
        Assert.False(File.Exists(locked));
    }

    [Fact]
    public void ReservedAndHostileNamesBecomeSafeRecoveryFiles()
    {
        using var dir = new TempDir();
        var store = new RecoveryStore(dir.Path);
        foreach (var name in new[] { "CON", "..\\..\\escape.md", "trailing.", "a?b*.md" })
        {
            var receipt = store.Preserve(Guid.NewGuid(), name, "x");
            Assert.Equal(dir.Path, Path.GetDirectoryName(receipt.RecoveryPath));
            Assert.True(File.Exists(receipt.RecoveryPath));
        }
    }

    [Fact]
    public void RecoveryFolderMayLiveBehindALongPath()
    {
        using var dir = new TempDir();
        var deep = dir.Path;
        while (deep.Length < 280) deep = Path.Combine(deep, "segment-" + new string('d', 20));
        var store = new RecoveryStore(deep);
        var receipt = store.Preserve(Guid.NewGuid(), "long.md", "payload");
        Assert.True(receipt.RecoveryPath.Length > 260);
        Assert.Equal("payload", File.ReadAllText(receipt.RecoveryPath));
    }
}
