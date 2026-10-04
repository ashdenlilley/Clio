using System.Threading.Channels;

namespace Clio.Core;

/// <summary>
/// One recursive <see cref="FileSystemWatcher"/> (ReadDirectoryChangesW) observes file-level writes without a handle
/// per directory. A liveness timer makes loss of the root immediate, since ReadDirectoryChangesW never reports the
/// root's own deletion, and snapshot diffs keep move semantics stable (macOS <c>WorkspaceWatcher</c>).
/// Events arrive on <see cref="Events"/>. The channel keeps the newest 2048; an overflow always leaves a
/// <see cref="WorkspaceEventKind.RescanRequired"/> marker so no external edit is lost silently.
/// </summary>
public sealed class WorkspaceWatcher : IDisposable
{
    public const int EventCapacity = 2048;
    private static readonly TimeSpan ScanDebounce = TimeSpan.FromMilliseconds(40);
    private static readonly TimeSpan DeleteConfirmation = TimeSpan.FromMilliseconds(120);
    private static readonly TimeSpan LivenessInterval = TimeSpan.FromMilliseconds(200);

    private enum ScanKind { Complete, Incomplete, RootUnavailable }

    private readonly Guid _workspaceId;
    private readonly string _root;
    private readonly bool _includeText;
    private readonly Action? _fullScanObserver;
    private readonly Action<string, WatcherChangeTypes>? _rawEventObserver;
    private readonly Channel<WorkspaceEvent> _channel;
    private readonly object _gate = new();
    private readonly FileSystemWatcher _watcher;
    private readonly Timer _liveness;
    private readonly Timer _scanTimer;
    private readonly Timer _deleteTimer;
    private readonly HashSet<string> _pendingDeletes = new(StringComparer.OrdinalIgnoreCase);
    private Dictionary<PhysicalFileIdentity, FileState> _snapshot = [];
    private Dictionary<string, PhysicalFileIdentity> _keyByPath = new(StringComparer.OrdinalIgnoreCase);
    private bool _finished;

    public ChannelReader<WorkspaceEvent> Events => _channel.Reader;

    /// <param name="includeTextFiles">Also track <c>.txt</c> documents (the scanner's text-file policy).</param>
    /// <param name="fullScanObserver">Called at the start of every full tree scan (tests count scans).</param>
    /// <param name="rawEventObserver">Called for every raw change before interpretation.</param>
    public WorkspaceWatcher(
        Guid workspaceId,
        string root,
        bool includeTextFiles = false,
        Action? fullScanObserver = null,
        Action<string, WatcherChangeTypes>? rawEventObserver = null)
    {
        _workspaceId = workspaceId;
        _root = SnapshotDiff.Standardize(root);
        _includeText = includeTextFiles;
        _fullScanObserver = fullScanObserver;
        _rawEventObserver = rawEventObserver;
        _channel = Channel.CreateBounded<WorkspaceEvent>(
            new BoundedChannelOptions(EventCapacity) { FullMode = BoundedChannelFullMode.DropOldest });
        _scanTimer = new Timer(_ => Rescan(), null, Timeout.Infinite, Timeout.Infinite);
        _deleteTimer = new Timer(_ => ConfirmDeletes(), null, Timeout.Infinite, Timeout.Infinite);
        _liveness = new Timer(_ => CheckRoot(), null, Timeout.Infinite, Timeout.Infinite);
        _watcher = new FileSystemWatcher
        {
            InternalBufferSize = 64 * 1024,
            IncludeSubdirectories = true,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime,
        };

        // Monitoring starts before the constructor returns, so no edit or deletion can fall between construction
        // and observation. Only the potentially large initial scan runs later.
        lock (_gate)
        {
            if (!RootIsReadableDirectory())
            {
                Emit(WorkspaceEventKind.AccessLost, _root);
                Finish();
                return;
            }
            try
            {
                _watcher.Path = _root;
                _watcher.Created += (_, e) => Handle(e.FullPath, null, WatcherChangeTypes.Created);
                _watcher.Changed += (_, e) => Handle(e.FullPath, null, WatcherChangeTypes.Changed);
                _watcher.Deleted += (_, e) => Handle(e.FullPath, null, WatcherChangeTypes.Deleted);
                _watcher.Renamed += (_, e) => Handle(e.FullPath, e.OldFullPath, WatcherChangeTypes.Renamed);
                _watcher.Error += (_, e) => OnWatcherError(e.GetException());
                _watcher.EnableRaisingEvents = true;
            }
            catch (Exception e) when (e is ArgumentException or IOException or UnauthorizedAccessException)
            {
                Emit(WorkspaceEventKind.Error, _root);
                Finish();
                return;
            }
            _liveness.Change(LivenessInterval, LivenessInterval);
        }
        Task.Run(LoadInitialSnapshot);
    }

