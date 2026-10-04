using Clio.Core;
using Clio.Intelligence;

namespace Clio.App;

/// <summary>
/// Process-wide services: recovery stores, identity store, document service, mover, search index and the set of
/// open workspaces. Created once at launch; <see cref="Start"/> runs startup recovery before any window opens a file.
/// </summary>
public sealed class AppServices : IDisposable
{
    private readonly SemaphoreSlim _indexGate = new(1, 1);
    private readonly List<WorkspaceHost> _workspaces = [];

    public static AppServices Instance { get; private set; } = null!;

    public AppSettings Settings { get; }
    public RecoveryStore Recovery { get; } = new();
    public CrashRecoveryJournal Journal { get; } = new();
    public DocumentIdentityStore Identities { get; } = new(DocumentIdentityStore.DefaultStoragePath);
    public DocumentService Documents { get; }
    public DocumentMover Mover { get; }
    public SearchIndex Search { get; private set; }
    public StartupRecoveryReport? RecoveryReport { get; private set; }

    /// <summary>The only network capability: assisted commands and paste formatting. Off until the writer opts in.</summary>
    public IntelligenceService Intelligence { get; }

    public PdfPrintSettingsStore PdfPrint { get; }

    /// <summary>Local MCP: the service, the app-side host, login autostart and clipboard hygiene. Off until the owner enables it.</summary>
    public McpController Mcp { get; }

    private int _rebuilds;

    /// <summary>No full index rebuild is running, so a listing or search answers for every indexed workspace.</summary>
    public bool IndexIsComplete => Volatile.Read(ref _rebuilds) == 0;

    public IReadOnlyList<WorkspaceHost> Workspaces => _workspaces;

    /// <summary>The set of workspaces changed. Raised on the UI thread.</summary>
    public event Action? WorkspacesChanged;

    /// <summary>A workspace reported changes (already applied to the search index). Raised on the UI thread.</summary>
    public event Action<WorkspaceHost, IReadOnlyList<WorkspaceEvent>>? WorkspaceEventsObserved;

    private AppServices(AppSettings settings)
    {
        Settings = settings;
        Intelligence = new IntelligenceService(new PersistedIntelligenceSettings(settings), new CredentialManagerKeyStore());
        PdfPrint = new PdfPrintSettingsStore(settings);
        Documents = new DocumentService(Recovery, Journal);
        Mover = new DocumentMover(Recovery, Journal, Identities);
        Search = new SearchIndex(identities: Identities, includeTextFiles: settings.IncludeTextFiles);
        Mcp = new McpController();
    }

    public static AppServices Create()
    {
        Instance = new AppServices(AppSettings.Load());
        return Instance;
    }

    /// <summary>Settles interrupted writes and moves, sweeps the crash journal, then opens the saved workspaces.</summary>
    public void Start()
    {
        var roots = Settings.Workspaces.Select(w => w.Root).Where(Directory.Exists).ToList();
        try { RecoveryReport = StartupRecovery.Run(roots, Journal, Recovery); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ClioException) { }
        foreach (var record in Settings.Workspaces.ToList())
            if (Directory.Exists(record.Root)) Attach(record);
        _ = RebuildIndexAsync();
        // Recovery has settled and the workspaces exist, so a client that was authorized last time can connect.
        Mcp.StartConfigured();
    }

    public WorkspaceHost? WorkspaceContaining(string path) =>
        _workspaces.Where(w => AppPaths.IsContained(path, w.Root)).OrderByDescending(w => w.Root.Length).FirstOrDefault();

    public WorkspaceHost AddWorkspace(string root)
    {
        root = AppPaths.Normalize(root);
        if (_workspaces.FirstOrDefault(w => string.Equals(w.Root, root, StringComparison.OrdinalIgnoreCase)) is { } existing) return existing;
        var record = new WorkspaceRecord(Guid.NewGuid(), root);
        Settings.Workspaces.Add(record);
        Settings.Save();
        var host = Attach(record);
        _ = RebuildIndexAsync();
        WorkspacesChanged?.Invoke();
        return host;
    }

    public void RemoveWorkspace(WorkspaceHost host)
    {
        _workspaces.Remove(host);
        host.Dispose();
        Settings.Workspaces.RemoveAll(w => w.Id == host.Id);
        Settings.Save();
        _ = RebuildIndexAsync();
        WorkspacesChanged?.Invoke();
    }

    /// <summary>Changes the text-file policy and reopens every workspace so watchers and the index follow it.</summary>
    public void SetIncludeTextFiles(bool include)
    {
        if (Settings.IncludeTextFiles == include) return;
        Settings.IncludeTextFiles = include;
        Settings.Save();
        foreach (var host in _workspaces) host.Dispose();
        _workspaces.Clear();
        Search.Dispose();
        Search = new SearchIndex(identities: Identities, includeTextFiles: include);
        foreach (var record in Settings.Workspaces.Where(w => Directory.Exists(w.Root))) Attach(record);
        _ = RebuildIndexAsync();
        WorkspacesChanged?.Invoke();
    }

    private WorkspaceHost Attach(WorkspaceRecord record)
    {
        var host = new WorkspaceHost(record.Id, record.Root, Settings.IncludeTextFiles, Search, _indexGate);
        host.EventsObserved += events => WorkspaceEventsObserved?.Invoke(host, events);
        _workspaces.Add(host);
        return host;
    }

    private async Task RebuildIndexAsync()
    {
        var descriptors = _workspaces.Select(w => new WorkspaceDescriptor(w.Id, w.Root)).ToList();
        Interlocked.Increment(ref _rebuilds);
        try
        {
            await _indexGate.WaitAsync();
            try { await Search.RebuildAsync(descriptors); }
            catch (Exception e) when (e is SearchIndexException or OperationCanceledException or IOException or ObjectDisposedException) { }
            finally { _indexGate.Release(); }
        }
        finally { Interlocked.Decrement(ref _rebuilds); }
    }

    /// <summary>
    /// Tells the search index about a change Clio just made itself, ahead of the watcher. Returns whether the index is
    /// now current; false means a client should expect search to lag until the watcher catches up.
    /// </summary>
    public async Task<bool> RecordCommittedAsync(IReadOnlyList<WorkspaceEvent> events, CancellationToken ct = default)
    {
        try
        {
            await _indexGate.WaitAsync(ct);
            try { await Search.ApplyAsync(events, ct); return true; }
            finally { _indexGate.Release(); }
        }
        catch (Exception e) when (e is SearchIndexException or OperationCanceledException or IOException or ObjectDisposedException) { return false; }
    }

    public void Dispose()
    {
        Mcp.Dispose();
        foreach (var host in _workspaces) host.Dispose();
        _workspaces.Clear();
        try { Journal.Flush(); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        Identities.FlushPendingPersistence();
        Search.Dispose();
        Identities.Dispose();
    }
}
