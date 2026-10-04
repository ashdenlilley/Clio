using System.Text;
using System.Text.Json;
using Xunit;

namespace Clio.Core.Tests;

public sealed class InterruptedMoveTransactionTests
{
    private static byte[] B(string s) => Encoding.UTF8.GetBytes(s);

    private static DiskRevision Rev(string content) => new(B(content).LongLength, DateTimeOffset.UtcNow, DiskRevision.Digest(B(content)));

    private static List<string> Journaled(CrashRecoveryJournal journal) =>
        [.. journal.ValidRecords().Select(r => $"{JsonNamingPolicy.CamelCase.ConvertName(r.Reason.ToString())}:{Encoding.UTF8.GetString(r.Data)}")];

    private sealed class Rig : IDisposable
    {
        public TempDir Dir { get; } = new();
        public string SourceRoot { get; }
        public string DestinationRoot { get; }
        public string Source { get; }
        public string Destination { get; }
        public CrashRecoveryJournal Journal { get; }

        public Rig(bool crossRoot)
        {
            SourceRoot = Dir.Sub("workspace-a");
            DestinationRoot = crossRoot ? Dir.Sub("workspace-b") : SourceRoot;
            Source = Path.Combine(Dir.Sub("workspace-a\\notes"), "moved.md");
            Destination = Path.Combine(crossRoot ? Dir.Sub("workspace-b\\inbox") : Dir.Sub("workspace-a\\archive"), "moved.md");
            Journal = new CrashRecoveryJournal(Dir.Sub("journal"));
        }

        public InterruptedMoveTransaction Begin(string sourceContent, string? expectedDestination) =>
            InterruptedMoveTransactions.Begin(Guid.NewGuid(), new BufferGeneration(Guid.NewGuid(), 3), SourceRoot, DestinationRoot, Source, Destination,
                Rev(sourceContent), expectedDestination is null ? null : Rev(expectedDestination), B(sourceContent));

        public int Recover(params string[] roots) => InterruptedMoveTransactions.Recover(roots.Length == 0 ? [SourceRoot, DestinationRoot] : roots, Journal);

        public void Dispose() => Dir.Dispose();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void RecoveryDecisionsMatchSharedVectors(bool crossRoot)
    {
        var spec = SpecVectors.Load("move-recovery.json");
        var contents = spec.GetProperty("contents");
        string Content(string key) => contents.GetProperty(key).GetString()!;

        foreach (var row in spec.GetProperty("rows").EnumerateArray())
        {
            using var rig = new Rig(crossRoot);
            var name = row.GetProperty("name").GetString() + (crossRoot ? " [cross-root]" : " [same root]");
            var recorded = row.GetProperty("destinationRecorded").GetBoolean();
            var tx = rig.Begin(Content("source"), recorded ? Content("expected") : null);

            if (row.GetProperty("source").GetString() == "present") File.WriteAllBytes(rig.Source, B(Content("source")));
            if (row.GetProperty("quarantine").GetString() == "present") File.WriteAllBytes(tx.Manifest.QuarantinePath, B(Content("source")));
            var destState = row.GetProperty("destination").GetString()!;
            if (destState != "absent") File.WriteAllBytes(rig.Destination, B(Content(destState == "candidate" ? "source" : destState)));

            var recovered = rig.Recover();

            Assert.True(row.GetProperty("recovered").GetInt32() == recovered, name + " recovered");
            var journaled = Journaled(rig.Journal);
            if (row.GetProperty("checkpoint").GetBoolean()) Assert.Equal(["interruptedMove:" + Content("source")], journaled);
            else Assert.True(journaled.Count == 0, name + " must not checkpoint");
            Assert.True(row.GetProperty("sourceRemains").GetBoolean() == File.Exists(rig.Source), name + " source");
            Assert.True(row.GetProperty("manifestRemoved").GetBoolean() == !File.Exists(tx.ManifestPath), name + " manifest");
            Assert.False(File.Exists(tx.Manifest.QuarantinePath) && row.GetProperty("checkpoint").GetBoolean(), name + " quarantine must be cleared once journaled");
            // The destination is never rewritten.
            if (destState != "absent") Assert.Equal(Content(destState == "candidate" ? "source" : destState), File.ReadAllText(rig.Destination));
        }
    }

