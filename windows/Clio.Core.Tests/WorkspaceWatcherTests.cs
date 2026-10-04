using System.Collections.Concurrent;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Xunit;

namespace Clio.Core.Tests;

public sealed class WorkspaceWatcherTests
{
    private static readonly TimeSpan Patience = TimeSpan.FromSeconds(8);

    /// <summary>Drains a watcher's channel into a list so tests can wait for specific events.</summary>
    private sealed class Recorder : IDisposable
    {
        private readonly ConcurrentQueue<WorkspaceEvent> _events = new();
        private readonly Task _pump;
        public Recorder(WorkspaceWatcher watcher) => _pump = Task.Run(async () =>
        {
            await foreach (var e in watcher.Events.ReadAllAsync()) _events.Enqueue(e);
        });
        public IReadOnlyList<WorkspaceEvent> All => [.. _events];
        public bool Contains(WorkspaceEventKind kind, string? path = null, DateTimeOffset? after = null) =>
            _events.Any(e => e.Kind == kind
                && (path is null || string.Equals(e.Path, path, StringComparison.OrdinalIgnoreCase))
                && (after is null || e.ObservedAt >= after));
        public async Task<bool> WaitFor(WorkspaceEventKind kind, string? path = null, DateTimeOffset? after = null)
        {
            var deadline = DateTime.UtcNow + Patience;
            while (DateTime.UtcNow < deadline)
            {
                if (Contains(kind, path, after)) return true;
                await Task.Delay(10);
            }
            return false;
        }
        public bool Completed => _pump.IsCompleted;
        public async Task<bool> WaitForCompletion() => await Task.WhenAny(_pump, Task.Delay(Patience)) == _pump;
        public void Dispose() { }
    }

    private static async Task<WorkspaceWatcher> Started(string root, bool text = false, Action? scanObserver = null, Action<string, WatcherChangeTypes>? raw = null)
    {
        var w = new WorkspaceWatcher(Guid.NewGuid(), root, text, scanObserver, raw);
        await Task.Delay(300); // let the initial snapshot finish
        return w;
    }

    [Fact]
    public void SnapshotDiffMatchesSharedVectors()
    {
        foreach (var scenario in SpecVectors.Load("workspace-snapshot-diff.json").GetProperty("scenarios").EnumerateArray())
        {
            var name = scenario.GetProperty("name").GetString()!;
            var next = Snapshot(scenario.GetProperty("next"));
            var changes = SnapshotDiff.Compute(Snapshot(scenario.GetProperty("previous")), next);
            var expected = scenario.GetProperty("events").EnumerateArray()
                .Select(e => (e.GetProperty("kind").GetString()!, e.GetProperty("path").GetString()!,
                    e.TryGetProperty("previous", out var p) ? p.GetString() : null)).ToList();
            var actual = changes.Select(c => (c.Kind.ToString().ToLowerInvariant(), c.Path, c.PreviousPath)).ToList();

            Assert.True(expected.Count == actual.Count && expected.All(e => actual.Contains(e)), $"{name}: expected {Format(expected)}, got {Format(actual)}");
            foreach (var kind in new[] { "deleted", "created" })
                Assert.True(expected.Where(e => e.Item1 == kind).Select(e => e.Item2).SequenceEqual(actual.Where(a => a.Item1 == kind).Select(a => a.Item2)),
                    $"{name}: {kind} order");
            Assert.Equal(scenario.GetProperty("rescanRequired").GetBoolean(), changes.Count == 0);
        }

        static string Format(IEnumerable<(string, string, string?)> items) => string.Join(", ", items.Select(i => $"{i.Item1}:{i.Item2}<-{i.Item3}"));

        static Dictionary<PhysicalFileIdentity, FileState> Snapshot(JsonElement files) => files.EnumerateArray().ToDictionary(
            f => (PhysicalFileIdentity)new PhysicalFileIdentity.Resource("v", f.GetProperty("id").GetString()!),
            f => new FileState(new PhysicalFileIdentity.Resource("v", f.GetProperty("id").GetString()!), f.GetProperty("path").GetString()!,
                new DateTime(f.GetProperty("mtime").GetInt64(), DateTimeKind.Utc), f.GetProperty("size").GetInt64()));
    }

