using System.Runtime.InteropServices;

namespace Clio.Core;

public enum CollisionChoice { Cancel, KeepBoth, Replace }

/// <summary>The destination already holds a file. <see cref="ExistingRevision"/> is what a Replace must approve.</summary>
public sealed record FileCollision(string ProposedPath, DiskRevision? ExistingRevision);

/// <summary>The source was moved but changed while the move ran; its last bytes are kept at <see cref="RetainedPath"/>.</summary>
public sealed record MoveRecoveryNotice(Guid TransactionId, string SourcePath, string RetainedPath);

public abstract record MoveOutcome
{
    public sealed record Completed(string DestinationPath) : MoveOutcome;
    public sealed record CompletedWithRecovery(string DestinationPath, MoveRecoveryNotice Notice) : MoveOutcome;
    public sealed record Collision(FileCollision Details) : MoveOutcome;
    public sealed record Cancelled : MoveOutcome;
}

public enum MoveFailure { SourceChanged, DestinationChanged, InvalidPath }

public sealed class MoveException(MoveFailure failure, string path)
    : ClioException(failure switch
    {
        MoveFailure.DestinationChanged => $"{Path.GetFileName(path)} changed while Clio was preparing the move. Nothing was replaced.",
        MoveFailure.SourceChanged => $"{Path.GetFileName(path)} changed outside Clio while the move was being prepared. Review the conflict before moving it.",
        _ => $"{path} is not a valid destination inside the workspace.",
    })
{
    public MoveFailure Failure { get; } = failure;
}

/// <summary>Test seam: a hook that throws at a phase simulates a killed process and leaves every artifact in place.</summary>
public enum MovePhase { TransactionBegun, DestinationInstalled, SourceQuarantined }

/// <summary>Everything one move needs. Roots may differ (a move between workspaces).</summary>
public sealed record MoveRequest(
    string SourcePath,
    string SourceRoot,
    string DestinationRoot,
    Guid DocumentId,
    string ParentRelativePath = "",
    string? PreferredFilename = null,
    CollisionChoice? Choice = null,
    FileCollision? ApprovedCollision = null,
    DiskRevision? ExpectedSourceRevision = null,
    BufferGeneration Generation = default,
    Guid? SourceWorkspaceId = null,
    Guid? DestinationWorkspaceId = null);

