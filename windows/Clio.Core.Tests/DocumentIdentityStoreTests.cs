using System.Diagnostics;
using System.Text.Json;
using Xunit;

namespace Clio.Core.Tests;

public sealed class DocumentIdentityStoreTests
{
    private static readonly Guid Preferred = new("11111111-2222-4333-8444-555555555555");

    private static Guid Workspace(string name) => new(System.Security.Cryptography.MD5.HashData(System.Text.Encoding.UTF8.GetBytes(name)));

    private static PhysicalFileIdentity.Resource Phys(string v)
    {
        var parts = v.Split(':', 2);
        return new PhysicalFileIdentity.Resource(parts[0], parts[1]);
    }

    private static DocumentIdentityCandidate Candidate(JsonElement c) => new(
        new DocumentLocator(Workspace(c.GetProperty("ws").GetString()!), c.GetProperty("path").GetString()!),
        Phys(c.GetProperty("physical").GetString()!),
        c.GetProperty("canonical").GetString(),
        c.TryGetProperty("preferred", out var pref) && pref.GetString() == "P" ? Preferred : null);

    [Fact]
    public void ScenariosMatchSharedVectors()
    {
        var root = SpecVectors.Load("document-identity.json");
        Assert.Equal(DocumentIdentityStore.MaximumRetainedTombstones, root.GetProperty("limits").GetProperty("maximumRetainedTombstones").GetInt32());
        Assert.Equal(DocumentIdentityStore.MaximumStorageByteCount, root.GetProperty("limits").GetProperty("maximumStorageBytes").GetInt64());

        foreach (var scenario in root.GetProperty("scenarios").EnumerateArray())
        {
            var name = scenario.GetProperty("name").GetString()!;
            var exists = scenario.TryGetProperty("exists", out var ex)
                ? new HashSet<string>(ex.EnumerateArray().Select(e => FileNames.Fold(e.GetString()!))) : [];
            using var store = new DocumentIdentityStore(null, null, exists.Contains);
            var ids = new Dictionary<string, Guid> { ["P"] = Preferred };
            var opIndex = 0;
            foreach (var op in scenario.GetProperty("ops").EnumerateArray())
            {
                switch (op.GetProperty("op").GetString())
                {
                    case "resolve":
                        var candidates = op.GetProperty("candidates").EnumerateArray().ToList();
                        var resolved = store.Resolve(candidates.Select(Candidate).ToList());
                        for (var i = 0; i < candidates.Count; i++) ids[candidates[i].GetProperty("as").GetString()!] = resolved[i];
                        break;
                    case "migrate":
                        var ws = Workspace(op.GetProperty("ws").GetString()!);
                        ids[op.GetProperty("as").GetString()!] = store.Migrate(
                            new DocumentLocator(ws, op.GetProperty("from").GetString()!), new DocumentLocator(ws, op.GetProperty("to").GetString()!),
                            Phys(op.GetProperty("physical").GetString()!), op.GetProperty("canonical").GetString());
                        break;
                    case "tombstone":
                        store.Tombstone(new DocumentLocator(Workspace(op.GetProperty("ws").GetString()!), op.GetProperty("path").GetString()!),
                            ids[op.GetProperty("id").GetString()!]);
                        break;
                    default: throw new InvalidOperationException(op.GetProperty("op").GetString());
                }
                if (scenario.TryGetProperty("physicalFilesAfterOp", out var after) && after.GetProperty("op").GetInt32() == opIndex)
                    Assert.Equal(after.GetProperty("count").GetInt32(), store.GetStatistics().PhysicalFiles);
                opIndex++;
            }
            if (scenario.TryGetProperty("same", out var same))
                foreach (var pair in same.EnumerateArray())
                    Assert.True(ids[pair[0].GetString()!] == ids[pair[1].GetString()!], $"{name}: {pair[0]} should equal {pair[1]}");
            if (scenario.TryGetProperty("different", out var different))
                foreach (var pair in different.EnumerateArray())
                    Assert.True(ids[pair[0].GetString()!] != ids[pair[1].GetString()!], $"{name}: {pair[0]} should differ from {pair[1]}");
        }
    }

    [Fact]
    public void TombstonesStayBounded()
    {
        using var store = new DocumentIdentityStore();
        var ws = Guid.NewGuid();
        for (var n = 0; n < DocumentIdentityStore.MaximumRetainedTombstones + 50; n++)
        {
            var locator = new DocumentLocator(ws, $"deleted-{n}.md");
            var id = store.Resolve(new DocumentIdentityCandidate(locator));
            store.Tombstone(locator, id);
        }
        Assert.True(store.GetStatistics().Tombstones <= DocumentIdentityStore.MaximumRetainedTombstones);
    }