    public void Dispose()
    {
        lock (_gate) Finish();
        _watcher.Dispose();
        _liveness.Dispose();
        _scanTimer.Dispose();
        _deleteTimer.Dispose();
    }

    // ---- scanning -------------------------------------------------------------------------------

    private void LoadInitialSnapshot()
    {
        lock (_gate)
        {
            if (_finished) return;
            switch (ScanFiles(out var files))
            {
                case ScanKind.Complete: ReplaceSnapshot(files); break;
                case ScanKind.Incomplete: Emit(WorkspaceEventKind.RescanRequired, _root); break;
                case ScanKind.RootUnavailable: Emit(WorkspaceEventKind.AccessLost, _root); Finish(); break;
            }
        }
    }

    private void ScheduleScan()
    {
        if (!_finished) _scanTimer.Change(ScanDebounce, Timeout.InfiniteTimeSpan);
    }

    private void Rescan()
    {
        lock (_gate)
        {
            if (_finished) return;
            if (!RootIsReadableDirectory()) { LoseRoot(); return; }
            switch (ScanFiles(out var next))
            {
                case ScanKind.Complete:
                    var changes = SnapshotDiff.Compute(_snapshot, next);
                    foreach (var c in changes) Emit(c.Kind, c.Path, c.PreviousPath);
                    if (changes.Count == 0) Emit(WorkspaceEventKind.RescanRequired, _root);
                    ReplaceSnapshot(next);
                    break;
                case ScanKind.Incomplete:
                    // A partial traversal cannot prove a deletion. Keep the last complete snapshot and ask for an audit.
                    Emit(WorkspaceEventKind.RescanRequired, _root);
                    break;
                case ScanKind.RootUnavailable:
                    LoseRoot();
                    break;
            }
        }
    }

