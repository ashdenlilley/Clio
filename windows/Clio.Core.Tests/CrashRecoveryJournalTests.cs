using System.Text;
using System.Text.Json;
using Xunit;

namespace Clio.Core.Tests;

public sealed class CrashRecoveryJournalTests
{
    private static Guid Doc(string name) => new(System.Security.Cryptography.MD5.HashData(Encoding.UTF8.GetBytes(name)));

    private static string ReasonName(RecoveryReason r) => JsonNamingPolicy.CamelCase.ConvertName(r.ToString());

    private static CrashRecoveryRecord Record(string doc, ulong rev, RecoveryReason reason, string content, DateTimeOffset? at = null) =>
        CrashRecoveryRecord.Create(Doc(doc), new BufferGeneration(Doc(doc), rev), "draft.md", null, reason, Encoding.UTF8.GetBytes(content), at);

    private static List<string> Remaining(CrashRecoveryJournal journal) =>
        [.. journal.ValidRecords().Select(r => $"{ReasonName(r.Reason)}:{r.Generation.Revision}:{Encoding.UTF8.GetString(r.Data)}").Order(StringComparer.Ordinal)];

    [Fact]
    public void ScenariosMatchSharedVectors()
    {
        var root = SpecVectors.Load("recovery-journal.json");
        Assert.Equal(CrashRecoveryJournal.MaximumRecordByteCount, root.GetProperty("maximumRecordBytes").GetInt64());
        foreach (var scenario in root.GetProperty("scenarios").EnumerateArray())
        {
            using var dir = new TempDir();
            var journal = new CrashRecoveryJournal(dir.Path);
            var clock = DateTimeOffset.Parse("2026-01-01T00:00:00Z");
            foreach (var op in scenario.GetProperty("ops").EnumerateArray())
            {
                clock = clock.AddSeconds(1);
                var kind = op.GetProperty("op").GetString();
                switch (kind)
                {
                    case "checkpoint":
                        var reason = Enum.Parse<RecoveryReason>(op.GetProperty("reason").GetString()!, ignoreCase: true);
                        journal.Checkpoint(Record(op.GetProperty("doc").GetString()!, op.GetProperty("rev").GetUInt64(), reason, op.GetProperty("content").GetString()!, clock));
                        break;
                    case "schedule":
                        var doc = op.GetProperty("doc").GetString()!;
                        journal.Schedule(new CrashRecoverySnapshot(Doc(doc), new BufferGeneration(Doc(doc), op.GetProperty("rev").GetUInt64()),
                            "draft.md", null, RecoveryReason.DirtyBuffer, op.GetProperty("content").GetString()!, clock));
                        break;
                    case "flush": journal.Flush(); break;
                    case "clear": journal.Clear(Doc(op.GetProperty("doc").GetString()!), op.GetProperty("through").GetUInt64()); break;
                    default: throw new InvalidOperationException(kind);
                }
            }
            journal.Flush();
            var expected = scenario.GetProperty("remaining").EnumerateArray().Select(e => e.GetString()!).ToList();
            Assert.True(expected.SequenceEqual(Remaining(journal)), scenario.GetProperty("name").GetString());
        }
    }

    [Fact]
    public void RoundTripsBinaryDataAndMetadata()
    {
        using var dir = new TempDir();
        var journal = new CrashRecoveryJournal(dir.Path);
        byte[] data = [0xEF, 0xBB, 0xBF, 0x00, 0xFF, 0x0D, 0x0A];
        var target = dir["target.md"];
        var written = CrashRecoveryRecord.Create(Guid.NewGuid(), new BufferGeneration(Guid.NewGuid(), 7), "target.md", target, RecoveryReason.ExternalConflict, data);
        journal.Checkpoint(written);

        var read = Assert.Single(journal.ValidRecords());
        Assert.Equal(data, read.Data);
        Assert.Equal(written.Id, read.Id);
        Assert.Equal(written.Generation, read.Generation);
        Assert.Equal(target, read.TargetPath);
        Assert.Equal(RecoveryReason.ExternalConflict, read.Reason);
        Assert.Equal(written.ContentDigest, read.ContentDigest);
    }

    [Fact]
    public void MalformedRecordIsIgnoredAndNeverDeleted()
    {
        using var dir = new TempDir();
        var malformed = dir["buffer-malformed.clio-recovery"];
        byte[] bytes = [0x00, 0xFF, 0x01, 0x7F];
        File.WriteAllBytes(malformed, bytes);

        var journal = new CrashRecoveryJournal(dir.Path);
        Assert.Empty(journal.ValidRecords());
        journal.Checkpoint(Record("A", 1, RecoveryReason.DirtyBuffer, "x"));
        journal.Clear(Doc("A"), 5);
        Assert.Equal(bytes, File.ReadAllBytes(malformed));
    }

