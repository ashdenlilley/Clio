namespace Clio.Core;

public enum ConflictChoice { KeepClio, LoadExternal, KeepBoth }

/// <summary>One side of an external-edit conflict. Retained files (sidecars holding displaced bytes) go with it.</summary>
public sealed record ConflictSide(DateTimeOffset Modified, DiskRevision? Revision, byte[] Data, IReadOnlyList<string>? RetainedPaths = null);

/// <summary>
/// The buffer's unsaved text and the outside text disagree. <see cref="Generation"/> pins the buffer revision the
/// conflict was raised for: a resolution against a newer revision is refused.
/// </summary>
public sealed record DocumentConflict(
    Guid Id,
    Guid DocumentId,
    string Path,
    BufferGeneration Generation,
    ConflictSide Clio,
    ConflictSide External,
    IReadOnlyList<ConflictSide>? AdditionalExternalVersions = null);

/// <summary>What the editor hands to saves: text and the facts needed to decide whether disk still agrees with it.</summary>
public sealed record DocumentSnapshot(
    Guid DocumentId,
    string Text,
    ulong Revision,
    string? Path,
    string? PreviousPath,
    DiskRevision? ExpectedDiskRevision,
    bool Bom,
    LineEnding LineEnding,
    bool IsDirty)
{
    public string Filename => System.IO.Path.GetFileName(Path ?? PreviousPath ?? FileNames.DefaultName);

    /// <summary>The bytes a save would write.</summary>
    public byte[] Encode() => DocumentIO.Encode(Text, Bom, LineEnding);
}

/// <summary>
/// UI-free state of one open document (macOS <c>Document</c>): text, the revision counter that dirties it, the disk
/// revision it was last known to match, and any pending conflict. All members are thread-safe; the editor edits on
/// its thread while autosave snapshots and writes on another.
/// </summary>
public sealed class DocumentSession
{
    private readonly object _gate = new();
    private string _text = "";
    private string? _path;
    private string? _previousPath;
    private DiskRevision? _expected;
    private ulong _revision;
    private ulong _savedRevision;
    private bool _bom;
    private LineEnding _lineEnding;
    private DocumentConflict? _conflict;

    public DocumentSession(Guid? id = null, string? workspaceRoot = null)
    {
        Id = id ?? Guid.NewGuid();
        WorkspaceRoot = workspaceRoot is null ? null : PathSafety.Normalize(workspaceRoot);
    }

    public Guid Id { get; }

    /// <summary>The workspace the document lives in; conflict copies are written here.</summary>
    public string? WorkspaceRoot { get; }

    public string? Path { get { lock (_gate) return _path; } }
    public string? PreviousPath { get { lock (_gate) return _previousPath; } }
    public string Text { get { lock (_gate) return _text; } }
    public ulong Revision { get { lock (_gate) return _revision; } }
    public bool IsDirty { get { lock (_gate) return _revision != _savedRevision; } }
    public DiskRevision? ExpectedDiskRevision { get { lock (_gate) return _expected; } }
    public DocumentConflict? Conflict { get { lock (_gate) return _conflict; } }

    /// <summary>A file deleted or trashed outside Clio stays detached until a deliberate restore or Save As.</summary>
    public bool RequiresExplicitRestore { get { lock (_gate) return _path is null && _previousPath is not null; } }

    public bool IsBackedByFile { get { lock (_gate) return _path is not null; } }

    /// <summary>A pending conflict stops autosave until the user picks a side.</summary>
    public bool IsAutosavePaused { get { lock (_gate) return _conflict is not null; } }

    public event Action? Changed;

    public static DocumentSession Open(string path, string? workspaceRoot = null, Guid? id = null)
    {
        var session = new DocumentSession(id, workspaceRoot);
        session.ApplyLoaded(path, DocumentIO.Load(path));
        return session;
    }

    public DocumentSnapshot Snapshot()
    {
        lock (_gate)
            return new DocumentSnapshot(Id, _text, _revision, _path, _previousPath, _expected, _bom, _lineEnding, _revision != _savedRevision);
    }

    /// <summary>An editor mutation. Returns the new revision, or the current one when the text did not change.</summary>
    public ulong SetText(string text)
    {
        ulong revision;
        lock (_gate)
        {
            if (string.Equals(_text, text, StringComparison.Ordinal)) return _revision;
            _text = text;
            revision = ++_revision;
        }
        Changed?.Invoke();
        return revision;
    }

    /// <summary>Adopts the file's contents as the clean buffer, at <paramref name="path"/>.</summary>
    public void ApplyLoaded(string path, LoadedDocument document)
    {
        lock (_gate)
        {
            _text = document.Text;
            _bom = document.Bom;
            _lineEnding = document.LineEnding;
            _expected = document.Revision;
            _path = System.IO.Path.GetFullPath(path);
            _previousPath = null;
            _conflict = null;
            _savedRevision = ++_revision;
        }
        Changed?.Invoke();
    }

    /// <summary>The outside text replaces the buffer (a clean buffer reconciling, or "load the outside version").</summary>
    public void ApplyExternal(LoadedDocument document)
    {
        lock (_gate)
        {
            _text = document.Text;
            _bom = document.Bom;
            _lineEnding = document.LineEnding;
            _expected = document.Revision;
            _conflict = null;
            _savedRevision = ++_revision;
        }
        Changed?.Invoke();
    }

    /// <summary>A save of <paramref name="saved"/> reached <paramref name="path"/>. Edits made meanwhile stay dirty.</summary>
    public void DidWrite(DocumentSnapshot saved, string path, DiskRevision revision)
    {
        lock (_gate)
        {
            _path = System.IO.Path.GetFullPath(path);
            _previousPath = null;
            _expected = revision;
            _conflict = null;
            _savedRevision = Math.Max(_savedRevision, saved.Revision);
        }
        Changed?.Invoke();
    }

    public void RegisterConflict(DocumentConflict conflict)
    {
        lock (_gate) _conflict = conflict;
        Changed?.Invoke();
    }

    /// <summary>The file is gone. The text is kept; saving needs an explicit restore.</summary>
    public void MarkUnbacked()
    {
        lock (_gate)
        {
            if (_path is null) return;
            _previousPath = _path;
            _path = null;
        }
        Changed?.Invoke();
    }

    /// <summary>The file moved outside Clio. The buffer follows it; nothing else about it changes.</summary>
    public void DidMove(string newPath, DiskRevision? revision = null)
    {
        lock (_gate)
        {
            _path = System.IO.Path.GetFullPath(newPath);
            _previousPath = null;
            if (revision is not null) _expected = revision;
        }
        Changed?.Invoke();
    }
}