    private ScanKind ScanFiles(out Dictionary<PhysicalFileIdentity, FileState> files)
    {
        _fullScanObserver?.Invoke();
        files = [];
        if (!RootIsReadableDirectory()) return ScanKind.RootUnavailable;
        var incomplete = false;
        var pending = new Stack<string>();
        pending.Push(_root);
        while (pending.Count > 0)
        {
            var dir = pending.Pop();
            IEnumerable<FileSystemInfo> entries;
            try { entries = new DirectoryInfo(dir).EnumerateFileSystemInfos().ToList(); }
            catch (Exception e) when (e is DirectoryNotFoundException or FileNotFoundException) { continue; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { incomplete = true; continue; }

            foreach (var entry in entries)
            {
                try
                {
                    if (AtomicFile.IsTempName(entry.Name)) continue;
                    // Only symbolic links and junctions count as links; OneDrive placeholders are ordinary files.
                    if (entry.LinkTarget is not null) continue;
                    if (entry is DirectoryInfo) { pending.Push(entry.FullName); continue; }
                    if (!IsDocument(entry.FullName)) continue;
                    var info = (FileInfo)entry;
                    // Identity comes from the same pass as the other values: a second lookup can race a rename.
                    if (PhysicalFileIdentity.TryOfFile(info.FullName) is not { } identity) continue;
                    files[identity] = new FileState(identity, info.FullName, info.LastWriteTimeUtc, info.Length);
                }
                catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { incomplete = true; }
            }
        }
        if (!RootIsReadableDirectory()) return ScanKind.RootUnavailable;
        return incomplete ? ScanKind.Incomplete : ScanKind.Complete;
    }

    private bool RootIsReadableDirectory()
    {
        try
        {
            if (!Directory.Exists(_root)) return false;
            using var e = Directory.EnumerateFileSystemEntries(_root).GetEnumerator();
            e.MoveNext();
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return false; }
    }

    private bool IsDocument(string path) =>
        WorkspaceScanner.IsMarkdown(path)
        || (_includeText && Path.GetExtension(path).Equals(".txt", StringComparison.OrdinalIgnoreCase));

    private void ReplaceSnapshot(Dictionary<PhysicalFileIdentity, FileState> next)
    {
        _snapshot = next;
        _keyByPath = new Dictionary<string, PhysicalFileIdentity>(StringComparer.OrdinalIgnoreCase);
        foreach (var (id, state) in next) _keyByPath[state.Path] = id;
    }

    // ---- liveness -------------------------------------------------------------------------------

    private void CheckRoot()
    {
        lock (_gate)
        {
            if (_finished) return;
            if (!RootIsReadableDirectory()) LoseRoot();
        }
    }

    private void LoseRoot()
    {
        Emit(WorkspaceEventKind.AccessLost, _root);
        _snapshot = [];
        _keyByPath.Clear();
        Finish();
    }

    private void OnWatcherError(Exception error)
    {
        lock (_gate)
        {
            if (_finished) return;
            if (!RootIsReadableDirectory()) { LoseRoot(); return; }
            // Buffer overflow (InternalBufferOverflowException) or any other loss of detail: audit the tree.
            Emit(WorkspaceEventKind.RescanRequired, _root);
            ScheduleScan();
        }
    }

    // ---- raw event interpretation ---------------------------------------------------------------

    private void Handle(string rawPath, string? oldPath, WatcherChangeTypes change)
    {
        lock (_gate)
        {
            if (_finished) return;
            var path = SnapshotDiff.Standardize(rawPath);
            _rawEventObserver?.Invoke(path, change);
            if (SnapshotDiff.SamePath(path, _root)) return;

            if (Path.GetFileName(path) == ".gitignore" || (oldPath is not null && Path.GetFileName(oldPath) == ".gitignore"))
            {
                Emit(WorkspaceEventKind.RescanRequired, path);
                return;
            }

            if (change == WatcherChangeTypes.Renamed && oldPath is not null)
            {
                HandleRename(SnapshotDiff.Standardize(oldPath), path);
                return;
            }

            if (Directory.Exists(path)) { if (change != WatcherChangeTypes.Changed) ScheduleScan(); return; }
            if (!IsDocument(path))
            {
                // A deleted directory shows up as a path we cannot classify: audit when it held tracked files.
                if (change == WatcherChangeTypes.Deleted && HasTrackedBelow(path)) ScheduleScan();
                return;
            }
            HandleFile(path, change);
        }
    }

    private void HandleFile(string path, WatcherChangeTypes change)
    {
        var exists = File.Exists(path);
        var tracked = _keyByPath.ContainsKey(path);
        if (change == WatcherChangeTypes.Deleted && !exists)
        {
            if (tracked)
            {
                // A save that swaps files (rename to a displaced name, then rename the new file in) leaves the path
                // absent for an instant. Confirm shortly: a path that reappears is a modification, never a deletion.
                _pendingDeletes.Add(path);
                _deleteTimer.Change(DeleteConfirmation, Timeout.InfiniteTimeSpan);
            }
            else
            {
                // An incomplete scan cannot establish that this path was tracked. Reconcile with a full audit so an
                // unknown coalesced event never detaches a live buffer.
                Emit(WorkspaceEventKind.RescanRequired, _root);
                ScheduleScan();
            }
            return;
        }
        if (!exists) return;
        _pendingDeletes.Remove(path);
        // A delete event for a path that exists again is an atomic replacement at the same locator.
        UpdateEntry(path);
        Emit(change == WatcherChangeTypes.Created && !tracked ? WorkspaceEventKind.Created : WorkspaceEventKind.Modified, path);
    }

    private void ConfirmDeletes()
    {
        lock (_gate)
        {
            if (_finished) return;
            foreach (var path in _pendingDeletes.ToList())
            {
                if (File.Exists(path)) { UpdateEntry(path); Emit(WorkspaceEventKind.Modified, path); }
                else if (_keyByPath.ContainsKey(path)) { RemoveEntry(path); Emit(WorkspaceEventKind.Deleted, path); }
            }
            _pendingDeletes.Clear();
        }
    }

    private void HandleRename(string oldPath, string newPath)
    {
        if (Directory.Exists(newPath)) { ScheduleScan(); return; }
        var oldDoc = IsDocument(oldPath);
        var newDoc = IsDocument(newPath);
        if (!newDoc)
        {
            // Renamed away from a document name (to a backup or temp name): the document is gone unless replaced.
            if (oldDoc) HandleFile(oldPath, WatcherChangeTypes.Deleted);
            return;
        }
        if (!oldDoc)
        {
            // Temp file renamed onto a document name: the usual atomic save.
            HandleFile(newPath, WatcherChangeTypes.Created);
            return;
        }
        if (!_keyByPath.TryGetValue(oldPath, out var oldId))
        {
            HandleFile(newPath, WatcherChangeTypes.Created);
            return;
        }
        var newId = PhysicalFileIdentity.TryOfFile(newPath);
        if (newId is null)
        {
            HandleFile(oldPath, WatcherChangeTypes.Deleted);
            return;
        }
        if (_keyByPath.ContainsKey(newPath) && !SnapshotDiff.SamePath(oldPath, newPath))
        {
            // Renamed over a tracked document: that locator now holds new content.
            RemoveEntry(oldPath);
            UpdateEntry(newPath);
            Emit(WorkspaceEventKind.Deleted, oldPath);
            Emit(WorkspaceEventKind.Modified, newPath);
            return;
        }
        if (newId.Equals(oldId))
        {
            RemoveEntry(oldPath);
            UpdateEntry(newPath);
            Emit(WorkspaceEventKind.Moved, newPath, oldPath);
            return;
        }
        // Different identity at a new name: treat as delete + create and let the next audit reconcile moves.
        RemoveEntry(oldPath);
        UpdateEntry(newPath);
        Emit(WorkspaceEventKind.Deleted, oldPath);
        Emit(WorkspaceEventKind.Created, newPath);
    }

    private bool HasTrackedBelow(string directory)
    {
        var prefix = directory + Path.DirectorySeparatorChar;
        return _keyByPath.Keys.Any(p => p.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));
    }

