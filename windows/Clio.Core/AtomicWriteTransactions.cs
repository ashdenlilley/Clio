using System.Text.Json;

namespace Clio.Core;

public enum AtomicWriteOperation { Create, Replace }

/// <summary>Points where a writer can be killed. Test seam: a hook that throws simulates a crash and leaves every artifact in place.</summary>
public enum AtomicWritePhase { ManifestSynced, CandidateSynced, Swapped, ParentSynced }

/// <summary>
/// Written and flushed before the first byte of a save, so a crash at any point leaves enough on disk to
/// tell what was being installed. Windows keeps the old file at <see cref="DisplacedPath"/> after the swap
/// (the ReplaceFileW backup), the counterpart of macOS leaving it in the temp slot after a rename swap.
/// </summary>
public sealed record AtomicWriteManifest(
    int SchemaVersion,
    Guid Id,
    AtomicWriteOperation Operation,
    string DestinationPath,
    string TemporaryPath,
    string DisplacedPath,
    long CandidateByteCount,
    string CandidateDigest,
    DiskRevision? ExpectedRevision,
    DateTimeOffset CreatedAt)
{
    public const int CurrentSchema = 1;
}

public sealed record AtomicWriteTransaction(AtomicWriteManifest Manifest, string ManifestPath);

/// <summary>Contract: spec/vectors/atomic-write-recovery.json.</summary>
public static class AtomicWriteTransactions
{
    public const string ManifestPrefix = ".clio-transaction-";
    public const string ManifestSuffix = ".json";
    public const string TemporaryPrefix = AtomicFile.TempPrefix;
    public const string DisplacedPrefix = ".clio-displaced-";
    public const long MaximumManifestByteCount = 1024 * 1024;
    public const long MaximumRecoverableByteCount = 4L * 50 * 1024 * 1024;