/// <summary>
/// UI-free file mover (macOS <c>DocumentMover</c>). A move installs the source's bytes at the destination inside an
/// <see cref="InterruptedMoveTransactions"/> manifest, then hides the source by renaming it to a quarantine name
/// instead of deleting it, so a crash or a late edit never loses bytes. Replacing preserves the replaced file in the
/// recovery store first. Decisions are shared through <c>spec/vectors/document-move.json</c>.
/// The caller owns buffers: it must save or settle the document before calling, and preserve any unsaved text of a
/// document the move replaces.
/// </summary>
public sealed class DocumentMover(
    RecoveryStore recovery,
    CrashRecoveryJournal journal,
    DocumentIdentityStore? identities = null,
    Action<MovePhase>? phaseHook = null,
    Func<string, FileSnapshot>? snapshot = null)
{
    private readonly Func<string, FileSnapshot> _snapshot = snapshot ?? FileSnapshots.Read;

    public MoveOutcome Move(MoveRequest request)
    {
        var source = Path.GetFullPath(request.SourcePath);
        var sourceRoot = PathSafety.Normalize(request.SourceRoot);
        var destinationRoot = PathSafety.Normalize(request.DestinationRoot);
        if (!PathSafety.IsContained(source, sourceRoot)) throw new MoveException(MoveFailure.InvalidPath, source);

        // Validate the source early; the bytes that are installed are read again right before the move.
        _ = SettledSource(source, request.ExpectedSourceRevision);
        var filename = FileNames.Safe(request.PreferredFilename ?? Path.GetFileName(source));
        var destination = DestinationPath(destinationRoot, request.ParentRelativePath, filename);

        if (string.Equals(destination, source, StringComparison.Ordinal)) return new MoveOutcome.Completed(destination);

        CreateConfinedParent(destination, destinationRoot);

        if (SamePathIgnoringCase(source, destination))
        {
            // NTFS is case-insensitive: the destination "exists" because it is the source itself.
            File.Move(source, destination);
            MigrateIdentity(request, source, destination);
            return new MoveOutcome.Completed(destination);
        }

        if (Occupied(destination))
        {
            var proposed = destination;
            if (request.Choice is not { } choice) return new MoveOutcome.Collision(new FileCollision(proposed, ExistingRevision(destination)));
            switch (choice)
            {
                case CollisionChoice.Cancel:
                    return new MoveOutcome.Cancelled();
                case CollisionChoice.KeepBoth:
                    var folder = Path.GetDirectoryName(proposed)!;
                    destination = Path.Combine(folder, FileNames.Available(Path.GetFileName(proposed), n => Occupied(Path.Combine(folder, n))));
                    break;
                case CollisionChoice.Replace:
                    return Replace(request, source, sourceRoot, destinationRoot, destination);
            }
        }

        return Install(request, source, sourceRoot, destinationRoot, destination);
    }

    /// <summary>
    /// Sends a document to the Recycle Bin after checking it still matches <paramref name="expected"/>.
    /// <paramref name="trash"/> is a test seam; the default uses the shell's undoable delete.
    /// </summary>
    public static void MoveToTrash(string path, DiskRevision? expected = null, Action<string>? trash = null)
    {
        var full = Path.GetFullPath(path);
        if (expected is not null)
        {
            DiskRevision current;
            try { current = DocumentIO.CurrentRevision(full); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new MoveException(MoveFailure.SourceChanged, full); }
            if (!SameContent(current, expected)) throw new MoveException(MoveFailure.SourceChanged, full);
        }
        (trash ?? SendToRecycleBin)(full);
    }

    // ---- replace / install ----------------------------------------------------------------------

    private MoveOutcome Replace(MoveRequest request, string source, string sourceRoot, string destinationRoot, string destination)
    {
        var replaced = ReadDestination(destination);
        if (request.ApprovedCollision is not { ExistingRevision: { } approved } collision
            || !SamePathIgnoringCase(collision.ProposedPath, destination)
            || !SameContent(replaced.Revision, approved))
            return new MoveOutcome.Collision(new FileCollision(destination, replaced.Revision));

        recovery.Preserve(request.DocumentId, Path.GetFileName(destination), replaced.Data, replaced.Revision.Modified);

        var installed = SettledSource(source, request.ExpectedSourceRevision);
        var transaction = Begin(request, sourceRoot, destinationRoot, source, destination, installed, replaced.Revision);
        var crashed = false;
        var installing = false;
        try
        {
            At(MovePhase.TransactionBegun, ref crashed);
            // The swap is only as safe as this comparison: re-check right before replacing.
            if (!DestinationStillMatches(destination, replaced.Revision)) throw new MoveException(MoveFailure.DestinationChanged, destination);
            installing = true;
            AtomicFile.Write(destination, installed.Data, replaced.Revision);
            At(MovePhase.DestinationInstalled, ref crashed);
        }
        catch (Exception) when (!crashed)
        {
            // Before the swap started nothing was written, so the manifest is simply dropped. Once it started the
            // outcome is only known by comparing the destination.
            if (installing) TryAbort(transaction);
            else Discard(transaction);
            throw;
        }
        return Finish(request, source, destination, transaction, installed);
    }

    private MoveOutcome Install(MoveRequest request, string source, string sourceRoot, string destinationRoot, string destination)
    {
        var installed = SettledSource(source, request.ExpectedSourceRevision);
        var transaction = Begin(request, sourceRoot, destinationRoot, source, destination, installed, destinationRevision: null);
        var crashed = false;
        bool created;
        try
        {
            At(MovePhase.TransactionBegun, ref crashed);
            created = AtomicFile.TryCreate(destination, installed.Data);
            if (created) At(MovePhase.DestinationInstalled, ref crashed);
        }
        catch (Exception) when (!crashed)
        {
            TryAbort(transaction);
            throw;
        }
        if (!created)
        {
            // Someone took the name after the check: nothing was installed, so drop the manifest and report it.
            try { InterruptedMoveTransactions.Finish(transaction, removeQuarantine: false); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            return new MoveOutcome.Collision(new FileCollision(destination, ExistingRevision(destination)));
        }
        return Finish(request, source, destination, transaction, installed);
    }

    private void At(MovePhase phase, ref bool crashed)
    {
        if (phaseHook is null) return;
        try { phaseHook(phase); }
        catch { crashed = true; throw; }
    }

    private MoveOutcome Finish(MoveRequest request, string source, string destination, InterruptedMoveTransaction transaction, FileSnapshot installed)
    {
        var notice = QuarantineAndValidateSource(transaction, installed.Revision, request);
        MigrateIdentity(request, source, destination);
        return notice is null ? new MoveOutcome.Completed(destination) : new MoveOutcome.CompletedWithRecovery(destination, notice);
    }

    /// <summary>
    /// Hides the source, then checks that what was hidden is what the user approved. A source edited in between is
    /// journaled so the late edit survives.
    /// </summary>
    private MoveRecoveryNotice? QuarantineAndValidateSource(InterruptedMoveTransaction transaction, DiskRevision approvedSource, MoveRequest request)
    {
        var m = transaction.Manifest;
        try
        {
            InterruptedMoveTransactions.QuarantineSource(transaction);
            phaseHook?.Invoke(MovePhase.SourceQuarantined);
            var quarantined = InterruptedMoveTransactions.SourceRevision(transaction);
            if (SameContent(quarantined, approvedSource))
            {
                InterruptedMoveTransactions.Finish(transaction, removeQuarantine: true);
                return null;
            }

            string? journalPath = null;
            try
            {
                var data = File.ReadAllBytes(m.QuarantinePath);
                journalPath = journal.Checkpoint(CrashRecoveryRecord.Create(
                    request.DocumentId, request.Generation, Path.GetFileName(m.SourcePath), m.SourcePath,
                    RecoveryReason.InterruptedMove, data, DateTimeOffset.UtcNow));
                InterruptedMoveTransactions.Finish(transaction, removeQuarantine: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ClioException)
            {
                // The manifest and quarantine stay discoverable for startup recovery. If the journal write
                // succeeded, report that durable location even though cleanup failed.
            }
            return new MoveRecoveryNotice(m.Id, m.SourcePath, journalPath ?? m.QuarantinePath);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // The source could not be hidden (open elsewhere). The destination holds a complete copy and the
            // manifest lets startup recovery finish the job; the source is still where it was.
            return new MoveRecoveryNotice(m.Id, m.SourcePath, File.Exists(m.QuarantinePath) ? m.QuarantinePath : m.SourcePath);
        }
    }

    private static void Discard(InterruptedMoveTransaction transaction)
    {
        try { InterruptedMoveTransactions.Finish(transaction, removeQuarantine: false); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private static void TryAbort(InterruptedMoveTransaction transaction)
    {
        try { InterruptedMoveTransactions.AbortIfDestinationUnchanged(transaction); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private static InterruptedMoveTransaction Begin(MoveRequest r, string sourceRoot, string destinationRoot, string source, string destination, FileSnapshot installed, DiskRevision? destinationRevision) =>
        InterruptedMoveTransactions.Begin(r.DocumentId, r.Generation, sourceRoot, destinationRoot, source, destination,
            installed.Revision, destinationRevision, installed.Data);

    // ---- identity -------------------------------------------------------------------------------

    private void MigrateIdentity(MoveRequest request, string source, string destination)
    {
        if (identities is null || request.SourceWorkspaceId is not { } from || request.DestinationWorkspaceId is not { } to) return;
        identities.Migrate(
            new DocumentLocator(from, Relative(source, request.SourceRoot)),
            new DocumentLocator(to, Relative(destination, request.DestinationRoot)),
            PhysicalFileIdentity.TryOfFile(destination), destination, request.DocumentId);
    }

    private static string Relative(string path, string root) =>
        Path.GetRelativePath(PathSafety.Normalize(root), Path.GetFullPath(path)).Replace('\\', '/');

    // ---- paths and snapshots --------------------------------------------------------------------

    /// <summary>The source's bytes, refused if they differ from what the caller last saw (an outside edit).</summary>
    private FileSnapshot SettledSource(string source, DiskRevision? expected)
    {
        FileSnapshot current;
        try { current = _snapshot(source); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new MoveException(MoveFailure.SourceChanged, source); }
        if (expected is not null && !SameContent(current.Revision, expected)) throw new MoveException(MoveFailure.SourceChanged, source);
        return current;
    }

    private FileSnapshot ReadDestination(string destination)
    {
        try { return _snapshot(destination); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new MoveException(MoveFailure.DestinationChanged, destination); }
    }

    private static bool DestinationStillMatches(string destination, DiskRevision expected)
    {
        try { return SameContent(DocumentIO.CurrentRevision(destination), expected); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    private static DiskRevision? ExistingRevision(string path)
    {
        try { return File.Exists(path) ? DocumentIO.CurrentRevision(path) : null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    private static bool Occupied(string path) => File.Exists(path) || Directory.Exists(path);

    /// <summary>
    /// The destination path for <paramref name="filename"/> under <paramref name="parentRelative"/>. Every parent
    /// component must be a plain name: no rooted paths, no "..", no reserved or illegal names.
    /// </summary>
    private static string DestinationPath(string root, string parentRelative, string filename)
    {
        var path = root;
        foreach (var component in parentRelative.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (!FileNames.IsSafeComponent(component)) throw new MoveException(MoveFailure.InvalidPath, parentRelative);
            path = Path.Combine(path, component);
        }
        var full = Path.GetFullPath(Path.Combine(path, filename));
        if (!PathSafety.IsContained(full, root)) throw new MoveException(MoveFailure.InvalidPath, full);
        return full;
    }

    /// <summary>
    /// Creates missing destination folders one component at a time, refusing any link on the way. Windows has no
    /// openat, so the chain is re-checked after creation: a link swapped in mid-creation is caught before use.
    /// </summary>
    private static void CreateConfinedParent(string destination, string root)
    {
        var parent = Path.GetDirectoryName(destination)!;
        if (PathSafety.HasLinkBetween(destination, root)) throw new LinkException(parent);
        var missing = new Stack<string>();
        for (var dir = parent; !SamePathIgnoringCase(dir, root) && !Directory.Exists(dir); dir = Path.GetDirectoryName(dir)!) missing.Push(dir);
        foreach (var dir in missing)
        {
            Directory.CreateDirectory(dir);
            if (PathSafety.IsLink(dir)) throw new LinkException(dir);
        }
        if (PathSafety.HasLinkBetween(destination, root)) throw new LinkException(parent);
    }

    /// <summary>True when the paths name the same entry on a case-insensitive volume but are spelled differently.</summary>
    private static bool SamePathIgnoringCase(string a, string b) =>
        string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);

    private static bool SameContent(DiskRevision a, DiskRevision b) => a.ByteCount == b.ByteCount && a.ContentDigest == b.ContentDigest;

    // ---- recycle bin ----------------------------------------------------------------------------

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ShFileOperation
    {
        public nint Window;
        public uint Function;
        [MarshalAs(UnmanagedType.LPWStr)] public string From;
        [MarshalAs(UnmanagedType.LPWStr)] public string? To;
        public ushort Flags;
        [MarshalAs(UnmanagedType.Bool)] public bool AnyOperationsAborted;
        public nint NameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string? Title;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperationW(ref ShFileOperation operation);

    private static void SendToRecycleBin(string path)
    {
        const uint Delete = 3;
        const ushort AllowUndo = 0x40, NoConfirmation = 0x10, Silent = 0x4, NoErrorUi = 0x400;
        var operation = new ShFileOperation { Function = Delete, From = path + "\0\0", Flags = AllowUndo | NoConfirmation | Silent | NoErrorUi };
        var result = SHFileOperationW(ref operation);
        if (result != 0 || operation.AnyOperationsAborted)
            throw new IOException($"The Recycle Bin refused {Path.GetFileName(path)} (code {result}).");
    }
}