    private void UpdateEntry(string path)
    {
        // Same-pass identity read: a file that vanished fails the whole read rather than yielding a path identity.
        FileInfo info;
        PhysicalFileIdentity? identity;
        try
        {
            info = new FileInfo(path);
            if (!info.Exists || info.LinkTarget is not null) return;
            identity = PhysicalFileIdentity.TryOfFile(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; }
        if (identity is null) return;
        RemoveEntry(path);
        _snapshot[identity] = new FileState(identity, path, info.LastWriteTimeUtc, info.Length);
        _keyByPath[path] = identity;
    }

    private void RemoveEntry(string path)
    {
        if (!_keyByPath.Remove(path, out var key)) return;
        _snapshot.Remove(key);
    }

    // ---- emission -------------------------------------------------------------------------------

    private void Emit(WorkspaceEventKind kind, string? path, string? previous = null)
    {
        // Losing even one detailed event could skip external-edit reconciliation. When the channel is full the
        // oldest event is dropped, so leave a full-audit marker in the newest slot. Repeated overflow keeps
        // replacing older detail with another marker. Emit runs under the gate and readers only shrink the count.
        var overflow = _channel.Reader.CanCount && _channel.Reader.Count >= EventCapacity;
        _channel.Writer.TryWrite(new WorkspaceEvent(_workspaceId, kind, path, previous));
        if (overflow && kind != WorkspaceEventKind.RescanRequired)
            _channel.Writer.TryWrite(new WorkspaceEvent(_workspaceId, WorkspaceEventKind.RescanRequired, _root));
    }

    private void Finish()
    {
        if (_finished) return;
        _finished = true;
        try { _watcher.EnableRaisingEvents = false; } catch (ObjectDisposedException) { }
        _scanTimer.Change(Timeout.Infinite, Timeout.Infinite);
        _deleteTimer.Change(Timeout.Infinite, Timeout.Infinite);
        _liveness.Change(Timeout.Infinite, Timeout.Infinite);
        _channel.Writer.TryComplete();
    }
}
