using System.Text;
using Clio.Core;
using Clio.Export;
using Clio.Mcp;
using Microsoft.UI.Dispatching;

namespace Clio.App;

/// <summary>
/// The app side of local MCP (<see cref="IMcpHost"/>): it reads and edits the documents Clio has open, through the same
/// per-tab sessions, editor models and autosavers the user types into. Every call hops to the UI thread, where the
/// sessions and windows live; slow work (scans, search, rendering, file moves) runs on worker threads in between. After
/// every suspension it revalidates the client's authority, and it never writes a backing file directly.
/// <para>
/// A document that is not open in any window is read through a background tab, kept only while MCP is on and idle for
/// less than ten minutes, and handed to the window that opens it so there is never a second session for one file.
/// </para>
/// </summary>
public sealed class AppMcpHost(DispatcherQueue ui) : IMcpHost
{
    private static readonly TimeSpan BackgroundIdle = TimeSpan.FromMinutes(10);

    private sealed class Background(DocumentTab tab) { public DocumentTab Tab { get; } = tab; public DateTime LastUsed { get; set; } = DateTime.UtcNow; }

    private sealed record Live(DocumentTab Tab, MainWindow? Window, WorkspaceHost Workspace);

    private readonly McpRevisionTracker _revisions = new();
    private readonly Dictionary<Guid, Background> _background = [];
    private volatile IReadOnlyList<McpWorkspaceInfo> _workspaces = [];

    public IReadOnlyList<McpWorkspaceInfo> Workspaces => _workspaces;

    /// <summary>Starts following the open workspaces. UI thread.</summary>
    public void Attach()
    {
        AppServices.Instance.WorkspacesChanged += Refresh;
        Refresh();
    }

    private void Refresh()
    {
        var hosts = AppServices.Instance.Workspaces;
        _workspaces = [.. hosts.Select(w => new McpWorkspaceInfo(w.Id, w.DisplayName))];
        // A folder that was closed takes its background documents with it.
        foreach (var (id, entry) in _background.ToList())
            if (entry.Tab.Workspace is null || hosts.All(w => w.Id != entry.Tab.Workspace.Id)) Drop(id);
    }

    /// <summary>Releases every background document. UI thread.</summary>
    public void ClearBackground()
    {
        foreach (var id in _background.Keys.ToList()) Drop(id);
    }

    private void Drop(Guid id)
    {
        if (!_background.Remove(id, out var entry)) return;
        entry.Tab.Dispose();
    }

    /// <summary>A window is opening <paramref name="path"/>: hand it the background tab for that file, if there is one.</summary>
    public DocumentTab? TakeBackgroundTab(string path)
    {
        var match = _background.FirstOrDefault(b => b.Value.Tab.Session.Path is { } p && string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
        if (match.Value is null) return null;
        _background.Remove(match.Key);
        return match.Value.Tab;
    }

    // ---- thread hops ----------------------------------------------------------------------------

    private Task<T> OnUi<T>(Func<Task<T>> work)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var queued = ui.TryEnqueue(async () =>
        {
            try { done.SetResult(await work()); }
            catch (Exception e) { done.SetException(e); }
        });
        if (!queued) done.SetException(new McpToolFailure("app_unavailable"));
        return done.Task;
    }

    private Task OnUi(Func<Task> work) => OnUi(async () => { await work(); return 0; });

    // ---- finding documents ----------------------------------------------------------------------

    private static WorkspaceHost WorkspaceOrThrow(Guid id) =>
        AppServices.Instance.Workspaces.FirstOrDefault(w => w.Id == id) ?? throw new McpException(McpErrorCode.OutsideWorkspace);

    private IEnumerable<(DocumentTab Tab, MainWindow? Window)> AllTabs() =>
        App.Windows.SelectMany(w => w.Tabs.Select(t => (t, (MainWindow?)w)))
            .Concat(_background.Values.Select(b => (b.Tab, (MainWindow?)null)));

