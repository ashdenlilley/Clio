using System.Text.Json;

namespace Clio.Core;

public sealed record InterruptedMoveManifest(
    int SchemaVersion,
    Guid Id,
    Guid DocumentId,
    BufferGeneration Generation,
    string SourceRoot,
    string DestinationRoot,
    string SourcePath,
    string DestinationPath,
    string QuarantinePath,
    DiskRevision SourceRevision,
    DiskRevision? DestinationRevision,
    long CandidateByteCount,
    string CandidateDigest,
    DateTimeOffset CreatedAt)
{
    public const int CurrentSchema = 1;
}

public sealed record InterruptedMoveTransaction(InterruptedMoveManifest Manifest, string ManifestPath);

/// <summary>
/// A move writes its manifest, installs the candidate at the destination, then hides the source by renaming
/// it to a quarantine name (never deleting it). A crash anywhere in between is settled by <see cref="Recover"/>,
/// which journals the source bytes before removing anything. Contract: spec/vectors/move-recovery.json.
/// </summary>
public static class InterruptedMoveTransactions
{
    public const string ManifestPrefix = ".clio-move-transaction-";
    public const string ManifestSuffix = ".json";
    public const string QuarantinePrefix = ".clio-move-source-";
    public const long MaximumManifestByteCount = 1024 * 1024;