    [Fact]
    public void RepeatedAtomicSavesKeepPhysicalStateBounded()
    {
        using var store = new DocumentIdentityStore();
        var locator = new DocumentLocator(Guid.NewGuid(), "note.md");
        var first = store.Resolve(new DocumentIdentityCandidate(locator, Phys("v:0"), "c:/w/note.md"));
        for (var n = 1; n <= 200; n++)
            Assert.Equal(first, store.Resolve(new DocumentIdentityCandidate(locator, Phys($"v:{n}"), "c:/w/note.md")));
        Assert.Equal(1, store.GetStatistics().PhysicalFiles);
    }

    [Fact]
    public void IdentityPersistsAcrossStoreRecreation()
    {
        using var dir = new TempDir();
        var path = dir["identities.json"];
        var locator = new DocumentLocator(Guid.NewGuid(), "persisted.md");
        Guid id;
        using (var store = new DocumentIdentityStore(path))
        {
            id = store.Resolve(new DocumentIdentityCandidate(locator, Phys("v:1"), "c:/w/persisted.md"));
            store.FlushPendingPersistence();
        }
        using var reopened = new DocumentIdentityStore(path);
        Assert.Equal(id, reopened.StoredDocumentId(locator));
        Assert.Equal(id, reopened.Resolve(new DocumentIdentityCandidate(locator, Phys("v:1"), "c:/w/persisted.md")));
        Assert.DoesNotContain(Directory.EnumerateFiles(dir.Path), f => Path.GetFileName(f).StartsWith(".clio-", StringComparison.Ordinal));
    }

    [Fact]
    public void CorruptStoreFailsClosedWithoutOverwritingMetadata()
    {
        using var dir = new TempDir();
        var path = dir["identities.json"];
        byte[] garbage = [0x00, 0xFF, 0x7B, 0x01];
        File.WriteAllBytes(path, garbage);
        using var store = new DocumentIdentityStore(path);
        var locator = new DocumentLocator(Guid.NewGuid(), "a.md");

        Assert.Throws<IdentityStoreException>(() => store.Resolve(new DocumentIdentityCandidate(locator)));
        Assert.Throws<IdentityStoreException>(() => store.Bind(Guid.NewGuid(), locator, null));
        Assert.Throws<IdentityStoreException>(() => store.Migrate(locator, locator with { RelativePath = "b.md" }, null));
        Assert.Throws<IdentityStoreException>(() => store.Tombstone(locator));
        Assert.Throws<IdentityStoreException>(() => store.TombstoneDescendants(locator.WorkspaceId, "x"));
        Assert.Throws<IdentityStoreException>(store.FlushPendingPersistence);
        Assert.Equal(garbage, File.ReadAllBytes(path));
    }

    [Fact]
    public void OversizedStoreIsTreatedAsCorrupt()
    {
        using var dir = new TempDir();
        var path = dir["identities.json"];
        using (var stream = File.Create(path)) stream.SetLength(DocumentIdentityStore.MaximumStorageByteCount + 1);
        using var store = new DocumentIdentityStore(path);
        Assert.Throws<IdentityStoreException>(() => store.Resolve(new DocumentIdentityCandidate(new DocumentLocator(Guid.NewGuid(), "a.md"))));
        Assert.Equal(DocumentIdentityStore.MaximumStorageByteCount + 1, new FileInfo(path).Length);
    }

    [Fact]
    public async Task BackgroundPersistenceFailureIsObservableAndFlushRetries()
    {
        using var dir = new TempDir();
        var path = dir["identities.json"];
        var failing = false;
        using var store = new DocumentIdentityStore(path, (data, p) =>
        {
            if (failing) throw new IOException("disk full");
            File.WriteAllBytes(p, data);
        });
        var ws = Guid.NewGuid();
        var locator = new DocumentLocator(ws, "a.md");
        var id = store.Resolve(new DocumentIdentityCandidate(locator, Phys("v:1"), "c:/w/a.md"));

        failing = true;
        // Only the physical id changes, so the write is debounced into the background.
        store.Bind(id, locator, Phys("v:2"), "c:/w/a.md");
        for (var i = 0; i < 100 && store.PersistenceFailureDescription() is null; i++) await Task.Delay(20);
        Assert.Equal("disk full", store.PersistenceFailureDescription());

        failing = false;
        store.FlushPendingPersistence();
        Assert.Null(store.PersistenceFailureDescription());
        using var reopened = new DocumentIdentityStore(path);
        Assert.Equal(id, reopened.Resolve(new DocumentIdentityCandidate(locator, Phys("v:2"), "c:/w/a.md")));
    }