    [Fact]
    public void CrossWorkspaceManifestWaitsForBothAuthorizedRoots()
    {
        using var rig = new Rig(crossRoot: true);
        var tx = rig.Begin("payload", null);
        File.WriteAllText(rig.Source, "payload");
        File.WriteAllText(rig.Destination, "payload");

        Assert.Equal(0, rig.Recover(rig.SourceRoot));
        Assert.True(File.Exists(rig.Source));
        Assert.True(File.Exists(tx.ManifestPath));
        Assert.Empty(rig.Journal.ValidRecords());

        Assert.Equal(1, rig.Recover(rig.SourceRoot, rig.DestinationRoot));
        Assert.False(File.Exists(rig.Source));
        Assert.False(File.Exists(tx.ManifestPath));
        Assert.Equal(["interruptedMove:payload"], Journaled(rig.Journal));
    }

    [Fact]
    public void BeginRefusesPathsOutsideTheirRoots()
    {
        using var rig = new Rig(crossRoot: false);
        var outside = rig.Dir["outside.md"];
        File.WriteAllText(outside, "x");
        Assert.Throws<LinkException>(() => InterruptedMoveTransactions.Begin(
            Guid.NewGuid(), default, rig.SourceRoot, rig.DestinationRoot, outside, rig.Destination, Rev("x"), null, B("x")));
        Assert.Throws<LinkException>(() => InterruptedMoveTransactions.Begin(
            Guid.NewGuid(), default, rig.SourceRoot, rig.DestinationRoot, rig.Source, outside, Rev("x"), null, B("x")));
    }

    [Fact]
    public void BeginRefusesALinkedSource()
    {
        using var rig = new Rig(crossRoot: false);
        var real = rig.Dir["real.md"];
        File.WriteAllText(real, "x");
        if (!TempDir.TryCreateSymlink(rig.Source, real)) return; // no symlink privilege on this machine
        Assert.Throws<LinkException>(() => rig.Begin("x", null));
        Assert.Equal("x", File.ReadAllText(real));
    }

    [Fact]
    public void TamperedManifestsAreIgnored()
    {
        using var rig = new Rig(crossRoot: false);
        File.WriteAllText(rig.Source, "payload");
        File.WriteAllText(rig.Destination, "payload");
        var good = rig.Begin("payload", null);

        // Wrong file name for its id, a quarantine path outside the root, and a destination root outside every grant.
        var renamed = Path.Combine(Path.GetDirectoryName(good.ManifestPath)!, InterruptedMoveTransactions.ManifestPrefix + Guid.NewGuid().ToString("D") + ".json");
        File.Copy(good.ManifestPath, renamed);
        File.Delete(good.ManifestPath);

        var escaped = good.Manifest with { Id = Guid.NewGuid(), QuarantinePath = rig.Dir["stolen"], DestinationRoot = rig.Dir.Path };
        File.WriteAllBytes(Path.Combine(Path.GetDirectoryName(rig.Source)!, InterruptedMoveTransactions.ManifestPrefix + escaped.Id.ToString("D") + ".json"),
            JsonSerializer.SerializeToUtf8Bytes(escaped, CrashRecoveryJournal.Json));

        Assert.Equal(0, rig.Recover());
        Assert.True(File.Exists(rig.Source));
        Assert.Empty(rig.Journal.ValidRecords());
        Assert.Equal(2, Directory.GetFiles(Path.GetDirectoryName(rig.Source)!, InterruptedMoveTransactions.ManifestPrefix + "*").Length);
    }

