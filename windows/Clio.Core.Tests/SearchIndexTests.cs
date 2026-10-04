using System.Text;
using Xunit;

namespace Clio.Core.Tests;

public sealed class SearchIndexTests
{
    private static WorkspaceDescriptor Workspace(string root) => new(Guid.NewGuid(), root);

    private static SearchIndex Open(TempDir dir, string name = "index.sqlite3", DocumentIdentityStore? ids = null, Func<string, FileSnapshot>? snapshot = null) =>
        new(Path.Combine(dir.Path, ".cache", name), ids ?? new DocumentIdentityStore(), snapshot);

    private static void Write(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
    }

    private static async Task<List<SearchBatch>> Batches(IAsyncEnumerable<SearchBatch> stream)
    {
        var batches = new List<SearchBatch>();
        await foreach (var b in stream) batches.Add(b);
        return batches;
    }

    private static async Task<SearchBatch> Final(IAsyncEnumerable<SearchBatch> stream) => (await Batches(stream)).Last(b => b.IsFinal);

    // ---- shared vectors ------------------------------------------------------------------------

    [Fact]
    public void QueryConstructionMatchesSharedVectors()
    {
        var root = SpecVectors.Load("search-queries.json");
        var limits = root.GetProperty("limits");
        Assert.Equal(SearchQuery.MaximumResults, limits.GetProperty("maximumResults").GetInt32());
        Assert.Equal(SearchQueryText.MaximumTerms, limits.GetProperty("maximumTerms").GetInt32());
        Assert.Equal(SearchQueryText.MaximumTermLength, limits.GetProperty("maximumTermLength").GetInt32());
        Assert.Equal(SearchIndex.MaximumIndexedFileBytes, limits.GetProperty("maximumIndexedFileBytes").GetInt64());

        foreach (var c in root.GetProperty("queryTerms").EnumerateArray())
            Assert.Equal(c.GetProperty("terms").EnumerateArray().Select(t => t.GetString()!), SearchQueryText.Terms(c.GetProperty("query").GetString()!));

        var caps = root.GetProperty("termCaps");
        var many = caps.GetProperty("manyTerms");
        Assert.Equal(many.GetProperty("expectedTerms").GetInt32(),
            SearchQueryText.Terms(string.Join(' ', Enumerable.Range(0, many.GetProperty("words").GetInt32()).Select(i => $"w{i}"))).Count);
        var longTerm = caps.GetProperty("longTerm");
        Assert.Equal(longTerm.GetProperty("expectedLength").GetInt32(),
            SearchQueryText.Terms(new string('a', longTerm.GetProperty("length").GetInt32()))[0].Length);

        foreach (var c in root.GetProperty("ftsQuery").EnumerateArray())
            Assert.Equal(c.GetProperty("fts").GetString(), SearchQueryText.FullTextQuery([.. c.GetProperty("terms").EnumerateArray().Select(t => t.GetString()!)]));

        foreach (var c in root.GetProperty("escapedLike").EnumerateArray())
            Assert.Equal(c.GetProperty("escaped").GetString(), SearchQueryText.EscapeLike(c.GetProperty("input").GetString()!));

        foreach (var c in root.GetProperty("limitClamp").EnumerateArray())
            Assert.Equal(c.GetProperty("clamped").GetInt32(), new SearchQuery("x", limit: c.GetProperty("limit").GetInt32()).Limit);
    }

    // ---- behaviour (ports of WorkspaceIndexTests) -----------------------------------------------