    public static InterruptedMoveTransaction Begin(
        Guid documentId, BufferGeneration generation, string sourceRoot, string destinationRoot,
        string sourcePath, string destinationPath, DiskRevision sourceRevision, DiskRevision? destinationRevision,
        ReadOnlySpan<byte> candidate)
    {
        var id = Guid.NewGuid();
        var source = Path.GetFullPath(sourcePath);
        var destination = Path.GetFullPath(destinationPath);
        var srcRoot = PathSafety.Normalize(sourceRoot);
        var dstRoot = PathSafety.Normalize(destinationRoot);
        if (!PathSafety.IsContained(source, srcRoot) || !PathSafety.IsContained(destination, dstRoot)
            || PathSafety.HasLinkBetween(source, srcRoot) || PathSafety.HasLinkBetween(destination, dstRoot)
            || PathSafety.IsLink(source) || PathSafety.IsLink(destination))
            throw new LinkException(sourcePath);

        var parent = Path.GetDirectoryName(source)!;
        var name = id.ToString("D");
        var manifest = new InterruptedMoveManifest(
            InterruptedMoveManifest.CurrentSchema, id, documentId, generation, srcRoot, dstRoot, source, destination,
            Path.Combine(parent, QuarantinePrefix + name), sourceRevision, destinationRevision,
            candidate.Length, DiskRevision.Digest(candidate), DateTimeOffset.UtcNow);
        var manifestPath = Path.Combine(parent, ManifestPrefix + name + ManifestSuffix);
        using (var stream = new FileStream(manifestPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            stream.Write(JsonSerializer.SerializeToUtf8Bytes(manifest, CrashRecoveryJournal.Json));
            stream.Flush(flushToDisk: true);
        }
        return new InterruptedMoveTransaction(manifest, manifestPath);
    }

    public static void Finish(InterruptedMoveTransaction transaction, bool removeQuarantine)
    {
        if (removeQuarantine && File.Exists(transaction.Manifest.QuarantinePath)) File.Delete(transaction.Manifest.QuarantinePath);
        if (File.Exists(transaction.ManifestPath)) File.Delete(transaction.ManifestPath);
    }

    /// <summary>Hides the source without deleting it. Fails (leaving the source in place) if the file is open elsewhere or the name is taken.</summary>
    public static void QuarantineSource(InterruptedMoveTransaction transaction) =>
        File.Move(transaction.Manifest.SourcePath, transaction.Manifest.QuarantinePath, overwrite: false);

    public static DiskRevision SourceRevision(InterruptedMoveTransaction transaction) =>
        DocumentIO.CurrentRevision(transaction.Manifest.QuarantinePath);

    /// <summary>Backs out a move whose destination was never touched. Returns false if the destination changed or the source is gone.</summary>
    public static bool AbortIfDestinationUnchanged(InterruptedMoveTransaction transaction)
    {
        var m = transaction.Manifest;
        if (!File.Exists(m.SourcePath) || File.Exists(m.QuarantinePath)) return false;
        DiskRevision? destination = null;
        try { destination = DocumentIO.CurrentRevision(m.DestinationPath); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        var unchanged = m.DestinationRevision is { } expected ? destination is { } d && Same(d, expected) : destination is null;
        if (!unchanged) return false;
        Finish(transaction, removeQuarantine: false);
        return true;
    }

    public static int Recover(string root, CrashRecoveryJournal journal) => Recover([root], journal);

    /// <summary>
    /// Settles manifests found under any of <paramref name="authorizedRoots"/>. A cross-workspace manifest is acted
    /// on only when both its roots are in that set. Returns the number of sources moved into the journal.
    /// </summary>
    public static int Recover(IEnumerable<string> authorizedRoots, CrashRecoveryJournal journal)
    {
        var roots = authorizedRoots.Select(PathSafety.Normalize).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var recovered = 0;
        var visited = new HashSet<Guid>();
        foreach (var root in roots)
        {
            foreach (var manifestPath in PathSafety.EnumerateManifests(root, ManifestPrefix + "*" + ManifestSuffix, recursive: true))
            {
                if (ValidManifest(manifestPath, root, roots) is not { } m || !visited.Add(m.Id)) continue;
                var transaction = new InterruptedMoveTransaction(m, manifestPath);
                var quarantine = Snapshot(m.QuarantinePath, root);

                // Act on a visible source only when the destination lies in an authorized root too.
                if (quarantine is null && Snapshot(m.SourcePath, root) is not null
                    && Snapshot(m.DestinationPath, m.DestinationRoot) is { } destination)
                {
                    if (m.DestinationRevision is { } expected && Same(destination.Revision, expected))
                    {
                        File.Delete(manifestPath); // the move never started
                        continue;
                    }
                    if (destination.Revision.ByteCount == m.CandidateByteCount && destination.Revision.ContentDigest == m.CandidateDigest)
                    {
                        try { QuarantineSource(transaction); }
                        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; } // source open elsewhere: retry next launch
                        quarantine = Snapshot(m.QuarantinePath, root);
                    }
                }

                if (quarantine is null && Snapshot(m.SourcePath, root) is not null
                    && m.DestinationRevision is null && PathSafety.IsAbsent(m.DestinationPath))
                {
                    File.Delete(manifestPath);
                    continue;
                }

                if (quarantine is { } q)
                {
                    journal.Checkpoint(CrashRecoveryRecord.Create(
                        m.DocumentId, m.Generation, Path.GetFileName(m.SourcePath), m.SourcePath,
                        RecoveryReason.InterruptedMove, q.Data, m.CreatedAt));
                    File.Delete(m.QuarantinePath);
                    File.Delete(manifestPath);
                    recovered++;
                    continue;
                }

                if (PathSafety.IsAbsent(m.SourcePath) && PathSafety.IsAbsent(m.QuarantinePath)
                    && Snapshot(m.DestinationPath, m.DestinationRoot) is { } landed
                    && landed.Revision.ByteCount == m.CandidateByteCount && landed.Revision.ContentDigest == m.CandidateDigest)
                    File.Delete(manifestPath);
            }
        }
        return recovered;
    }

    // ---- internals ------------------------------------------------------------------------------

    private static bool Same(DiskRevision a, DiskRevision b) => a.ByteCount == b.ByteCount && a.ContentDigest == b.ContentDigest;

    private static (byte[] Data, DiskRevision Revision)? Snapshot(string path, string root)
    {
        try
        {
            if (!PathSafety.IsSafeRegularFile(path, root)) return null;
            var info = new FileInfo(path);
            if (info.Length > 50L * 1024 * 1024) return null;
            var data = File.ReadAllBytes(path);
            return data.LongLength != info.Length ? null : (data, new DiskRevision(data.LongLength, info.LastWriteTimeUtc, DiskRevision.Digest(data)));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static InterruptedMoveManifest? ValidManifest(string manifestPath, string root, IReadOnlyList<string> authorizedRoots)
    {
        try
        {
            if (!PathSafety.IsSafeRegularFile(manifestPath, root) || new FileInfo(manifestPath).Length > MaximumManifestByteCount) return null;
            var m = JsonSerializer.Deserialize<InterruptedMoveManifest>(File.ReadAllBytes(manifestPath), CrashRecoveryJournal.Json);
            if (m is null || m.SchemaVersion != InterruptedMoveManifest.CurrentSchema) return null;
            var paths = new[] { m.SourceRoot, m.DestinationRoot, m.SourcePath, m.DestinationPath, m.QuarantinePath };
            if (paths.Any(p => string.IsNullOrEmpty(p) || !Path.IsPathFullyQualified(p))) return null;
            var id = m.Id.ToString("D");
            return PathSafety.Normalize(m.SourceRoot).Equals(root, StringComparison.OrdinalIgnoreCase)
                && PathSafety.IsContained(m.SourcePath, root)
                && PathSafety.IsContained(m.QuarantinePath, root)
                && PathSafety.SameDirectory(m.SourcePath, m.QuarantinePath)
                && PathSafety.SameDirectory(manifestPath, m.SourcePath)
                && Path.GetFileName(manifestPath) == ManifestPrefix + id + ManifestSuffix
                && Path.GetFileName(m.QuarantinePath) == QuarantinePrefix + id
                && IsAuthorizedRoot(m.DestinationRoot, authorizedRoots)
                && PathSafety.IsContained(m.DestinationPath, m.DestinationRoot)
                ? m : null;
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    private static bool IsAuthorizedRoot(string candidate, IReadOnlyList<string> roots)
    {
        var c = PathSafety.Normalize(candidate);
        if (!Directory.Exists(c) || PathSafety.IsLink(c)) return false;
        return roots.Any(r => c.Equals(r, StringComparison.OrdinalIgnoreCase)
            || c.StartsWith(r + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));
    }
}
