using System.Text;
using System.Text.Json;
using Xunit;

namespace Clio.Core.Tests;

public sealed class AtomicWriteTransactionTests
{
    private sealed class InjectedCrash : Exception;

    private static byte[] B(string s) => Encoding.UTF8.GetBytes(s);

    private static DiskRevision Rev(string content) => new(B(content).LongLength, DateTimeOffset.UtcNow, DiskRevision.Digest(B(content)));

    private static List<string> Artifacts(string dir) =>
        [.. Directory.EnumerateFileSystemEntries(dir).Select(Path.GetFileName).Where(n => n!.StartsWith(".clio-", StringComparison.Ordinal)).Select(n => n!)];

    private static List<string> Journaled(CrashRecoveryJournal journal) =>
        [.. journal.ValidRecords().Select(r => $"{JsonNamingPolicy.CamelCase.ConvertName(r.Reason.ToString())}:{Encoding.UTF8.GetString(r.Data)}").Order(StringComparer.Ordinal)];

    /// <summary>Journal entries as 'reason:state' where state is the vector's name for the content (base, candidate, other).</summary>
    private static List<string> JournaledAs(CrashRecoveryJournal journal, System.Text.Json.JsonElement contents) =>
        [.. Journaled(journal).Select(j =>
        {
            var content = j[(j.IndexOf(':') + 1)..];
            var state = contents.EnumerateObject().First(p => p.Value.GetString() == content).Name;
            return j[..(j.IndexOf(':') + 1)] + state;
        }).Order(StringComparer.Ordinal)];

    private static void WriteManifest(string dir, AtomicWriteManifest m, string? name = null) =>
        File.WriteAllBytes(Path.Combine(dir, name ?? AtomicWriteTransactions.ManifestPrefix + m.Id.ToString("D") + AtomicWriteTransactions.ManifestSuffix),
            JsonSerializer.SerializeToUtf8Bytes(m, CrashRecoveryJournal.Json));

    [Fact]
    public void RecoveryDecisionsMatchSharedVectors()
    {
        var spec = SpecVectors.Load("atomic-write-recovery.json");
        var contents = spec.GetProperty("contents");
        string Content(string state) => contents.GetProperty(state).GetString()!;

        foreach (var row in spec.GetProperty("rows").EnumerateArray())
        {
            var temporary = row.GetProperty("temporary").GetString()!;
            // The temporary slot is the temp file or, once the temp is gone, the displaced file: both must behave alike.
            var slots = temporary == "absent" ? new[] { "temp" } : new[] { "temp", "displaced" };
            foreach (var slot in slots)
            {
                using var dir = new TempDir();
                var name = row.GetProperty("name").GetString() + " [" + slot + "]";
                var destination = dir["draft.md"];
                var expectedBase = row.GetProperty("expectedBase").GetBoolean();
                var tx = AtomicWriteTransactions.Begin(B(Content("candidate")), destination,
                    expectedBase ? AtomicWriteOperation.Replace : AtomicWriteOperation.Create, expectedBase ? Rev(Content("base")) : null);

                var destState = row.GetProperty("destination").GetString()!;
                if (destState != "absent") File.WriteAllBytes(destination, B(Content(destState)));
                var slotPath = slot == "temp" ? tx.Manifest.TemporaryPath : tx.Manifest.DisplacedPath;
                if (temporary != "absent") File.WriteAllBytes(slotPath, B(Content(temporary)));

                var journal = new CrashRecoveryJournal(dir.Sub("journal"));
                AtomicWriteTransactions.RecoverInterrupted(dir.Path, journal);

                var expected = row.GetProperty("checkpoints").EnumerateArray().Select(e => e.GetString()!).Order(StringComparer.Ordinal).ToList();
                Assert.True(expected.SequenceEqual(JournaledAs(journal, contents)), name + " checkpoints: " + string.Join(",", JournaledAs(journal, contents)));
                var cleanup = row.GetProperty("cleanup").GetBoolean();
                Assert.Equal(!cleanup, File.Exists(tx.ManifestPath));
                if (temporary != "absent") Assert.Equal(!cleanup, File.Exists(slotPath));
                // Recovery never edits the destination.
                Assert.Equal(destState == "absent" ? null : Content(destState), File.Exists(destination) ? File.ReadAllText(destination) : null);
            }
        }
    }