    [Fact]
    public void LockedSourceIsRetriedNextTimeAndNeverLost()
    {
        using var rig = new Rig(crossRoot: false);
        File.WriteAllText(rig.Source, "payload");
        File.WriteAllText(rig.Destination, "payload");
        var tx = rig.Begin("payload", null);

        using (new FileStream(rig.Source, FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.Equal(0, rig.Recover()); // must not throw or stop other manifests

        Assert.True(File.Exists(rig.Source));
        Assert.True(File.Exists(tx.ManifestPath));
        Assert.Equal(1, rig.Recover());
        Assert.Equal(["interruptedMove:payload"], Journaled(rig.Journal));
    }

    [Fact]
    public void AbortBacksOutOnlyWhileTheDestinationIsUntouched()
    {
        using var rig = new Rig(crossRoot: false);
        File.WriteAllText(rig.Source, "payload");
        var untouched = rig.Begin("payload", null);
        Assert.True(InterruptedMoveTransactions.AbortIfDestinationUnchanged(untouched));
        Assert.False(File.Exists(untouched.ManifestPath));
        Assert.True(File.Exists(rig.Source));

        var written = rig.Begin("payload", null);
        File.WriteAllText(rig.Destination, "payload");
        Assert.False(InterruptedMoveTransactions.AbortIfDestinationUnchanged(written));
        Assert.True(File.Exists(written.ManifestPath));

        File.WriteAllText(rig.Destination, "old");
        var replace = rig.Begin("payload", "old");
        Assert.True(InterruptedMoveTransactions.AbortIfDestinationUnchanged(replace));
    }

    [Fact]
    public void QuarantineKeepsTheSourceBytesAndRefusesToOverwrite()
    {
        using var rig = new Rig(crossRoot: false);
        File.WriteAllText(rig.Source, "payload");
        var tx = rig.Begin("payload", null);

        InterruptedMoveTransactions.QuarantineSource(tx);
        Assert.False(File.Exists(rig.Source));
        Assert.Equal("payload", File.ReadAllText(tx.Manifest.QuarantinePath));
        Assert.Equal(DiskRevision.Digest(B("payload")), InterruptedMoveTransactions.SourceRevision(tx).ContentDigest);

        File.WriteAllText(rig.Source, "recreated");
        Assert.Throws<IOException>(() => InterruptedMoveTransactions.QuarantineSource(tx));
        Assert.Equal("payload", File.ReadAllText(tx.Manifest.QuarantinePath));
        Assert.Equal("recreated", File.ReadAllText(rig.Source));

        InterruptedMoveTransactions.Finish(tx, removeQuarantine: true);
        Assert.False(File.Exists(tx.Manifest.QuarantinePath));
        Assert.False(File.Exists(tx.ManifestPath));
    }

    [Fact]
    public void LongPathsAndCaseInsensitiveRootsRecover()
    {
        using var dir = new TempDir();
        var deep = dir.Path;
        while (deep.Length < 270) deep = Path.Combine(deep, "level-" + new string('q', 24));
        Directory.CreateDirectory(deep);
        var source = Path.Combine(deep, "doc.md");
        var destination = Path.Combine(deep, "moved.md");
        File.WriteAllText(source, "payload");
        File.WriteAllText(destination, "payload");
        var journal = new CrashRecoveryJournal(dir.Sub("journal"));
        var tx = InterruptedMoveTransactions.Begin(Guid.NewGuid(), default, deep, deep, source, destination, Rev("payload"), null, B("payload"));
        Assert.True(tx.ManifestPath.Length > 260);

        // The authorized root is given with different casing than the manifest recorded.
        Assert.Equal(1, InterruptedMoveTransactions.Recover([deep.ToUpperInvariant()], journal));
        Assert.False(File.Exists(source));
        Assert.Equal(["interruptedMove:payload"], Journaled(journal));
    }
}