    [Fact]
    public async Task SearchFilteringInvalidationAndStableIdentity()
    {
        using var dir = new TempDir();
        var alpha = Path.Combine(dir.Path, "alpha.md");
        Write(alpha, "A quiet searchable phrase.\nSecond line.");
        using var ids = new DocumentIdentityStore();
        using var index = Open(dir, ids: ids);
        var workspace = Workspace(dir.Path);
        await index.RebuildAsync([workspace]);

        var quick = await Final(index.QuickOpenAsync(new SearchQuery("alp")));
        Assert.Equal("alpha.md", quick.Results[0].RelativePath);
        var firstId = quick.Results[0].DocumentId;

        var search = await Final(index.SearchAsync(new SearchQuery("searchable phrase")));
        Assert.Equal(["alpha.md"], search.Results.Select(r => r.RelativePath));
        Assert.NotNull(search.Results[0].ExcerptMatchRange);

        await index.RebuildAsync([workspace]);
        Assert.Equal(firstId, (await Final(index.QuickOpenAsync(new SearchQuery("alpha")))).Results[0].DocumentId);

        Write(alpha, "A replacement token.");
        await index.ApplyAsync([new WorkspaceEvent(workspace.Id, WorkspaceEventKind.Modified, alpha)]);
        Assert.Equal(firstId, (await Final(index.SearchAsync(new SearchQuery("replacement")))).Results[0].DocumentId);
        Assert.Empty((await Final(index.SearchAsync(new SearchQuery("quiet")))).Results);

        var moved = Path.Combine(dir.Path, "renamed.md");
        File.Move(alpha, moved);
        await index.ApplyAsync([new WorkspaceEvent(workspace.Id, WorkspaceEventKind.Moved, moved, alpha)]);
        var afterMove = await Final(index.QuickOpenAsync(new SearchQuery("renamed")));
        Assert.Equal(firstId, afterMove.Results[0].DocumentId);
        Assert.Empty((await Final(index.QuickOpenAsync(new SearchQuery("alpha")))).Results);

        File.Delete(moved);
        await index.ApplyAsync([new WorkspaceEvent(workspace.Id, WorkspaceEventKind.Deleted, moved)]);
        Assert.Empty((await Final(index.QuickOpenAsync(new SearchQuery("renamed")))).Results);
    }

    [Fact]
    public async Task DisappearingModifiedFileIsTreatedAsDeletion()
    {
        using var dir = new TempDir();
        var doc = Path.Combine(dir.Path, "ephemeral.md");
        Write(doc, "short lived token");
        using var index = Open(dir);
        var workspace = Workspace(dir.Path);
        await index.RebuildAsync([workspace]);
        File.Delete(doc);

        await index.ApplyAsync([new WorkspaceEvent(workspace.Id, WorkspaceEventKind.Modified, doc)]);
        Assert.Empty((await Final(index.SearchAsync(new SearchQuery("short lived")))).Results);
    }

    [Fact]
    public async Task FileThatGrowsPastTheLimitAfterTheMetadataCheckIsRejected()
    {
        using var dir = new TempDir();
        var doc = Path.Combine(dir.Path, "growing.md");
        Write(doc, "stale bounded token");
        var grown = false;
        using var index = Open(dir, snapshot: path =>
        {
            var real = SearchIndex.ReadSnapshot(path);
            return grown ? new FileSnapshot(new byte[SearchIndex.MaximumIndexedFileBytes + 1], real.Revision) : real;
        });
        var workspace = Workspace(dir.Path);
        await index.RebuildAsync([workspace]);
        Assert.Single((await Final(index.SearchAsync(new SearchQuery("stale bounded")))).Results);

        grown = true;
        await index.ApplyAsync([new WorkspaceEvent(workspace.Id, WorkspaceEventKind.Modified, doc)]);
        Assert.Empty((await Final(index.SearchAsync(new SearchQuery("stale bounded")))).Results);
    }

    [Fact]
    public async Task OversizedAndNonUtf8FilesAreNotIndexed()
    {
        using var dir = new TempDir();
        Write(Path.Combine(dir.Path, "good.md"), "needle in a good file");
        File.WriteAllBytes(Path.Combine(dir.Path, "binary.md"), [0xFF, 0xFE, 0x00, 0xC3, 0x28, (byte)'n', (byte)'e', (byte)'e', (byte)'d', (byte)'l', (byte)'e']);
        using var index = Open(dir);
        await index.RebuildAsync([Workspace(dir.Path)]);
        var found = await Final(index.SearchAsync(new SearchQuery("needle")));
        Assert.Equal(["good.md"], found.Results.Select(r => r.RelativePath));
    }