    [Theory]
    [InlineData(AtomicWritePhase.ManifestSynced)]
    [InlineData(AtomicWritePhase.CandidateSynced)]
    [InlineData(AtomicWritePhase.Swapped)]
    [InlineData(AtomicWritePhase.ParentSynced)]
    public void KillPointsRecoverEveryUniqueByteSequence(AtomicWritePhase phase)
    {
        foreach (var replace in new[] { true, false })
        {
            using var dir = new TempDir();
            var destination = dir["draft.md"];
            if (replace) File.WriteAllText(destination, "outside-base");

            Assert.Throws<InjectedCrash>(() => AtomicFile.Write(destination, B("latest-local"), null, p => { if (p == phase) throw new InjectedCrash(); }));

            var journal = new CrashRecoveryJournal(dir.Sub("journal"));
            AtomicWriteTransactions.RecoverInterrupted(dir.Path, journal);

            var seen = new HashSet<string>(Journaled(journal).Select(j => j[(j.IndexOf(':') + 1)..]));
            if (File.Exists(destination)) seen.Add(File.ReadAllText(destination));
            var required = replace
                ? phase == AtomicWritePhase.ManifestSynced ? new[] { "outside-base" } : ["outside-base", "latest-local"]
                : phase == AtomicWritePhase.ManifestSynced ? [] : new[] { "latest-local" };
            Assert.True(seen.IsSupersetOf(required), $"{phase} replace={replace} lost bytes; saw {string.Join(",", seen)}");
            Assert.Empty(Artifacts(dir.Path));
        }
    }

    [Fact]
    public void SuccessfulWriteLeavesNoArtifacts()
    {
        using var dir = new TempDir();
        var destination = dir["a.md"];
        AtomicFile.Write(destination, B("first"));
        AtomicFile.Write(destination, B("second"));
        Assert.Equal("second", File.ReadAllText(destination));
        Assert.Empty(Artifacts(dir.Path));
    }

    [Fact]
    public void PhaseHookSeesEveryPhaseInOrder()
    {
        using var dir = new TempDir();
        var destination = dir["a.md"];
        File.WriteAllText(destination, "old");
        var seen = new List<AtomicWritePhase>();
        AtomicFile.Write(destination, B("new"), null, seen.Add);
        Assert.Equal([AtomicWritePhase.ManifestSynced, AtomicWritePhase.CandidateSynced, AtomicWritePhase.Swapped, AtomicWritePhase.ParentSynced], seen);
    }