    [Fact]
    public void TombstoneDescendantsRemovesAFolderCaseInsensitively()
    {
        using var store = new DocumentIdentityStore();
        var ws = Guid.NewGuid();
        var inside = new DocumentLocator(ws, "Folder/Sub/Note.md");
        var sibling = new DocumentLocator(ws, "FolderTwo/Note.md");
        var insideId = store.Resolve(new DocumentIdentityCandidate(inside));
        var siblingId = store.Resolve(new DocumentIdentityCandidate(sibling));

        store.TombstoneDescendants(ws, "folder");

        Assert.Null(store.StoredDocumentId(inside));
        Assert.Equal(siblingId, store.StoredDocumentId(sibling));
        Assert.NotEqual(insideId, store.Resolve(new DocumentIdentityCandidate(inside)));
    }

    [Fact]
    public void ResolutionScalesLinearly()
    {
        using var store = new DocumentIdentityStore();
        var ws = Guid.NewGuid();
        List<DocumentIdentityCandidate> Make(int n) => [.. Enumerable.Range(0, n).Select(i =>
            new DocumentIdentityCandidate(new DocumentLocator(ws, $"doc-{i}.md"), Phys($"v:{i}"), $"c:/w/doc-{i}.md"))];

        var watch = Stopwatch.StartNew();
        var ids = store.Resolve(Make(20_000));
        var again = store.Resolve(Make(20_000));
        watch.Stop();

        Assert.True(ids.SequenceEqual(again));
        Assert.Equal(20_000, ids.Distinct().Count());
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(10), $"two passes over 20k candidates took {watch.Elapsed}");
    }

    // ---- real NTFS file ids ----------------------------------------------------------------------

    [Fact]
    public void FileIdSurvivesARenameAndDiffersBetweenFiles()
    {
        using var dir = new TempDir();
        File.WriteAllText(dir["a.md"], "a");
        File.WriteAllText(dir["b.md"], "b");
        var before = PhysicalFileIdentity.OfFile(dir["a.md"]);
        File.Move(dir["a.md"], dir["Renamed.md"]);
        Assert.Equal(before, PhysicalFileIdentity.OfFile(dir["renamed.MD"]));
        Assert.NotEqual(before, PhysicalFileIdentity.OfFile(dir["b.md"]));
        Assert.IsType<PhysicalFileIdentity.Resource>(before);
    }

    [Fact]
    public void MissingFileFallsBackToItsFoldedPath()
    {
        using var dir = new TempDir();
        var identity = Assert.IsType<PhysicalFileIdentity.ByPath>(PhysicalFileIdentity.OfFile(dir["ghost.md"]));
        Assert.Equal(PhysicalFileIdentity.OfFile(dir["GHOST.md"]), identity);
    }

    [Fact]
    public void RenameKeepsIdentityAndDeleteRecreateDoesNotEvenIfNtfsReusesTheFileId()
    {
        using var dir = new TempDir();
        var ws = Guid.NewGuid();
        using var store = new DocumentIdentityStore();
        DocumentIdentityCandidate At(string name) =>
            new(new DocumentLocator(ws, name), PhysicalFileIdentity.OfFile(dir[name]), Path.GetFullPath(dir[name]));

        File.WriteAllText(dir["source.md"], "first inode");
        var original = store.Resolve(At("source.md"));

        File.Move(dir["source.md"], dir["moved.md"]);
        var migrated = store.Migrate(new DocumentLocator(ws, "source.md"), new DocumentLocator(ws, "moved.md"),
            PhysicalFileIdentity.OfFile(dir["moved.md"]), Path.GetFullPath(dir["moved.md"]));
        Assert.Equal(original, migrated);
        Assert.Equal(original, store.Resolve(At("moved.md")));

        store.Tombstone(new DocumentLocator(ws, "moved.md"), original);
        File.Delete(dir["moved.md"]);
        File.WriteAllText(dir["moved.md"], "new file, id may be reused");
        Assert.NotEqual(original, store.Resolve(At("moved.md")));
    }

    [Fact]
    public void MissedRenameAndOldPathRecreationDoNotMergeRealFiles()
    {
        using var dir = new TempDir();
        var ws = Guid.NewGuid();
        using var store = new DocumentIdentityStore();
        DocumentIdentityCandidate At(string name) =>
            new(new DocumentLocator(ws, name), PhysicalFileIdentity.OfFile(dir[name]), Path.GetFullPath(dir[name]));

        File.WriteAllText(dir["a.md"], "original");
        var originalId = store.Resolve(At("a.md"));

        File.Move(dir["a.md"], dir["z.md"]);
        File.WriteAllText(dir["a.md"], "recreated");
        var ids = store.Resolve([At("a.md"), At("z.md")]);

        Assert.Equal(originalId, ids[1]);
        Assert.NotEqual(originalId, ids[0]);
    }
}