    [Fact]
    public async Task ReportsNestedCreateMoveModifyAndDelete()
    {
        using var dir = new TempDir();
        var nested = dir.Sub("nested");
        using var watcher = await Started(dir.Path);
        using var rec = new Recorder(watcher);

        // Wait for each change before making the next: a move and a delete landing in one rescan correctly report
        // only the deletion, and fixed sleeps would let that happen under load.
        var created = Path.Combine(nested, "one.md");
        File.WriteAllText(created, "one");
        Assert.True(await rec.WaitFor(WorkspaceEventKind.Created, created), Dump(rec));

        var before = DateTimeOffset.UtcNow;
        var temp = Path.Combine(nested, ".clio-save-one");
        File.WriteAllText(temp, "two");
        File.Replace(temp, created, null);
        Assert.True(await rec.WaitFor(WorkspaceEventKind.Modified, created, before), Dump(rec));

        var moved = Path.Combine(nested, "two.md");
        File.Move(created, moved);
        Assert.True(await rec.WaitFor(WorkspaceEventKind.Moved, moved), Dump(rec));
        Assert.Equal(created, rec.All.Last(e => e.Kind == WorkspaceEventKind.Moved).PreviousPath, ignoreCase: true);

        File.Delete(moved);
        Assert.True(await rec.WaitFor(WorkspaceEventKind.Deleted, moved), Dump(rec));
    }

    [Fact]
    public async Task ReportsInPlaceWriteWithoutFullRescan()
    {
        using var dir = new TempDir();
        var file = dir["in-place.md"];
        File.WriteAllText(file, "before");
        var scans = 0;
        using var watcher = await Started(dir.Path, scanObserver: () => Interlocked.Increment(ref scans));
        using var rec = new Recorder(watcher);

        var idBefore = PhysicalFileIdentity.OfFile(file);
        File.WriteAllText(file, "after direct write");
        Assert.Equal(idBefore, PhysicalFileIdentity.OfFile(file));

        Assert.True(await rec.WaitFor(WorkspaceEventKind.Modified, file), Dump(rec));
        await Task.Delay(200);
        Assert.Equal(1, Volatile.Read(ref scans));
    }

    [Fact]
    public async Task SustainedAtomicSavesDoNotRepeatFullScans()
    {
        using var dir = new TempDir();
        var file = dir["atomic.md"];
        File.WriteAllText(file, "initial");
        var scans = 0;
        using var watcher = await Started(dir.Path, scanObserver: () => Interlocked.Increment(ref scans));
        using var rec = new Recorder(watcher);

        for (var revision = 0; revision < 12; revision++)
        {
            DocumentIO.Save(file, $"revision {revision}", false, LineEnding.Lf, DocumentIO.Load(file).Revision);
            await Task.Delay(60);
        }
        Assert.True(await rec.WaitFor(WorkspaceEventKind.Modified, file), Dump(rec));
        await Task.Delay(300);
        Assert.Equal(1, Volatile.Read(ref scans));
        Assert.DoesNotContain(rec.All, e => e.Kind is WorkspaceEventKind.Deleted or WorkspaceEventKind.Created);
    }

    [Fact]
    public async Task ReportsDeletionOfFilePresentAtStartup()
    {
        using var dir = new TempDir();
        var file = dir["delete-me.md"];
        File.WriteAllText(file, "before deletion");
        using var watcher = await Started(dir.Path);
        using var rec = new Recorder(watcher);

        File.Delete(file);
        Assert.True(await rec.WaitFor(WorkspaceEventKind.Deleted, file), Dump(rec));
    }

    [Fact]
    public async Task ReportsInPlaceGitIgnoreChange()
    {
        using var dir = new TempDir();
        var ignore = dir[".gitignore"];
        File.WriteAllText(ignore, "*.tmp");
        using var watcher = await Started(dir.Path);
        using var rec = new Recorder(watcher);

        using (var stream = new FileStream(ignore, FileMode.Truncate, FileAccess.Write, FileShare.ReadWrite))
            stream.Write("*.md"u8);
        Assert.True(await rec.WaitFor(WorkspaceEventKind.RescanRequired, ignore), Dump(rec));
    }

    [Fact]
    public async Task DisposeFinishesTheEventStream()
    {
        using var dir = new TempDir();
        var watcher = await Started(dir.Path);
        using var rec = new Recorder(watcher);
        watcher.Dispose();
        Assert.True(await rec.WaitForCompletion());
    }

    [Fact]
    public async Task ReportsAccessLossWhenRootDisappears()
    {
        using var dir = new TempDir();
        var root = dir.Sub("root");
        using var watcher = await Started(root);
        using var rec = new Recorder(watcher);

        Directory.Delete(root, recursive: true);
        Assert.True(await rec.WaitFor(WorkspaceEventKind.AccessLost), Dump(rec));
        Assert.True(await rec.WaitForCompletion());
    }

    [Fact]
    public async Task MissingRootReportsAccessLossAtOnce()
    {
        using var dir = new TempDir();
        using var watcher = new WorkspaceWatcher(Guid.NewGuid(), dir["absent"]);
        using var rec = new Recorder(watcher);
        Assert.True(await rec.WaitFor(WorkspaceEventKind.AccessLost));
        Assert.True(await rec.WaitForCompletion());
    }