    [Fact]
    public void SnapshotRefusesALinkRepointedAfterTheScan()
    {
        using var dir = new TempDir();
        var target = dir["private.md"];
        File.WriteAllText(target, "private data");
        var link = dir["link.md"];
        if (!TempDir.TryCreateSymlink(link, target)) return; // needs the symlink privilege
        Assert.ThrowsAny<ClioException>(() => SearchIndex.ReadSnapshot(link));
    }

    [Fact]
    public async Task SnapshotRevisionDescribesTheBytesThatWereIndexed()
    {
        using var dir = new TempDir();
        var doc = dir["note.md"];
        Write(doc, "first content");
        var snapshot = SearchIndex.ReadSnapshot(doc);
        Write(doc, "replaced content that is longer");
        Assert.Equal("first content".Length, snapshot.Revision.ByteCount);
        Assert.Equal(DiskRevision.Digest(Encoding.UTF8.GetBytes("first content")), snapshot.Revision.ContentDigest);
        await Task.CompletedTask;
    }

    [Fact]
    public async Task OverlappingWorkspaceRootsAppearOnce()
    {
        using var dir = new TempDir();
        var nested = Path.Combine(dir.Path, "nested");
        Write(Path.Combine(nested, "note.md"), "one unique needle");
        using var index = Open(dir);
        var root = Workspace(dir.Path);
        var inner = Workspace(nested);
        await index.RebuildAsync([root, inner]);

        var batch = await Final(index.SearchAsync(new SearchQuery("needle")));
        var only = Assert.Single(batch.Results);
        Assert.Equal(inner.Id, only.WorkspaceId);
        Assert.Equal("note.md", only.RelativePath);

        var parent = await Final(index.SearchAsync(new SearchQuery("needle", root.Id)));
        Assert.Equal("nested/note.md", parent.Results[0].RelativePath);
    }

    [Fact]
    public async Task ColdScopedContentSearchStreamsThenRanksAtEveryLimit()
    {
        using var dir = new TempDir();
        var scope = Path.Combine(dir.Path, "scope");
        var other = Path.Combine(dir.Path, "other");
        for (var i = 0; i < 30; i++) Write(Path.Combine(scope, $"a{i:00}.md"), "needle " + string.Concat(Enumerable.Repeat("padding ", 100)));
        Write(Path.Combine(scope, "z-best.md"), "needle needle needle needle needle");
        Write(Path.Combine(other, "outside.md"), "needle");
        var scoped = Workspace(scope);
        var database = "cold.sqlite3";
        using var ids = new DocumentIdentityStore();
        using (var seed = Open(dir, database, ids)) await seed.RebuildAsync([scoped, Workspace(other)]);

        foreach (var limit in new[] { 1, 10, 100 })
        {
            using var reopened = Open(dir, database, ids);
            var batches = await Batches(reopened.SearchAsync(new SearchQuery("needle", scoped.Id, limit: limit)));
            Assert.Equal(2, batches.Count);
            Assert.False(batches[0].IsFinal);
            Assert.All(batches[0].Results, r => Assert.Equal(0, r.Score));
            Assert.True(batches[1].IsFinal);
            Assert.Equal(Math.Min(limit, 31), batches[1].Results.Count);
            Assert.Equal("z-best.md", batches[1].Results[0].RelativePath);
            Assert.All(batches[1].Results, r => { Assert.Equal(scoped.Id, r.WorkspaceId); Assert.True(r.Score > 0); });
            var rest = batches[1].Results.Skip(1).Select(r => r.RelativePath).ToList();
            Assert.Equal([.. rest.OrderBy(p => p, StringComparer.OrdinalIgnoreCase)], rest);
        }
    }

    [Fact]
    public async Task ResultsNeverExceedFiveHundredWhateverTheRequestedLimit()
    {
        using var dir = new TempDir();
        for (var i = 0; i < 520; i++) Write(Path.Combine(dir.Path, $"n{i:000}.md"), "common token");
        using var index = Open(dir);
        await index.RebuildAsync([Workspace(dir.Path)]);
        Assert.Equal(500, (await Final(index.SearchAsync(new SearchQuery("common", limit: 10_000)))).Results.Count);
        Assert.Equal(500, (await Final(index.QuickOpenAsync(new SearchQuery("n", limit: 10_000)))).Results.Count);
    }

