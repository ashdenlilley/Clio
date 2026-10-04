using System.Runtime.CompilerServices;

namespace Clio.Core;

public sealed class ExternalConflictException(DocumentConflict conflict)
    : ClioException("The file changed outside Clio. Choose which version to keep.")
{
    public DocumentConflict Conflict { get; } = conflict;
}

public sealed class DocumentDeletedException(string path)
    : ClioException($"{Path.GetFileName(path)} was deleted or moved outside Clio. Its text is kept open; save it to a new location to restore it.")
{
    public string DeletedPath { get; } = path;
}

public sealed class DetachedDocumentException(string previousPath)
    : ClioException($"{Path.GetFileName(previousPath)} no longer exists. Restore or Save As to write it again.")
{
    public string PreviousPath { get; } = previousPath;
}

public sealed class UnbackedDocumentException() : ClioException("This document has no file yet. Choose where to save it.");

public sealed class FileOutsideWorkspaceException(string path)
    : ClioException($"{Path.GetFileName(path)} is outside the workspace Clio is allowed to write to.");

public enum ResolutionFailure { NoConflict, ConflictChanged }

public sealed class ConflictResolutionException(ResolutionFailure failure)
    : ClioException(failure == ResolutionFailure.NoConflict
        ? "This document no longer has an external-edit conflict."
        : "The outside version changed again. Review the refreshed conflict before continuing.")
{
    public ResolutionFailure Failure { get; } = failure;
}

public enum ReconcileResult { Unchanged, Reloaded, ConflictRaised, Deleted }