    [Fact]
    public async Task TextFilesAreTrackedOnlyWhenIncluded()
    {
        using var dir = new TempDir();
        using var plain = await Started(dir.Path);
        using var withText = await Started(dir.Path, text: true);
        using var plainRec = new Recorder(plain);
        using var textRec = new Recorder(withText);

        var note = dir["a.txt"];
        File.WriteAllText(note, "x");
        Assert.True(await textRec.WaitFor(WorkspaceEventKind.Created, note), Dump(textRec));
        Assert.False(plainRec.Contains(WorkspaceEventKind.Created, note));
    }

    [Fact]
    public async Task PartialTraversalKeepsLastSnapshotWithoutFalseDeletion()
    {
        using var dir = new TempDir();
        var restricted = dir.Sub("restricted");
        var note = Path.Combine(restricted, "retained.md");
        File.WriteAllText(note, "retain this canonical file");
        var scans = 0;
        using var watcher = await Started(dir.Path, scanObserver: () => Interlocked.Increment(ref scans));
        using var rec = new Recorder(watcher);
        var complete = Volatile.Read(ref scans);
        Assert.True(complete >= 1);

        using (DenyListing(restricted))
        {
            Directory.CreateDirectory(dir["trigger"]);
            Assert.True(await rec.WaitFor(WorkspaceEventKind.RescanRequired), Dump(rec));
            Assert.True(Volatile.Read(ref scans) > complete);
            Assert.False(rec.Contains(WorkspaceEventKind.Deleted, note));
        }
    }

    [Fact]
    public async Task UnknownRemovalAfterPartialStartupRequestsAudit()
    {
        using var dir = new TempDir();
        var restricted = dir.Sub("restricted");
        var note = Path.Combine(restricted, "unknown.md");
        File.WriteAllText(note, "not yet in a complete snapshot");
        WorkspaceWatcher watcher;
        using (DenyListing(restricted))
        {
            watcher = await Started(dir.Path);
        }
        using var _ = watcher;
        using var rec = new Recorder(watcher);
        Assert.True(await rec.WaitFor(WorkspaceEventKind.RescanRequired), Dump(rec));

        File.Delete(note);
        await Task.Delay(400);
        Assert.False(rec.Contains(WorkspaceEventKind.Deleted, note));
        Assert.True(rec.Contains(WorkspaceEventKind.RescanRequired));
    }

    [Fact]
    public async Task OverflowAlwaysLeavesAFullRescanMarker()
    {
        using var dir = new TempDir();
        using var watcher = await Started(dir.Path);
        for (var i = 0; i < WorkspaceWatcher.EventCapacity + 300; i++) File.WriteAllText(dir[$"bulk-{i}.md"], "x");
        await Task.Delay(1500);

        // Read after the burst: the oldest details were dropped, the marker must remain.
        var marker = false;
        using var cts = new CancellationTokenSource(Patience);
        try
        {
            await foreach (var e in watcher.Events.ReadAllAsync(cts.Token))
                if (e.Kind == WorkspaceEventKind.RescanRequired) { marker = true; break; }
        }
        catch (OperationCanceledException) { }
        Assert.True(marker);
    }

    [Fact]
    public async Task WatchesAPathWithSpacesAndUnicode()
    {
        using var dir = new TempDir();
        var folder = dir.Sub("Ünïcode folder");
        using var watcher = await Started(dir.Path);
        using var rec = new Recorder(watcher);
        var file = Path.Combine(folder, "Café notes.md");
        File.WriteAllText(file, "x");
        Assert.True(await rec.WaitFor(WorkspaceEventKind.Created, file), Dump(rec));
    }

    private static string Dump(Recorder rec) => string.Join(", ", rec.All.Select(e => $"{e.Kind}:{Path.GetFileName(e.Path)}"));

    /// <summary>Denies listing on a directory for the current user and restores access on dispose.</summary>
    private static IDisposable DenyListing(string path)
    {
        var user = WindowsIdentity.GetCurrent().User!;
        var rule = new FileSystemAccessRule(user, FileSystemRights.ListDirectory, AccessControlType.Deny);
        var info = new DirectoryInfo(path);
        var acl = info.GetAccessControl();
        acl.AddAccessRule(rule);
        info.SetAccessControl(acl);
        return new Restore(() =>
        {
            var restore = info.GetAccessControl();
            restore.RemoveAccessRule(rule);
            info.SetAccessControl(restore);
        });
    }

    private sealed class Restore(Action action) : IDisposable
    {
        public void Dispose() => action();
    }
}
