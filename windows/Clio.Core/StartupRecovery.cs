namespace Clio.Core;

/// <param name="AtomicWritesRecovered">Interrupted atomic saves whose bytes were journaled.</param>
/// <param name="MovesRecovered">Interrupted moves whose source bytes were journaled.</param>
/// <param name="RecoveredBuffers">Journal records preserved as recovery copies (or dropped because the file already holds them).</param>
/// <param name="PendingBuffers">Journal records that could not be preserved yet; they stay in the journal untouched.</param>
public sealed record StartupRecoveryReport(int AtomicWritesRecovered, int MovesRecovered, int RecoveredBuffers, int PendingBuffers);

/// <summary>
/// What runs once at launch (macOS: <c>Workspace.init</c> transaction recovery, then
/// <c>AppState.recoverPendingCrashBuffers</c>). Order matters: interrupted writes and moves settle first, because
/// they journal the bytes that the buffer sweep then reconciles.
/// </summary>
public static class StartupRecovery
{
    /// <param name="authorizedRoots">Workspace roots Clio may repair inside. Manifests outside them are ignored.</param>
    public static StartupRecoveryReport Run(IReadOnlyList<string> authorizedRoots, CrashRecoveryJournal journal, RecoveryStore recovery)
    {
        var atomic = 0;
        foreach (var root in authorizedRoots.Where(Directory.Exists))
            atomic += AtomicWriteTransactions.RecoverInterrupted(root, journal);
        var moves = InterruptedMoveTransactions.Recover(authorizedRoots.Where(Directory.Exists), journal);

        var (recovered, pending) = SweepJournal(authorizedRoots, journal, recovery);
        try { recovery.PruneExpired(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return new StartupRecoveryReport(atomic, moves, recovered, pending);
    }

    /// <summary>
    /// Every valid journal record is either already on disk (its target holds the same bytes: the record is
    /// redundant and removed) or preserved as a recovery copy, then removed. A record that cannot be preserved
    /// stays, and counts as pending. Nothing is ever restored over an existing file.
    /// </summary>
    public static (int Recovered, int Pending) SweepJournal(IReadOnlyList<string> authorizedRoots, CrashRecoveryJournal journal, RecoveryStore recovery)
    {
        var recovered = 0;
        var pending = 0;
        foreach (var record in journal.ValidRecords())
        {
            if (AlreadyCanonical(record, authorizedRoots))
            {
                journal.Remove(record.Id);
                continue;
            }
            try
            {
                recovery.Preserve(record.DocumentId, record.Filename, record.Data, record.CreatedAt);
                journal.Remove(record.Id);
                recovered++;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ClioException)
            {
                pending++;
            }
        }
        return (recovered, pending);
    }

    /// <summary>The record's target is an authorized, regular, non-link file whose bytes are exactly the record's.</summary>
    private static bool AlreadyCanonical(CrashRecoveryRecord record, IReadOnlyList<string> roots)
    {
        if (record.TargetPath is not { } target) return false;
        try
        {
            if (!roots.Any(r => PathSafety.IsContained(target, r) && !PathSafety.HasLinkBetween(target, r))) return false;
            if (!File.Exists(target) || PathSafety.IsLink(target)) return false;
            var revision = DocumentIO.CurrentRevision(target);
            return revision.ByteCount == record.Data.LongLength && revision.ContentDigest == record.ContentDigest;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