    [Fact]
    public void LockedDestinationKeepsTheOriginalAndLeavesNoArtifacts()
    {
        using var dir = new TempDir();
        var destination = dir["locked.md"];
        File.WriteAllText(destination, "original");

        using (new FileStream(destination, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            // Without a known revision the writer must read the file first and fails there; with one it fails at the swap.
            Assert.ThrowsAny<IOException>(() => AtomicFile.Write(destination, B("new")));
            Assert.ThrowsAny<IOException>(() => AtomicFile.Write(destination, B("new"), Rev("original")));
        }

        Assert.Equal("original", File.ReadAllText(destination));
        Assert.Empty(Artifacts(dir.Path));
        AtomicFile.Write(destination, B("new"), Rev("original"));
        Assert.Equal("new", File.ReadAllText(destination));
    }

    [Fact]
    public void WriteSucceedsOncePassingLockIsReleased()
    {
        using var dir = new TempDir();
        var destination = dir["busy.md"];
        File.WriteAllText(destination, "original");
        var hold = new FileStream(destination, FileMode.Open, FileAccess.Read, FileShare.None);
        _ = Task.Run(() => { Thread.Sleep(150); hold.Dispose(); }); // an antivirus scan that lets go

        AtomicFile.Write(destination, B("new"), Rev("original"));

        Assert.Equal("new", File.ReadAllText(destination));
        Assert.Empty(Artifacts(dir.Path));
    }

    [Fact]
    public void LongPathsSaveAndRecover()
    {
        using var dir = new TempDir();
        var deep = dir.Path;
        while (deep.Length < 270) deep = Path.Combine(deep, "folder-" + new string('p', 24));
        Directory.CreateDirectory(deep);
        var destination = Path.Combine(deep, "long.md");
        AtomicFile.Write(destination, B("v1"));
        AtomicFile.Write(destination, B("v2"));
        Assert.True(destination.Length > 260);
        Assert.Equal("v2", File.ReadAllText(destination));
        Assert.Empty(Artifacts(deep));

        Assert.Throws<InjectedCrash>(() => AtomicFile.Write(destination, B("v3"), null, p => { if (p == AtomicWritePhase.Swapped) throw new InjectedCrash(); }));
        var journal = new CrashRecoveryJournal(dir.Sub("journal"));
        Assert.True(AtomicWriteTransactions.RecoverInterrupted(dir.Path, journal) >= 1);
        Assert.Contains("atomicDisplaced:v2", Journaled(journal));
        Assert.Empty(Artifacts(deep));
    }

    [Fact]
    public void CaseInsensitiveNameReplacesTheExistingFileInPlace()
    {
        using var dir = new TempDir();
        File.WriteAllText(dir["Notes.md"], "old");
        AtomicFile.Write(dir["notes.md"], B("new"));
        // One file, never two names for the same document. The casing follows the path the caller passed.
        Assert.Equal("new", File.ReadAllText(Assert.Single(Directory.GetFiles(dir.Path))));
    }

    [Fact]
    public void ReplacingKeepsFileAttributes()
    {
        using var dir = new TempDir();
        var destination = dir["a.md"];
        File.WriteAllText(destination, "old");
        File.SetAttributes(destination, FileAttributes.Hidden | FileAttributes.Archive);
        AtomicFile.Write(destination, B("new"));
        Assert.True(File.GetAttributes(destination).HasFlag(FileAttributes.Hidden));
    }

    [Fact]
    public void WritingThroughASymlinkIsRefused()
    {
        using var dir = new TempDir();
        var real = dir["real.md"];
        File.WriteAllText(real, "real");
        if (!TempDir.TryCreateSymlink(dir["link.md"], real)) return; // no symlink privilege on this machine
        Assert.Throws<LinkException>(() => AtomicFile.Write(dir["link.md"], B("x")));
        Assert.Equal("real", File.ReadAllText(real));
        Assert.Empty(Artifacts(dir.Path));
    }

    // ---- hostile manifests -----------------------------------------------------------------------

    private static AtomicWriteManifest ManifestFor(string dir, string destination, string candidate, string? temporaryName = null, Guid? id = null)
    {
        var guid = id ?? Guid.NewGuid();
        return new AtomicWriteManifest(
            AtomicWriteManifest.CurrentSchema, guid, AtomicWriteOperation.Replace, destination,
            Path.Combine(dir, temporaryName ?? AtomicWriteTransactions.TemporaryPrefix + guid.ToString("D")),
            Path.Combine(dir, AtomicWriteTransactions.DisplacedPrefix + guid.ToString("D")),
            B(candidate).LongLength, DiskRevision.Digest(B(candidate)), Rev("base"), DateTimeOffset.UtcNow);
    }

    [Fact]
    public void ManifestPointingOutsideTheRootIsLeftUntouched()
    {
        using var dir = new TempDir();
        var workspace = dir.Sub("workspace");
        var outside = dir["outside.md"];
        File.WriteAllText(outside, "do-not-touch");
        var m = ManifestFor(workspace, outside, "do-not-touch");
        File.WriteAllText(m.TemporaryPath, "do-not-touch"); // a valid-looking candidate in the temp slot
        WriteManifest(workspace, m);

        var journal = new CrashRecoveryJournal(dir.Sub("journal"));
        Assert.Equal(0, AtomicWriteTransactions.RecoverInterrupted(workspace, journal));
        Assert.Empty(journal.ValidRecords());
        Assert.Equal("do-not-touch", File.ReadAllText(outside));
        Assert.Single(Artifacts(workspace), n => n.StartsWith(AtomicWriteTransactions.ManifestPrefix, StringComparison.Ordinal));
    }

    [Fact]
    public void ManifestWithMismatchedNamesOrSchemaIsIgnored()
    {
        using var dir = new TempDir();
        var workspace = dir.Sub("workspace");
        var destination = Path.Combine(workspace, "draft.md");
        File.WriteAllText(destination, "base");
        var journal = new CrashRecoveryJournal(dir.Sub("journal"));

        var wrongTemp = ManifestFor(workspace, destination, "cand", temporaryName: ".clio-save-not-my-id");
        File.WriteAllText(wrongTemp.TemporaryPath, "cand");
        WriteManifest(workspace, wrongTemp);

        var wrongSchema = ManifestFor(workspace, destination, "cand") with { SchemaVersion = 2 };
        File.WriteAllText(wrongSchema.TemporaryPath, "cand");
        WriteManifest(workspace, wrongSchema);

        var wrongName = ManifestFor(workspace, destination, "cand");
        File.WriteAllText(wrongName.TemporaryPath, "cand");
        WriteManifest(workspace, wrongName, AtomicWriteTransactions.ManifestPrefix + Guid.NewGuid().ToString("D") + AtomicWriteTransactions.ManifestSuffix);

        Assert.Equal(0, AtomicWriteTransactions.RecoverInterrupted(workspace, journal));
        Assert.Empty(journal.ValidRecords());
        Assert.Equal(3, Directory.GetFiles(workspace, AtomicWriteTransactions.ManifestPrefix + "*").Length);
    }

    [Fact]
    public void OversizedManifestAndOversizedCandidateAreIgnored()
    {
        using var dir = new TempDir();
        var workspace = dir.Sub("workspace");
        var destination = Path.Combine(workspace, "draft.md");
        File.WriteAllText(destination, "base");
        var journal = new CrashRecoveryJournal(dir.Sub("journal"));

        var huge = ManifestFor(workspace, destination, "cand") with { CandidateByteCount = AtomicWriteTransactions.MaximumRecoverableByteCount + 1 };
        File.WriteAllText(huge.TemporaryPath, "cand");
        WriteManifest(workspace, huge);

        var bloated = ManifestFor(workspace, destination, "cand");
        File.WriteAllText(bloated.TemporaryPath, "cand");
        File.WriteAllText(Path.Combine(workspace, AtomicWriteTransactions.ManifestPrefix + bloated.Id.ToString("D") + AtomicWriteTransactions.ManifestSuffix),
            new string(' ', (int)AtomicWriteTransactions.MaximumManifestByteCount + 1));

        Assert.Equal(0, AtomicWriteTransactions.RecoverInterrupted(workspace, journal));
        Assert.Empty(journal.ValidRecords());
        Assert.Equal(2, Directory.GetFiles(workspace, AtomicWriteTransactions.ManifestPrefix + "*").Length);
    }

    [Fact]
    public void SymlinkedTemporaryFileIsNeverFollowed()
    {
        using var dir = new TempDir();
        var workspace = dir.Sub("workspace");
        var outside = dir["outside.md"];
        File.WriteAllText(outside, "do-not-touch");
        var destination = Path.Combine(workspace, "draft.md");
        File.WriteAllText(destination, "base");
        var m = ManifestFor(workspace, destination, "do-not-touch");
        if (!TempDir.TryCreateSymlink(m.TemporaryPath, outside)) return; // no symlink privilege on this machine
        WriteManifest(workspace, m);

        var journal = new CrashRecoveryJournal(dir.Sub("journal"));
        AtomicWriteTransactions.RecoverInterrupted(workspace, journal);

        Assert.Empty(journal.ValidRecords());
        Assert.Equal("do-not-touch", File.ReadAllText(outside));
        Assert.NotNull(new FileInfo(m.TemporaryPath).LinkTarget);
        Assert.True(File.Exists(Path.Combine(workspace, AtomicWriteTransactions.ManifestPrefix + m.Id.ToString("D") + AtomicWriteTransactions.ManifestSuffix)));
    }

    [Fact]
    public void LinkedSubdirectoryIsNotEnumerated()
    {
        using var dir = new TempDir();
        var workspace = dir.Sub("workspace");
        var outsideDir = dir.Sub("elsewhere");
        var destination = Path.Combine(outsideDir, "draft.md");
        File.WriteAllText(destination, "base");
        var m = ManifestFor(outsideDir, destination, "cand");
        File.WriteAllText(m.TemporaryPath, "cand");
        WriteManifest(outsideDir, m);
        try { Directory.CreateSymbolicLink(Path.Combine(workspace, "portal"), outsideDir); }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException) { return; } // no symlink privilege

        var journal = new CrashRecoveryJournal(dir.Sub("journal"));
        Assert.Equal(0, AtomicWriteTransactions.RecoverInterrupted(workspace, journal));
        Assert.True(File.Exists(m.TemporaryPath));
        Assert.Empty(journal.ValidRecords());
    }

    [Fact]
    public void RecoveryWalksNestedFoldersAndHonoursTheNonRecursiveFlag()
    {
        using var dir = new TempDir();
        var nested = dir.Sub("a\\b");
        var destination = Path.Combine(nested, "draft.md");
        Assert.Throws<InjectedCrash>(() => AtomicFile.Write(destination, B("nested"), null, p => { if (p == AtomicWritePhase.CandidateSynced) throw new InjectedCrash(); }));

        var journal = new CrashRecoveryJournal(dir.Sub("journal"));
        Assert.Equal(0, AtomicWriteTransactions.RecoverInterrupted(dir.Path, journal, recursive: false));
        Assert.NotEmpty(Artifacts(nested));
        Assert.Equal(1, AtomicWriteTransactions.RecoverInterrupted(dir.Path, journal));
        Assert.Equal(["atomicCandidate:nested"], Journaled(journal));
        Assert.Empty(Artifacts(nested));
    }
}