    [Fact]
    public void TamperedPayloadFailsTheDigestAndIsKept()
    {
        using var dir = new TempDir();
        var journal = new CrashRecoveryJournal(dir.Path);
        var path = journal.Checkpoint(Record("A", 1, RecoveryReason.SaveFailed, "original"));
        var tampered = File.ReadAllText(path).Replace(Convert.ToBase64String("original"u8), Convert.ToBase64String("tampered"u8));
        File.WriteAllText(path, tampered);

        Assert.Empty(journal.ValidRecords());
        Assert.True(File.Exists(path));
    }

    [Fact]
    public void CheckpointIsIdempotentForTheSameRecord()
    {
        using var dir = new TempDir();
        var journal = new CrashRecoveryJournal(dir.Path);
        var record = Record("A", 1, RecoveryReason.AtomicCandidate, "once");
        Assert.Equal(journal.Checkpoint(record), journal.Checkpoint(record));
        Assert.Single(journal.ValidRecords());
    }

    [Fact]
    public void RemoveDeletesOnlyThatRecord()
    {
        using var dir = new TempDir();
        var journal = new CrashRecoveryJournal(dir.Path);
        var keep = Record("A", 1, RecoveryReason.SaveFailed, "keep");
        var drop = Record("A", 2, RecoveryReason.SaveFailed, "drop");
        journal.Checkpoint(keep);
        journal.Checkpoint(drop);
        journal.Remove(drop.Id);
        Assert.Equal(["saveFailed:1:keep"], Remaining(journal));
    }

    [Fact]
    public void OversizedRecordIsRefused()
    {
        using var dir = new TempDir();
        var journal = new CrashRecoveryJournal(dir.Path);
        var big = new byte[CrashRecoveryJournal.MaximumRecordByteCount + 1];
        Assert.Throws<ClioException>(() => journal.Checkpoint(Record("A", 1, RecoveryReason.DirtyBuffer, "") with { Data = big }));
        Assert.Empty(Directory.GetFileSystemEntries(dir.Path));
    }

    [Fact]
    public void WriteFailureIsReportedAndKeptUntilASuccess()
    {
        using var dir = new TempDir();
        var blocker = dir["not-a-folder"];
        File.WriteAllText(blocker, "file where the journal folder should be");
        var journal = new CrashRecoveryJournal(blocker);
        var seen = new List<string?>();
        journal.StatusChanged += (_, message) => seen.Add(message);

        journal.Schedule(new CrashRecoverySnapshot(Doc("A"), new BufferGeneration(Doc("A"), 1), "a.md", null, RecoveryReason.DirtyBuffer, "text"));
        journal.Flush();

        Assert.NotNull(journal.LastError(Doc("A")));
        Assert.NotNull(Assert.Single(seen));
        Assert.Throws<IOException>(() => journal.Checkpoint(Record("A", 2, RecoveryReason.DirtyBuffer, "x")));

        File.Delete(blocker);
        journal.Checkpoint(Record("A", 3, RecoveryReason.DirtyBuffer, "ok"));
        Assert.Null(journal.LastError(Doc("A")));
    }

    [Fact]
    public async Task ScheduledSnapshotIsWrittenWithoutAnExplicitFlush()
    {
        using var dir = new TempDir();
        var journal = new CrashRecoveryJournal(dir.Path);
        journal.Schedule(new CrashRecoverySnapshot(Doc("A"), new BufferGeneration(Doc("A"), 1), "a.md", null, RecoveryReason.DirtyBuffer, "typed"));
        for (var i = 0; i < 100 && journal.ValidRecords().Count == 0; i++) await Task.Delay(20);
        Assert.Equal(["dirtyBuffer:1:typed"], Remaining(journal));
    }

    [Fact]
    public void ReservedAndLongTargetNamesAreStoredVerbatimInsideTheRecord()
    {
        using var dir = new TempDir();
        var journal = new CrashRecoveryJournal(dir.Path);
        var name = "CON." + new string('x', 200);
        journal.Checkpoint(CrashRecoveryRecord.Create(Doc("A"), new BufferGeneration(Doc("A"), 1), name, null, RecoveryReason.SaveFailed, "x"u8.ToArray()));
        Assert.Equal(name, Assert.Single(journal.ValidRecords()).Filename);
        // The record file name is built from ids only, so a hostile document name can never break the path.
        Assert.DoesNotContain("CON", Path.GetFileName(Directory.GetFiles(dir.Path).Single()));
    }
}