    private Live? FindLive(Guid workspaceId, Guid documentId)
    {
        foreach (var (tab, window) in AllTabs())
        {
            if (tab.Session.Id != documentId) continue;
            // The id is the document's; the workspace must be the one that holds it.
            if (tab.Workspace is not { } workspace || workspace.Id != workspaceId) throw new McpException(McpErrorCode.OutsideWorkspace);
            if (_background.TryGetValue(documentId, out var entry)) entry.LastUsed = DateTime.UtcNow;
            return new Live(tab, window, workspace);
        }
        return null;
    }

    private void EvictIdle()
    {
        var now = DateTime.UtcNow;
        foreach (var (id, entry) in _background.ToList())
            if (now - entry.LastUsed > BackgroundIdle && !entry.Tab.Session.IsDirty) Drop(id);
    }

    /// <summary>The open document with this id, or one loaded in the background from its workspace. Revalidates authority throughout.</summary>
    private async Task<Live> ResolveAsync(Guid workspaceId, Guid documentId, McpAuthority authority, CancellationToken ct)
    {
        authority.Validate(workspaceId);
        ct.ThrowIfCancellationRequested();
        EvictIdle();
        var workspace = WorkspaceOrThrow(workspaceId);
        var live = FindLive(workspaceId, documentId);
        if (live is null)
        {
            var services = AppServices.Instance;
            var files = await Task.Run(() => WorkspaceScanner.ScanFiles(workspaceId, workspace.Root, services.Identities, services.Settings.IncludeTextFiles), ct);
            authority.Validate(workspaceId);
            ct.ThrowIfCancellationRequested();
            var file = files.FirstOrDefault(f => f.DocumentId == documentId) ?? throw new McpException(McpErrorCode.OutsideWorkspace);
            if (file.ByteCount > McpLimits.ReadDocumentBytes) throw new McpException(McpErrorCode.OversizedRequest);
            // Opening it, or the scan's wait, may have let a window get there first.
            live = FindLive(workspaceId, documentId);
            if (live is null)
            {
                WorkspaceOrThrow(workspaceId);
                McpWorkspaceBoundary.Validate(file.Path, workspace.Root);
                DocumentTab tab;
                try { tab = DocumentTab.Open(file.Path); }
                catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException)
                {
                    throw new McpToolFailure("document_unavailable");
                }
                if (tab.Session.Id != documentId || tab.Workspace?.Id != workspaceId) { tab.Dispose(); throw new McpException(McpErrorCode.OutsideWorkspace); }
                _background[documentId] = new Background(tab);
                live = new Live(tab, null, workspace);
            }
        }
        if (live.Tab.Session.Path is not { } path) throw new McpException(McpErrorCode.OutsideWorkspace);
        McpWorkspaceBoundary.Validate(path, live.Workspace.Root);
        authority.Validate(workspaceId);
        return live;
    }

    private McpDocumentInfo Info(DocumentTab tab, Guid workspaceId)
    {
        var s = tab.Session;
        return new McpDocumentInfo(s.Id, workspaceId, Path.GetFileName(s.Path ?? s.PreviousPath ?? FileNames.DefaultName),
            _revisions.For(s, s.Id, s.Revision), s.Conflict is not null ? "conflict" : s.IsDirty ? "pending" : "saved");
    }

    private void CheckRevision(McpRevision expected, DocumentTab tab)
    {
        var current = _revisions.For(tab.Session, tab.Session.Id, tab.Session.Revision);
        if (expected != current)
            throw new McpToolFailure("stale_revision", new Dictionary<string, string> { ["currentRevision"] = current.Encode() });
    }

    private static string RelativePath(string root, string path) => Path.GetRelativePath(root, path).Replace('\\', '/');

    private static string NormalizeLineEndings(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n');

    /// <summary>Shows the document in an editor window (the one that has it, else the last active one) and returns that window.</summary>
    private MainWindow EnsureShown(Live live)
    {
        if (live.Window is { IsClosing: false } holder)
        {
            holder.Activate(live.Tab);
            holder.Activate();
            return holder;
        }
        var target = App.LastActiveWindow ?? App.Windows.FirstOrDefault() ?? App.OpenWindow();
        if (_background.Remove(live.Tab.Session.Id)) target.AdoptTab(live.Tab);
        else target.OpenPath(live.Tab.Session.Path!);
        target.Activate();
        return target;
    }

    // ---- reading --------------------------------------------------------------------------------

    public Task<McpDiscovery> DiscoverAsync(Guid workspaceId, string? query, McpAuthority authority, CancellationToken ct) => OnUi(async () =>
    {
        authority.Validate(workspaceId);
        var workspace = WorkspaceOrThrow(workspaceId);
        var services = AppServices.Instance;
        var entries = new List<McpDiscoveryEntry>();
        var capped = false;
        var complete = true;
        if (query is null)
        {
            var files = await Task.Run(() => WorkspaceScanner.ScanFiles(workspaceId, workspace.Root, services.Identities, services.Settings.IncludeTextFiles), ct);
            entries.AddRange(files.Select(f => new McpDiscoveryEntry(f.DocumentId, workspaceId, f.RelativePath)));
            if (entries.Count > SearchQuery.MaximumResults) { entries.RemoveRange(SearchQuery.MaximumResults, entries.Count - SearchQuery.MaximumResults); capped = true; }
        }
        else
        {
            IReadOnlyList<SearchResult> results = [];
            try
            {
                await foreach (var batch in services.Search.SearchAsync(new SearchQuery(query, workspaceId, false, SearchQuery.MaximumResults), ct)) results = batch.Results;
            }
            catch (SearchIndexException) { throw new McpToolFailure("search_unavailable"); }
            entries.AddRange(results.Where(r => r.WorkspaceId == workspaceId).Select(r => new McpDiscoveryEntry(r.DocumentId, workspaceId, r.RelativePath)));
            capped = results.Count >= SearchQuery.MaximumResults;
            complete = services.IndexIsComplete;
        }
        authority.Validate(workspaceId);
        ct.ThrowIfCancellationRequested();

        // Only open buffers override the index: unsaved text, and the removal of a stale disk match.
        foreach (var (tab, _) in AllTabs())
        {
            if (tab.Workspace?.Id != workspaceId || tab.Session.Path is not { } path) continue;
            try { McpWorkspaceBoundary.Validate(path, workspace.Root); }
            catch (McpException) { entries.RemoveAll(e => e.DocumentId == tab.Session.Id); continue; }
            var relative = RelativePath(workspace.Root, path);
            var text = tab.Session.Text;
            var matches = query is null || (Encoding.UTF8.GetByteCount(text) <= McpLimits.ReadDocumentBytes && LiveMatches(text, relative, query));
            entries.RemoveAll(e => e.DocumentId == tab.Session.Id);
            if (matches) entries.Add(new McpDiscoveryEntry(tab.Session.Id, workspaceId, relative));
        }
        return new McpDiscovery(entries, capped, complete);
    });

    /// <summary>Every term of the query appears in the text or the path, case-insensitively (the index matches word prefixes).</summary>
    private static bool LiveMatches(string text, string relativePath, string query)
    {
        var terms = SearchQueryText.Terms(query);
        return terms.Count > 0 && terms.All(t =>
            text.Contains(t, StringComparison.OrdinalIgnoreCase) || relativePath.Contains(t, StringComparison.OrdinalIgnoreCase));
    }

    public Task<McpDocumentSnapshot> SnapshotAsync(Guid workspaceId, Guid documentId, McpAuthority authority, CancellationToken ct) => OnUi(async () =>
    {
        var live = await ResolveAsync(workspaceId, documentId, authority, ct);
        if (live.Window is null) Reconcile(live.Tab);
        authority.Validate(workspaceId);
        var session = live.Tab.Session;
        return new McpDocumentSnapshot(Info(live.Tab, workspaceId), session.Text, session.Path);
    });

    /// <summary>A background document has no window watching it, so pick up outside edits before reading.</summary>
    private static void Reconcile(DocumentTab tab)
    {
        try { AppServices.Instance.Documents.ReconcileExternalChange(tab.Session); }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { }
    }

    public Task<McpActiveDocument?> ActiveDocumentAsync(McpAuthority authority, CancellationToken ct) => OnUi<McpActiveDocument?>(() =>
    {
        ct.ThrowIfCancellationRequested();
        if (App.LastActiveWindow is not { ActiveTab: { } tab } window) return Task.FromResult<McpActiveDocument?>(null);
        if (tab.Workspace is not { } workspace || tab.Session.Path is not { } path) return Task.FromResult<McpActiveDocument?>(null);
        // A document outside the client's folders is not its business: answer as if nothing were open.
        try { authority.Validate(workspace.Id); McpWorkspaceBoundary.Validate(path, workspace.Root); }
        catch (McpException) { return Task.FromResult<McpActiveDocument?>(null); }
        var selection = window.EditorSurface.Model.Selection;
        return Task.FromResult<McpActiveDocument?>(new McpActiveDocument(Info(tab, workspace.Id), selection.Start, selection.Length));
    });

    // ---- opening, selecting, editing ------------------------------------------------------------

    public Task OpenAsync(Guid workspaceId, Guid documentId, McpAuthority authority, CancellationToken ct) => OnUi(async () =>
    {
        var live = await ResolveAsync(workspaceId, documentId, authority, ct);
        authority.Validate(workspaceId);
        EnsureShown(live);
    });

    public Task<McpDocumentInfo> SelectTextAsync(Guid workspaceId, Guid documentId, McpRevision expected, int location, int length,
        McpAuthority authority, CancellationToken ct) => OnUi(async () =>
    {
        var live = await ResolveAsync(workspaceId, documentId, authority, ct);
        CheckRevision(expected, live.Tab);
        var window = EnsureShown(live);
        var session = live.Tab.Session;
        var (surface, model) = Editor(window, live.Tab);
        if (surface.IsComposing || !string.Equals(surface.Text, session.Text, StringComparison.Ordinal)) throw new McpToolFailure("editor_busy_retry");
        // The same range rules as an edit: no half of a surrogate pair or a composed character.
        _ = new McpTextReplacement(location, length, "").Applying(session.Text);
        authority.Validate(workspaceId);
        ct.ThrowIfCancellationRequested();
        model.SetSelection(location, location + length);
        return Info(live.Tab, workspaceId);
    });

    public Task<McpDocumentInfo> ReplaceAsync(Guid workspaceId, Guid documentId, McpRevision expected, McpTextReplacement edit,
        McpAuthority authority, CancellationToken ct) => OnUi(async () =>
    {
        var live = await ResolveAsync(workspaceId, documentId, authority, ct);
        CheckRevision(expected, live.Tab);
        var window = EnsureShown(live);
        var session = live.Tab.Session;
        var (surface, model) = Editor(window, live.Tab);
        // Nothing below suspends: the checks and the edit see the same buffer.
        if (surface.IsComposing || !string.Equals(surface.Text, session.Text, StringComparison.Ordinal)) throw new McpToolFailure("editor_busy_retry");
        if (session.Conflict is not null || Encoding.UTF8.GetByteCount(session.Text) > McpLimits.ReadDocumentBytes)
            throw new McpToolFailure("document_conflicted_or_too_large");
        // The buffer is LF; a client may send CRLF. Offsets refer to the existing text, so only the inserted text changes.
        var normalized = edit with { Text = NormalizeLineEndings(edit.Text) };
        var candidate = normalized.Applying(session.Text);
        authority.Validate(workspaceId);
        McpWorkspaceBoundary.Validate(session.Path!, live.Workspace.Root);
        ct.ThrowIfCancellationRequested();

        // Through the editor, so it lands in the document's undo history and the autosaver sees it like typing.
        model.SetSelection((int)edit.Location, (int)(edit.Location + edit.Length));
        model.Insert(normalized.Text);
        if (!string.Equals(surface.Text, candidate, StringComparison.Ordinal)) throw new McpToolFailure("editor_rejected_change");
        return Info(live.Tab, workspaceId);
    });

    private static (EditorControl Surface, Clio.Editor.EditorModel Model) Editor(MainWindow window, DocumentTab tab)
    {
        var surface = window.EditorSurface;
        if (!ReferenceEquals(surface.Model, tab.Editing)) throw new McpToolFailure("editor_busy_retry");
        return (surface, tab.Editing);
    }

    // ---- creating, moving, trashing, exporting --------------------------------------------------

    public Task<McpCommit> CreateAsync(Guid workspaceId, string filename, string text, McpAuthority authority, CancellationToken ct) => OnUi(async () =>
    {
        authority.Validate(workspaceId);
        var workspace = WorkspaceOrThrow(workspaceId);
        if (!FileNames.IsSafeComponent(filename)) throw new McpException(McpErrorCode.InvalidRequest);
        var target = Path.Combine(workspace.Root, filename);
        McpWorkspaceBoundary.Validate(target, workspace.Root);
        var bytes = DocumentIO.Encode(NormalizeLineEndings(text), bom: false, LineEnding.Lf);
        authority.Validate(workspaceId);
        ct.ThrowIfCancellationRequested();

        bool created;
        try { created = await Task.Run(() => AtomicFile.TryCreate(target, bytes)); }
        catch (LinkException) { throw new McpException(McpErrorCode.OutsideWorkspace); }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { throw new McpToolFailure("create_failed"); }
        if (!created) throw new McpToolFailure("destination_exists");

        // The file exists now, so the answer reports it even if the client has gone.
        DocumentTab tab;
        try { tab = DocumentTab.Open(target); }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { throw new McpToolFailure("document_unavailable"); }
        _background[tab.Session.Id] = new Background(tab);
        var indexed = await AppServices.Instance.RecordCommittedAsync([new WorkspaceEvent(workspaceId, WorkspaceEventKind.Created, target)]);
        return new McpCommit(Info(tab, workspaceId), !indexed);
    });

    public Task<McpCommit> MoveAsync(McpMoveRequest request, McpAuthority authority, CancellationToken ct) => OnUi(async () =>
    {
        var live = await ResolveAsync(request.WorkspaceId, request.DocumentId, authority, ct);
        authority.Validate(request.DestinationWorkspaceId);
        var destination = WorkspaceOrThrow(request.DestinationWorkspaceId);
        var tab = live.Tab;
        var session = tab.Session;
        CheckRevision(request.Revision, tab);
        if (session.IsDirty || session.Conflict is not null || session.Path is not { } source) throw new McpToolFailure("wait_for_save_before_move");
        var parent = request.ParentRelativePath.Replace('/', Path.DirectorySeparatorChar);
        McpWorkspaceBoundary.Validate(Path.Combine(destination.Root, parent, request.Filename), destination.Root);

        tab.Autosaver.SuspendForFileOperation();
        try
        {
            await tab.Autosaver.SettlePendingFileIOAsync();
            // The settle suspended: the buffer, the folders and the client's grant may all have changed.
            session = tab.Session;
            authority.Validate(request.WorkspaceId);
            authority.Validate(request.DestinationWorkspaceId);
            ct.ThrowIfCancellationRequested();
            CheckRevision(request.Revision, tab);
            if (session.IsDirty || session.Conflict is not null || session.Path is null) throw new McpToolFailure("wait_for_save_before_move");

            var move = new MoveRequest(
                source, live.Workspace.Root, destination.Root, session.Id, request.ParentRelativePath, request.Filename,
                Choice: null, ApprovedCollision: null, session.ExpectedDiskRevision, new BufferGeneration(session.Id, session.Revision),
                live.Workspace.Id, destination.Id);
            string target;
            try
            {
                target = await Task.Run(() => AppServices.Instance.Mover.Move(move)) switch
                {
                    MoveOutcome.Completed done => done.DestinationPath,
                    MoveOutcome.CompletedWithRecovery recovered => recovered.DestinationPath,
                    MoveOutcome.Collision => throw new McpToolFailure("destination_exists"),
                    _ => throw new McpToolFailure("move_cancelled"),
                };
            }
            catch (MoveException e)
            {
                throw e.Failure switch
                {
                    MoveFailure.SourceChanged => new McpToolFailure("document_changed_on_disk"),
                    MoveFailure.DestinationChanged => new McpToolFailure("destination_exists"),
                    _ => (Exception)new McpException(McpErrorCode.OutsideWorkspace),
                };
            }
            catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { throw new McpToolFailure("move_failed"); }

            // The move is done, so the answer reports it even if the client has gone.
            tab.Rebind(target);
            var indexed = await AppServices.Instance.RecordCommittedAsync(
                [new WorkspaceEvent(destination.Id, WorkspaceEventKind.Moved, target, source)]);
            return new McpCommit(Info(tab, destination.Id), !indexed);
        }
        finally { tab.Autosaver.ResumeAfterFileOperation(); }
    });

    /// <summary>Native confirmation: it opens Clio's own window if none exists, and only the owner's click can approve.</summary>
    public Task<bool> ConfirmDeletionAsync(McpDeletionRequest request, CancellationToken ct) => OnUi(async () =>
    {
        ct.ThrowIfCancellationRequested();
        var window = App.LastActiveWindow ?? App.Windows.FirstOrDefault() ?? App.OpenWindow();
        return await window.ConfirmMcpDeletionAsync(request, ct);
    });

    public Task<bool> TrashAsync(Guid workspaceId, Guid documentId, McpRevision approved, McpAuthority authority, CancellationToken ct) => OnUi(async () =>
    {
        var live = await ResolveAsync(workspaceId, documentId, authority, ct);
        var tab = live.Tab;
        // Settle any pending save first, so it cannot write the file back after it is gone.
        try { await tab.Autosaver.FlushAsync(tab.Session); }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { }
        authority.Validate(workspaceId);
        var session = tab.Session;
        if (session.Path is not { } path) throw new McpException(McpErrorCode.OutsideWorkspace);
        McpWorkspaceBoundary.Validate(path, live.Workspace.Root);
        CheckRevision(approved, tab);
        ct.ThrowIfCancellationRequested();

        var expected = session.ExpectedDiskRevision;
        try { await Task.Run(() => DocumentMover.MoveToTrash(path, expected)); }
        catch (MoveException e) when (e.Failure == MoveFailure.SourceChanged) { throw new McpToolFailure("document_changed_on_disk"); }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { throw new McpToolFailure("trash_failed"); }

        if (live.Window is { } window) window.CloseTabQuietly(path);
        else Drop(documentId);
        var indexed = await AppServices.Instance.RecordCommittedAsync([new WorkspaceEvent(workspaceId, WorkspaceEventKind.Deleted, path)]);
        return !indexed;
    });

    public Task<McpRevision> ExportAsync(McpExportRequest request, McpAuthority authority, CancellationToken ct) => OnUi(async () =>
    {
        var live = await ResolveAsync(request.WorkspaceId, request.DocumentId, authority, ct);
        authority.Validate(request.DestinationWorkspaceId);
        var destination = WorkspaceOrThrow(request.DestinationWorkspaceId);
        CheckRevision(request.Revision, live.Tab);
        if (!FileNames.IsSafeComponent(request.Filename)) throw new McpException(McpErrorCode.InvalidRequest);
        var target = Path.Combine(destination.Root, request.Filename);
        McpWorkspaceBoundary.Validate(target, destination.Root);

        var format = request.Format switch
        {
            McpExportFormat.Pdf => ExportFormat.Pdf,
            McpExportFormat.Html => ExportFormat.Html,
            McpExportFormat.Docx => ExportFormat.Docx,
            _ => ExportFormat.Txt,
        };
        var source = live.Tab.Session.Text;
        var title = Path.GetFileNameWithoutExtension(live.Tab.Title);
        byte[] bytes;
        try { bytes = await Task.Run(() => DocumentExporter.Render(format, source, title, null, ct), ct); }
        catch (Exception e) when (e is ClioException) { throw new McpToolFailure("export_failed"); }

        // Rendering suspended; commit only while the client still holds both folders. Create-if-absent never overwrites.
        authority.Validate(request.WorkspaceId);
        authority.Validate(request.DestinationWorkspaceId);
        McpWorkspaceBoundary.Validate(target, destination.Root);
        ct.ThrowIfCancellationRequested();
        bool created;
        try { created = await Task.Run(() => AtomicFile.TryCreate(target, bytes)); }
        catch (LinkException) { throw new McpException(McpErrorCode.OutsideWorkspace); }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { throw new McpToolFailure("export_failed"); }
        if (!created) throw new McpToolFailure("destination_exists");
        return request.Revision;
    });
}
