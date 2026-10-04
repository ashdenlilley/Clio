using Clio.Core;
using Microsoft.UI.Dispatching;

namespace Clio.App;

/// <summary>An open document: its session, its autosaver, and the workspace it belongs to.</summary>
public sealed class DocumentTab : IDisposable
{
    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();

    public DocumentSession Session { get; private set; }
    public Autosaver Autosaver { get; }
    public WorkspaceHost? Workspace { get; private set; }

    /// <summary>
    /// The document's live editing state: text, selection and undo history. It outlives the editor control showing it, so
    /// switching tabs keeps each document's undo and redo.
    /// </summary>
    public Clio.Editor.EditorModel Editing { get; }

    /// <summary>Where this document was scrolled to when it was last shown.</summary>
    public double ScrollOffset { get; set; }

    /// <summary>
    /// Brings <see cref="Editing"/> in line with the session before the tab is shown. When the session changed while the
    /// tab was in the background (an outside edit reloaded, a conflict was resolved) the old history describes text that
    /// no longer exists, so it is dropped; otherwise nothing changes and undo carries on.
    /// </summary>
    public void SyncEditingBuffer()
    {
        if (string.Equals(Editing.Buffer.Text, Session.Text, StringComparison.Ordinal)) return;
        Editing.Buffer.Reset(Session.Text);
        Editing.SetSelection(0, 0);
        ScrollOffset = 0;
    }

    /// <summary>Session state changed (any thread raised it; this fires on the UI thread).</summary>
    public event Action? Changed;

    public DocumentTab(DocumentSession session, WorkspaceHost? workspace)
    {
        Session = session;
        Workspace = workspace;
        Editing = new Clio.Editor.EditorModel(new Clio.Editor.TextBuffer(session.Text));
        Autosaver = new Autosaver(AppServices.Instance.Documents);
        Session.Changed += OnSessionChanged;
    }

    private void OnSessionChanged() => _ui.TryEnqueue(() => Changed?.Invoke());

    public static DocumentTab Open(string path)
    {
        var workspace = AppServices.Instance.WorkspaceContaining(path);
        var session = DocumentSession.Open(path, workspace?.Root);
        return new DocumentTab(session, workspace);
    }

    public string Title
    {
        get
        {
            var path = Session.Path ?? Session.PreviousPath;
            return path is null ? "Untitled" : Path.GetFileName(path);
        }
    }

    /// <summary>The conflict is a deletion: the outside side holds no file.</summary>
    public bool ConflictIsDeletion => Session.Conflict is { External.Revision: null };

    /// <summary>Text for the status line.</summary>
    public string StatusText
    {
        get
        {
            if (Session.Conflict is not null) return "Changed outside Clio. Choose a version";
            if (Session.RequiresExplicitRestore) return "File deleted. Text kept";
            if (!Session.IsBackedByFile) return "Not saved yet";
            if (Autosaver.LastError is { } error) return error.Message;
            return Session.IsDirty ? "Editing…" : "Saved";
        }
    }

    /// <summary>Writes the text to <paramref name="path"/> (a file the user chose) and adopts it as the backing file.</summary>
    public void SaveAs(string path)
    {
        path = Path.GetFullPath(path);
        var snapshot = Session.Snapshot();
        var data = snapshot.Encode();
        File.WriteAllBytes(path, data);
        var revision = DocumentIO.Revision(path, data);

        var workspace = AppServices.Instance.WorkspaceContaining(path);
        var rootChanges = Session.WorkspaceRoot is { } root
            ? !AppPaths.IsContained(path, root)
            : workspace is not null;
        if (rootChanges) Rebind(path, keepText: Session.Text);
        else Session.DidWrite(snapshot, path, revision);
        AppServices.Instance.Journal.Clear(snapshot.DocumentId, snapshot.Revision);
        _ui.TryEnqueue(() => Changed?.Invoke());
    }

    /// <summary>
    /// The file now lives at <paramref name="path"/>. Within the same workspace the session just follows it. Across
    /// workspaces the session's save boundary changes, so a new session (same id) takes over and keeps any newer text.
    /// </summary>
    public void Rebind(string path, string? keepText = null)
    {
        path = Path.GetFullPath(path);
        var workspace = AppServices.Instance.WorkspaceContaining(path);
        if (Session.WorkspaceRoot is { } root && AppPaths.IsContained(path, root) && ReferenceEquals(workspace, Workspace))
        {
            Session.DidMove(path, DocumentIO.CurrentRevision(path));
            return;
        }
        var pending = keepText ?? (Session.IsDirty ? Session.Text : null);
        var replacement = DocumentSession.Open(path, workspace?.Root, Session.Id);
        if (pending is not null) replacement.SetText(pending);
        Session.Changed -= OnSessionChanged;
        Session = replacement;
        Workspace = workspace;
        Session.Changed += OnSessionChanged;
        _ui.TryEnqueue(() => Changed?.Invoke());
    }

    public void Dispose()
    {
        Session.Changed -= OnSessionChanged;
        Autosaver.Dispose();
    }
}