/// <summary>
/// UI-free document I/O policy (macOS <c>Workspace.save</c>, <c>reconcileExternalChange</c> and
/// <c>ConflictResolver</c>). Saves never overwrite bytes the user has not seen: a disk revision that differs from the
/// one the buffer was loaded from raises a conflict, and resolving it re-checks the disk before every write.
/// Dirty text is journaled before each write. Decisions are shared through <c>spec/vectors/external-change.json</c>.
/// </summary>
public sealed class DocumentService(
    RecoveryStore recovery,
    CrashRecoveryJournal journal,
    Func<string, FileSnapshot>? snapshot = null,
    Func<DateTimeOffset>? now = null)
{
    private static readonly TimeSpan SelfWriteWindow = TimeSpan.FromSeconds(5);

    private readonly Func<string, FileSnapshot> _read = snapshot ?? FileSnapshots.Read;
    private readonly Func<DateTimeOffset> _now = now ?? (() => DateTimeOffset.UtcNow);
    private readonly ConditionalWeakTable<DocumentSession, object> _gates = new();
    private readonly Dictionary<string, (DiskRevision Revision, DateTimeOffset Expires)> _selfWrites = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _selfWriteLock = new();

    private object Gate(DocumentSession session) => _gates.GetValue(session, _ => new object());

    // ---- journal --------------------------------------------------------------------------------

    /// <summary>Queues the buffer's newest text for the crash journal. Cheap: encoding happens when the journal drains.</summary>
    public void ScheduleCrashRecovery(DocumentSession session)
    {
        var s = session.Snapshot();
        if (!s.IsDirty) return;
        journal.Schedule(new CrashRecoverySnapshot(s.DocumentId, new BufferGeneration(s.DocumentId, s.Revision), s.Filename, s.Path ?? s.PreviousPath,
            RecoveryReason.DirtyBuffer, s.Text));
    }

    private void Checkpoint(DocumentSnapshot s, RecoveryReason reason) =>
        journal.Checkpoint(CrashRecoveryRecord.Create(s.DocumentId, new BufferGeneration(s.DocumentId, s.Revision), s.Filename, s.Path ?? s.PreviousPath, reason, s.Encode()));

    // ---- save -----------------------------------------------------------------------------------

    /// <summary>
    /// Writes the dirty buffer to its file and returns the path, or returns the current path untouched when the
    /// buffer is clean. Throws <see cref="ExternalConflictException"/> instead of overwriting an outside edit and
    /// <see cref="DocumentDeletedException"/> instead of resurrecting a deleted file.
    /// </summary>
    public string? Save(DocumentSession session)
    {
        lock (Gate(session))
        {
            var snap = session.Snapshot();
            if (!snap.IsDirty) return snap.Path;

            Checkpoint(snap, RecoveryReason.DirtyBuffer);
            if (session.Conflict is { } pending) throw new ExternalConflictException(pending);
            if (snap.Path is null)
            {
                if (snap.PreviousPath is { } previous) throw new DetachedDocumentException(previous);
                throw new UnbackedDocumentException();
            }

            var path = snap.Path;
            if (session.WorkspaceRoot is { } root && !PathSafety.IsContained(path, root)) throw new FileOutsideWorkspaceException(path);
            if (!File.Exists(path))
            {
                session.MarkUnbacked();
                throw new DocumentDeletedException(path);
            }

            var current = Read(path);
            if (snap.ExpectedDiskRevision is { } expected && !Same(current.Revision, expected))
                throw Raise(session, snap, current);

            var data = snap.Encode();
            // The swap is only as safe as this comparison: re-check right before replacing.
            if (!StillMatches(path, current.Revision)) throw Raise(session, snap, Read(path));
            AtomicFile.Write(path, data, current.Revision);

            var revision = DocumentIO.Revision(path, data);
            RecordSelfWrite(path, revision);
            session.DidWrite(snap, path, revision);
            journal.Clear(snap.DocumentId, snap.Revision);
            return path;
        }
    }

    // ---- external changes -----------------------------------------------------------------------

    /// <summary>
    /// Applies an outside change only when the buffer is clean. A dirty buffer enters a conflict and autosave stops
    /// until the user chooses a side. A file that disappeared detaches the buffer but keeps its text.
    /// </summary>
    public ReconcileResult ReconcileExternalChange(DocumentSession session)
    {
        lock (Gate(session))
        {
            var snap = session.Snapshot();
            if (snap.Path is not { } path) return ReconcileResult.Unchanged;
            if (!File.Exists(path))
            {
                if (session.Conflict is { } conflict) throw new ExternalConflictException(conflict);
                session.MarkUnbacked();
                return ReconcileResult.Deleted;
            }

            var disk = Read(path);
            if (ConsumeSelfWrite(path, disk.Revision)) return ReconcileResult.Unchanged;
            if (snap.ExpectedDiskRevision is { } expected && Same(expected, disk.Revision)) return ReconcileResult.Unchanged;

            if (snap.IsDirty)
            {
                Checkpoint(snap, RecoveryReason.ExternalConflict);
                session.RegisterConflict(MakeConflict(snap, disk));
                return ReconcileResult.ConflictRaised;
            }
            session.ApplyExternal(DocumentIO.Decode(path, disk.Data));
            return ReconcileResult.Reloaded;
        }
    }

    // ---- conflict resolution --------------------------------------------------------------------

    /// <summary>
    /// Settles a conflict. Every write re-reads the disk first and refuses (with
    /// <see cref="ResolutionFailure.ConflictChanged"/>) when the outside text changed again, so the user never
    /// resolves a version they have not reviewed. Returns the recovery copy of the side that lost, if any.
    /// </summary>
    public RecoveryReceipt? Resolve(ConflictChoice choice, DocumentSession session)
    {
        lock (Gate(session))
        {
            if (session.Conflict is not { External.Revision: { } expectedExternal } conflict)
                throw new ConflictResolutionException(ResolutionFailure.NoConflict);

            var generation = new BufferGeneration(session.Id, session.Revision);
            var current = Validated(session, conflict.Id, generation, expectedExternal);

            // A rare double interleaving can displace more than one outside revision. Preserve those first.
            foreach (var side in conflict.AdditionalExternalVersions ?? [])
            {
                PreserveAndRelease(side, session.Id, conflict.Path);
                current = Validated(session, conflict.Id, generation, expectedExternal);
            }

            var snap = session.Snapshot();
            RecoveryReceipt? receipt = null;
            switch (choice)
            {
                case ConflictChoice.KeepClio:
                    receipt = recovery.Preserve(session.Id, snap.Filename, current.Data, current.Revision.Modified);
                    current = Validated(session, conflict.Id, generation, expectedExternal);
                    ReplaceAfterConflict(session, snap, conflict, current);
                    break;

                case ConflictChoice.LoadExternal:
                    receipt = recovery.Preserve(session.Id, snap.Filename, snap.Encode());
                    current = Validated(session, conflict.Id, generation, expectedExternal);
                    session.ApplyExternal(DocumentIO.Decode(conflict.Path, current.Data));
                    break;

                case ConflictChoice.KeepBoth:
                    SaveConflictCopy(session, snap, conflict, current);
                    break;
            }
            Release(conflict.External);
            return receipt;
        }
    }

    /// <summary>
    /// The file is confirmed gone: journal the buffer, keep every outside version a conflict still held as a
    /// recovery copy, and detach the buffer. Throws <see cref="ResolutionFailure.ConflictChanged"/> when the file
    /// reappeared meanwhile.
    /// </summary>
    public void DetachAfterExternalDeletion(DocumentSession session)
    {
        lock (Gate(session))
        {
            var snap = session.Snapshot();
            Checkpoint(snap, RecoveryReason.ExternalDeletion);
            var path = session.Conflict?.Path ?? snap.Path;

            var preserved = new HashSet<string>(StringComparer.Ordinal);
            var sides = session.Conflict is { } conflict ? (conflict.AdditionalExternalVersions ?? []).Append(conflict.External).ToList() : [];
            foreach (var side in sides)
            {
                var digest = side.Revision?.ContentDigest ?? DiskRevision.Digest(side.Data);
                if (!preserved.Add(digest)) continue;
                PreserveAndRelease(side, session.Id, path ?? snap.Filename);
            }

            if (path is not null && File.Exists(path))
            {
                ReconcileExternalChange(session);
                throw new ConflictResolutionException(ResolutionFailure.ConflictChanged);
            }
            session.MarkUnbacked();
        }
    }

    private void ReplaceAfterConflict(DocumentSession session, DocumentSnapshot snap, DocumentConflict conflict, FileSnapshot current)
    {
        var path = conflict.Path;
        Checkpoint(snap, RecoveryReason.ExternalConflict);
        if (!File.Exists(path))
        {
            session.MarkUnbacked();
            throw new DocumentDeletedException(path);
        }
        var data = snap.Encode();
        // Write only over the outside version the user reviewed.
        if (!StillMatches(path, current.Revision)) throw ChangedAgain(session, snap);
        AtomicFile.Write(path, data, current.Revision);
        var revision = DocumentIO.Revision(path, data);
        RecordSelfWrite(path, revision);
        session.DidWrite(snap, path, revision);
        journal.Clear(snap.DocumentId, snap.Revision);
    }

    /// <summary>Writes the buffer to a collision-safe sibling and attaches the buffer to it; the original keeps the outside text.</summary>
    private void SaveConflictCopy(DocumentSession session, DocumentSnapshot snap, DocumentConflict conflict, FileSnapshot current)
    {
        Checkpoint(snap, RecoveryReason.ExternalConflict);
        if (!File.Exists(conflict.Path))
        {
            session.MarkUnbacked();
            throw new DocumentDeletedException(conflict.Path);
        }
        if (!StillMatches(conflict.Path, current.Revision)) throw ChangedAgain(session, snap);

        var folder = session.WorkspaceRoot ?? Path.GetDirectoryName(conflict.Path)!;
        var data = snap.Encode();
        var name = FileNames.Safe(Path.GetFileName(conflict.Path));
        string destination;
        for (var attempt = 0; ; attempt++)
        {
            name = FileNames.Available(name, n => File.Exists(Path.Combine(folder, n)) || Directory.Exists(Path.Combine(folder, n)));
            destination = Path.Combine(folder, name);
            if (AtomicFile.TryCreate(destination, data)) break;
            if (attempt >= FileNames.MaximumCollisionAttempts) throw new ClioException($"No available file name for {name}.");
        }
        var revision = DocumentIO.Revision(destination, data);
        RecordSelfWrite(destination, revision);
        session.DidWrite(snap, destination, revision);
        journal.Clear(snap.DocumentId, snap.Revision);
    }

    private FileSnapshot Validated(DocumentSession session, Guid conflictId, BufferGeneration generation, DiskRevision expectedExternal)
    {
        var path = session.Conflict?.Path ?? session.Path ?? throw new ConflictResolutionException(ResolutionFailure.ConflictChanged);
        if (!File.Exists(path))
        {
            session.MarkUnbacked();
            throw new DocumentDeletedException(path);
        }
        var current = Read(path);
        if (!Same(current.Revision, expectedExternal))
        {
            // Refresh the conflict so the user reviews what is on disk now.
            ReconcileExternalChange(session);
            throw new ConflictResolutionException(ResolutionFailure.ConflictChanged);
        }
        if (session.Conflict?.Id != conflictId || session.Id != generation.BufferId || session.Revision != generation.Revision)
            throw new ConflictResolutionException(ResolutionFailure.ConflictChanged);
        return current;
    }

    private ConflictResolutionException ChangedAgain(DocumentSession session, DocumentSnapshot snap)
    {
        if (File.Exists(snap.Path ?? session.Conflict?.Path ?? "")) ReconcileExternalChange(session);
        return new ConflictResolutionException(ResolutionFailure.ConflictChanged);
    }

    private RecoveryReceipt PreserveAndRelease(ConflictSide side, Guid documentId, string path)
    {
        var receipt = recovery.Preserve(documentId, Path.GetFileName(path), side.Data, side.Modified);
        Release(side);
        return receipt;
    }

    private static void Release(ConflictSide side)
    {
        foreach (var retained in side.RetainedPaths ?? [])
        {
            try { File.Delete(retained); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    // ---- helpers --------------------------------------------------------------------------------

    private ExternalConflictException Raise(DocumentSession session, DocumentSnapshot snap, FileSnapshot external)
    {
        var conflict = MakeConflict(snap, external);
        session.RegisterConflict(conflict);
        return new ExternalConflictException(conflict);
    }

    private DocumentConflict MakeConflict(DocumentSnapshot snap, FileSnapshot external, IReadOnlyList<ConflictSide>? additional = null) =>
        new(Guid.NewGuid(), snap.DocumentId, snap.Path!, new BufferGeneration(snap.DocumentId, snap.Revision),
            new ConflictSide(_now(), snap.ExpectedDiskRevision, snap.Encode()),
            new ConflictSide(external.Revision.Modified, external.Revision, external.Data), additional);

    private FileSnapshot Read(string path)
    {
        try { return _read(path); }
        catch (FileNotFoundException) { throw new DocumentDeletedException(path); }
        catch (DirectoryNotFoundException) { throw new DocumentDeletedException(path); }
    }

    private static bool Same(DiskRevision a, DiskRevision b) => a.ByteCount == b.ByteCount && a.ContentDigest == b.ContentDigest;

    private static bool StillMatches(string path, DiskRevision expected)
    {
        try { return Same(DocumentIO.CurrentRevision(path), expected); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    private void RecordSelfWrite(string path, DiskRevision revision)
    {
        lock (_selfWriteLock) _selfWrites[Path.GetFullPath(path)] = (revision, _now() + SelfWriteWindow);
    }

    /// <summary>True once for a change the watcher reports that Clio's own save just made.</summary>
    public bool ConsumeSelfWrite(string path, DiskRevision revision)
    {
        lock (_selfWriteLock)
        {
            var current = _now();
            foreach (var expired in _selfWrites.Where(w => w.Value.Expires <= current).Select(w => w.Key).ToList()) _selfWrites.Remove(expired);
            var key = Path.GetFullPath(path);
            if (!_selfWrites.TryGetValue(key, out var record) || !Same(record.Revision, revision)) return false;
            _selfWrites.Remove(key);
            return true;
        }
    }
}