    public static AtomicWriteTransaction Begin(ReadOnlySpan<byte> contents, string destination, AtomicWriteOperation operation, DiskRevision? expected)
    {
        var full = Path.GetFullPath(destination);
        var parent = Path.GetDirectoryName(full) ?? throw new LinkException(destination);
        if (PathSafety.IsLink(full) || PathSafety.IsLink(parent)) throw new LinkException(destination);

        var id = Guid.NewGuid();
        var name = id.ToString("D");
        var manifest = new AtomicWriteManifest(
            AtomicWriteManifest.CurrentSchema, id, operation, full,
            Path.Combine(parent, TemporaryPrefix + name), Path.Combine(parent, DisplacedPrefix + name),
            contents.Length, DiskRevision.Digest(contents), expected, DateTimeOffset.UtcNow);
        var manifestPath = Path.Combine(parent, ManifestPrefix + name + ManifestSuffix);

        using (var stream = new FileStream(manifestPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            stream.Write(JsonSerializer.SerializeToUtf8Bytes(manifest, CrashRecoveryJournal.Json));
            stream.Flush(flushToDisk: true);
        }
        return new AtomicWriteTransaction(manifest, manifestPath);
    }

    /// <summary>
    /// Removes the transaction's leftovers. The manifest goes last and only when nothing it describes is
    /// left, so a leftover (locked by a scanner, say) is still recoverable on the next launch.
    /// </summary>
    public static void Finish(AtomicWriteTransaction transaction, bool removeTemporary = true)
    {
        var m = transaction.Manifest;
        var clean = true;
        if (removeTemporary) foreach (var p in new[] { m.TemporaryPath, m.DisplacedPath }) clean &= TryDelete(p);
        if (clean) TryDelete(transaction.ManifestPath);
    }

    /// <summary>
    /// Settles transactions a crash left behind under <paramref name="rootPath"/>, copying every byte sequence
    /// that could otherwise be lost into <paramref name="journal"/> first. Anything unrecognised, or that
    /// points outside the root or through a link, is left untouched. Returns the number of journal records written.
    /// </summary>
    public static int RecoverInterrupted(string rootPath, CrashRecoveryJournal journal, bool recursive = true)
    {
        var root = PathSafety.Normalize(rootPath);
        var recovered = 0;
        foreach (var manifestPath in PathSafety.EnumerateManifests(root, ManifestPrefix + "*" + ManifestSuffix, recursive))
        {
            if (ValidManifest(manifestPath, root) is not { } m) continue;
            var limit = Math.Max(m.CandidateByteCount, m.ExpectedRevision?.ByteCount ?? 0);
            if (limit < 0 || limit > MaximumRecoverableByteCount) continue;

            var tempPresent = !PathSafety.IsAbsent(m.TemporaryPath);
            var displacedPresent = !PathSafety.IsAbsent(m.DisplacedPath);
            var slotPath = tempPresent || !displacedPresent ? m.TemporaryPath : m.DisplacedPath;
            var slotAbsent = !tempPresent && !displacedPresent;

            var destination = Snapshot(m.DestinationPath, root, limit);
            var slot = Snapshot(slotPath, root, limit);
            var destinationIsCandidate = destination is { } d && IsCandidate(d.Revision, m);
            var slotIsCandidate = slot is { } s && IsCandidate(s.Revision, m);
            var destinationIsExpected = m.ExpectedRevision is { } expected
                ? destination is { } d2 && Same(d2.Revision, expected)
                : PathSafety.IsAbsent(m.DestinationPath);
            var slotIsExpected = m.ExpectedRevision is { } e && slot is { } s2 && Same(s2.Revision, e);

            if (slot is { } sl && (slotIsCandidate || slotIsExpected))
            {
                Checkpoint(journal, m, sl.Data, slotIsCandidate ? RecoveryReason.AtomicCandidate : RecoveryReason.AtomicDisplaced);
                recovered++;
            }
            // A failed swap can leave the old file in the backup slot while the candidate is still staged.
            if (tempPresent && displacedPresent && m.ExpectedRevision is { } want
                && Snapshot(m.DisplacedPath, root, limit) is { } backup && Same(backup.Revision, want))
            {
                Checkpoint(journal, m, backup.Data, RecoveryReason.AtomicDisplaced);
                recovered++;
            }
            if (destinationIsCandidate && slotAbsent)
            {
                Checkpoint(journal, m, destination!.Value.Data, RecoveryReason.AtomicCandidate);
                recovered++;
            }

            var preCommit = slotIsCandidate && destinationIsExpected;
            var installed = destinationIsCandidate && (slotAbsent || slotIsExpected);
            var manifestOnly = slotAbsent && destinationIsExpected;
            if (preCommit || installed || manifestOnly)
            {
                foreach (var p in new[] { m.TemporaryPath, m.DisplacedPath })
                    if (PathSafety.IsSafeRegularFile(p, root)) File.Delete(p);
                File.Delete(manifestPath);
            }
        }
        return recovered;
    }

    // ---- internals ------------------------------------------------------------------------------

    private static bool Same(DiskRevision a, DiskRevision b) => a.ByteCount == b.ByteCount && a.ContentDigest == b.ContentDigest;

    private static bool IsCandidate(DiskRevision r, AtomicWriteManifest m) => r.ByteCount == m.CandidateByteCount && r.ContentDigest == m.CandidateDigest;

    private static void Checkpoint(CrashRecoveryJournal journal, AtomicWriteManifest m, byte[] data, RecoveryReason reason) =>
        journal.Checkpoint(CrashRecoveryRecord.Create(
            m.Id, new BufferGeneration(m.Id, 0), Path.GetFileName(m.DestinationPath), m.DestinationPath, reason, data, m.CreatedAt));

    private static (byte[] Data, DiskRevision Revision)? Snapshot(string path, string root, long maximumByteCount)
    {
        try
        {
            if (!PathSafety.IsSafeRegularFile(path, root)) return null;
            var info = new FileInfo(path);
            if (info.Length > maximumByteCount) return null;
            var data = File.ReadAllBytes(path);
            if (data.LongLength != info.Length) return null; // changed while reading
            return (data, new DiskRevision(data.LongLength, info.LastWriteTimeUtc, DiskRevision.Digest(data)));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static AtomicWriteManifest? ValidManifest(string manifestPath, string root)
    {
        try
        {
            if (!PathSafety.IsSafeRegularFile(manifestPath, root) || new FileInfo(manifestPath).Length > MaximumManifestByteCount) return null;
            var m = JsonSerializer.Deserialize<AtomicWriteManifest>(File.ReadAllBytes(manifestPath), CrashRecoveryJournal.Json);
            if (m is null || m.SchemaVersion != AtomicWriteManifest.CurrentSchema) return null;
            var paths = new[] { m.DestinationPath, m.TemporaryPath, m.DisplacedPath };
            if (paths.Any(p => string.IsNullOrEmpty(p) || !Path.IsPathFullyQualified(p) || !PathSafety.IsContained(p, root))) return null;
            var id = m.Id.ToString("D");
            return PathSafety.SameDirectory(m.DestinationPath, m.TemporaryPath)
                && PathSafety.SameDirectory(m.DestinationPath, m.DisplacedPath)
                && PathSafety.SameDirectory(manifestPath, m.DestinationPath)
                && Path.GetFileName(manifestPath) == ManifestPrefix + id + ManifestSuffix
                && Path.GetFileName(m.TemporaryPath) == TemporaryPrefix + id
                && Path.GetFileName(m.DisplacedPath) == DisplacedPrefix + id
                ? m : null;
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    private static bool TryDelete(string path)
    {
        try
        {
            if (File.Exists(path) && !PathSafety.IsLink(path)) File.Delete(path);
            return !File.Exists(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