    [Fact]
    public async Task ContentSearchReturnsBoundedExcerptForTenMiBSingleLine()
    {
        using var dir = new TempDir();
        const int half = 5 * 1024 * 1024;
        Write(Path.Combine(dir.Path, "large.md"), new string('a', half) + " needle " + new string('z', half - 8));
        using var index = Open(dir);
        await index.RebuildAsync([Workspace(dir.Path)]);

        var result = (await Final(index.SearchAsync(new SearchQuery("needle")))).Results[0];
        Assert.True(result.Excerpt!.Length <= 1024);
        Assert.NotNull(result.ExcerptMatchRange);
    }

    [Fact]
    public async Task SearchEscapesOperatorsAndSurvivesImmediateCancellation()
    {
        using var dir = new TempDir();
        Write(Path.Combine(dir.Path, "100%_notes.md"), "Compass 🧭 café café quote OR AND percent underscore slash.");
        using var index = Open(dir);
        await index.RebuildAsync([Workspace(dir.Path)]);

        Assert.Equal("100%_notes.md", (await Final(index.QuickOpenAsync(new SearchQuery("%_")))).Results[0].RelativePath);
        Assert.Equal("100%_notes.md", (await Final(index.SearchAsync(new SearchQuery("\"café\" OR AND")))).Results[0].RelativePath);
        // Diacritics fold: the decomposed spelling in the document matches the composed query and the reverse.
        Assert.Single((await Final(index.SearchAsync(new SearchQuery("cafe")))).Results);

        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            await foreach (var _ in index.SearchAsync(new SearchQuery(string.Concat(Enumerable.Repeat("needle ", 2_000))), cts.Token)) { }
        });
        Assert.Equal("100%_notes.md", (await Final(index.SearchAsync(new SearchQuery("Compass")))).Results[0].RelativePath);
    }

    [Fact]
    public async Task ConcurrentRebuildKeepsPreviousIndexQueryable()
    {
        using var dir = new TempDir();
        Write(Path.Combine(dir.Path, "stable.md"), "stable previous content");
        using var index = Open(dir);
        var workspace = Workspace(dir.Path);
        await index.RebuildAsync([workspace]);
        for (var i = 0; i < 500; i++) Write(Path.Combine(dir.Path, "bulk", $"{i}.md"), $"background rebuild {i}");

        var rebuilding = index.RebuildAsync([workspace]);
        var during = await Final(index.SearchAsync(new SearchQuery("stable previous")));
        Assert.Equal("stable.md", during.Results[0].RelativePath);
        await rebuilding;

        Assert.Equal("bulk/499.md", (await Final(index.SearchAsync(new SearchQuery("background 499")))).Results[0].RelativePath);
    }

    [Fact]
    public async Task NewerRebuildCancelsTheOlderOne()
    {
        using var dir = new TempDir();
        for (var i = 0; i < 200; i++) Write(Path.Combine(dir.Path, $"{i}.md"), $"doc {i}");
        using var index = Open(dir);
        var workspace = Workspace(dir.Path);
        var older = index.RebuildAsync([workspace]);
        var newer = index.RebuildAsync([workspace]);
        await newer;
        try { await older; } catch (OperationCanceledException) { }
        Assert.Equal(200, (await Final(index.QuickOpenAsync(new SearchQuery(".md", limit: 500)))).Results.Count);
    }

    [Fact]
    public async Task RescanAndGitIgnoreEventsRebuild()
    {
        using var dir = new TempDir();
        Write(Path.Combine(dir.Path, "keep.md"), "kept token");
        Write(Path.Combine(dir.Path, "hide.md"), "hidden token");
        using var index = Open(dir);
        var workspace = Workspace(dir.Path);
        await index.RebuildAsync([workspace]);
        Assert.Single((await Final(index.SearchAsync(new SearchQuery("hidden")))).Results);

        Write(Path.Combine(dir.Path, ".gitignore"), "hide.md");
        await index.ApplyAsync([new WorkspaceEvent(workspace.Id, WorkspaceEventKind.Modified, Path.Combine(dir.Path, ".gitignore"))]);
        Assert.Empty((await Final(index.SearchAsync(new SearchQuery("hidden")))).Results);

        Write(Path.Combine(dir.Path, "later.md"), "late token");
        await index.ApplyAsync([new WorkspaceEvent(workspace.Id, WorkspaceEventKind.RescanRequired, dir.Path)]);
        Assert.Single((await Final(index.SearchAsync(new SearchQuery("late token")))).Results);
    }

    [Fact]
    public async Task AccessLossEventsLeaveTheIndexQueryable()
    {
        using var dir = new TempDir();
        Write(Path.Combine(dir.Path, "a.md"), "durable token");
        using var index = Open(dir);
        var workspace = Workspace(dir.Path);
        await index.RebuildAsync([workspace]);
        await index.ApplyAsync([new WorkspaceEvent(workspace.Id, WorkspaceEventKind.AccessLost, dir.Path)]);
        Assert.Single((await Final(index.SearchAsync(new SearchQuery("durable")))).Results);
    }

    [Fact]
    public async Task IndexesPathsWithSpacesUnicodeAndLongNames()
    {
        using var dir = new TempDir();
        var longName = new string('x', 120) + ".md";
        Write(Path.Combine(dir.Path, "Ünïcode folder", "Café notes.md"), "alpha");
        Write(Path.Combine(dir.Path, longName), "beta");
        using var index = Open(dir);
        await index.RebuildAsync([Workspace(dir.Path)]);
        Assert.Equal("Ünïcode folder/Café notes.md", (await Final(index.QuickOpenAsync(new SearchQuery("café NOTES")))).Results[0].RelativePath);
        // SQLite NOCASE folds ASCII only, on macOS as here: the unaccented spelling is not a filename match.
        Assert.Empty((await Final(index.QuickOpenAsync(new SearchQuery("cafe notes")))).Results);
        Assert.Equal(longName, (await Final(index.QuickOpenAsync(new SearchQuery("xxxxxxxx")))).Results[0].RelativePath);
    }

    // ---- scanner identity ----------------------------------------------------------------------

    [Fact]
    public void ScannerIdentityIsStableAcrossRenameAndNewForARecreatedPath()
    {
        using var dir = new TempDir();
        var workspace = Guid.NewGuid();
        var original = dir["one.md"];
        File.WriteAllText(original, "one");
        using var ids = new DocumentIdentityStore();
        var first = WorkspaceScanner.ScanFiles(workspace, dir.Path, ids).Single();

        File.Move(original, dir["renamed.md"]);
        ids.Migrate(new DocumentLocator(workspace, "one.md"), new DocumentLocator(workspace, "renamed.md"), PhysicalFileIdentity.TryOfFile(dir["renamed.md"]), dir["renamed.md"]);
        var afterRename = WorkspaceScanner.ScanFiles(workspace, dir.Path, ids).Single();
        Assert.Equal(first.DocumentId, afterRename.DocumentId);
        Assert.Equal("renamed.md", afterRename.RelativePath);

        // A different file taking the old name is a new document.
        File.WriteAllText(original, "recreated");
        var all = WorkspaceScanner.ScanFiles(workspace, dir.Path, ids);
        Assert.Equal(2, all.Count);
        Assert.NotEqual(first.DocumentId, all.Single(f => f.RelativePath == "one.md").DocumentId);
        Assert.Equal(first.DocumentId, all.Single(f => f.RelativePath == "renamed.md").DocumentId);
    }

    [Fact]
    public void ScannerOptionallyIncludesTextFiles()
    {
        using var dir = new TempDir();
        File.WriteAllText(dir["a.md"], "a");
        File.WriteAllText(dir["b.txt"], "b");
        Assert.Equal(["a.md"], WorkspaceScanner.Scan(dir.Path).Select(e => e.Relative));
        Assert.Equal(["a.md", "b.txt"], WorkspaceScanner.Scan(dir.Path, includeText: true).Select(e => e.Relative));
    }
}
