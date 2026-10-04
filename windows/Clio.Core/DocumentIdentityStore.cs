using System.Text.Json;

namespace Clio.Core;

/// <summary>
/// Persistent identity authority, kept apart from the disposable search index. One document may have several
/// locator aliases (overlapping roots); tombstones make a new file at a deleted path get a new id.
/// Locators and canonical paths are case-folded because NTFS is case-insensitive.
/// Contract: spec/vectors/document-identity.json.
/// </summary>
public sealed class DocumentIdentityStore : IDisposable
{
    public const int MaximumRetainedTombstones = 1024;
    public const long MaximumStorageByteCount = 16L * 1024 * 1024;
    private static readonly TimeSpan PersistDelay = TimeSpan.FromMilliseconds(100);

    public static string DefaultStoragePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Clio", "DocumentIdentities.json");

    public sealed record Statistics(int Locators, int PhysicalFiles, int Tombstones);

    private sealed class State
    {
        public Dictionary<string, Guid> Locators { get; set; } = [];
        public Dictionary<string, Guid> PhysicalFiles { get; set; } = [];
        public Dictionary<string, string> PhysicalPaths { get; set; } = [];
        public Dictionary<string, Guid> Tombstones { get; set; } = [];
        public List<string> TombstoneOrder { get; set; } = [];
    }

    private readonly object _lock = new();
    private readonly object _persistLock = new();
    private readonly string? _storagePath;
    private readonly Action<byte[], string> _writer;
    private readonly Func<string, bool> _pathExists;
    private readonly State _state = new();
    // Derived reverse index: rebuilt on load, never persisted, so older stores migrate by themselves.
    private readonly Dictionary<string, string> _keyByPath = [];
    private readonly Exception? _startupError;
    private Timer? _timer;
    private object? _pendingToken;
    private Exception? _backgroundError;

    /// <param name="pathExists">Whether a folded canonical path still exists on disk. Injectable so tests need no filesystem.</param>
    public DocumentIdentityStore(string? storagePath = null, Action<byte[], string>? writer = null, Func<string, bool>? pathExists = null)
    {
        _storagePath = storagePath;
        _writer = writer ?? WriteFile;
        _pathExists = pathExists ?? File.Exists;
        if (storagePath is null || !File.Exists(storagePath)) return;
        try
        {
            if (new FileInfo(storagePath).Length > MaximumStorageByteCount) throw new IdentityStoreException(storagePath);
            var stored = JsonSerializer.Deserialize<State>(File.ReadAllBytes(storagePath), CrashRecoveryJournal.Json)
                ?? throw new IdentityStoreException(storagePath);
            _state = Normalize(stored);
            RebuildPathIndex();
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or IdentityStoreException or NotSupportedException)
        {
            _state = new State();
            _keyByPath.Clear();
            _startupError = new IdentityStoreException(storagePath);
        }
    }

    public Guid Resolve(DocumentIdentityCandidate candidate) => Resolve([candidate])[0];

    public IReadOnlyList<Guid> Resolve(IReadOnlyList<DocumentIdentityCandidate> candidates)
    {
        lock (_lock)
        {
            ThrowIfUnreadable();
            var changed = false;
            // Update every observed path first so one scan can tell a moved live file from a new file
            // that reused its old path, whatever the traversal order.
            if (ReconcileObservedPaths(candidates)) changed = true;

            var physicalsByDocument = new Dictionary<Guid, List<(string Key, string Path)>>();
            foreach (var (key, id) in _state.PhysicalFiles)
            {
                if (!_state.PhysicalPaths.TryGetValue(key, out var path)) continue;
                if (!physicalsByDocument.TryGetValue(id, out var list)) physicalsByDocument[id] = list = [];
                list.Add((key, path));
            }

            var identifiers = new List<Guid>(candidates.Count);
            foreach (var candidate in candidates)
            {
                var locatorKey = Key(candidate.Locator);
                var physicalKey = candidate.Physical is null ? null : Key(candidate.Physical);
                var path = candidate.CanonicalPath is null ? null : FileNames.Fold(candidate.CanonicalPath);

                Guid? tombstoned = _state.Tombstones.TryGetValue(locatorKey, out var t) ? t : null;
                Guid? physicalId = physicalKey is not null && _state.PhysicalFiles.TryGetValue(physicalKey, out var p) ? p : null;
                if (tombstoned is not null && physicalId == tombstoned)
                {
                    // The file id of a deleted document was reused: it is a new document.
                    RemovePhysical(physicalKey!);
                    physicalId = null;
                    changed = true;
                }

                Guid? locatorId = tombstoned is null && _state.Locators.TryGetValue(locatorKey, out var l) ? l : null;
                if (locatorId is { } known && path is not null
                    && physicalsByDocument.TryGetValue(known, out var alive)
                    && alive.Any(a => a.Key != physicalKey && a.Path != path && _pathExists(a.Path)))
                {
                    // The old document is still alive at another path: this path is a recreation, not an alias.
                    locatorId = null;
                }

                Guid? proposed = null;
                if (candidate.PreferredId is { } preferred)
                {
                    if (physicalId == preferred || locatorId == preferred) proposed = preferred;
                    else if (!_state.PhysicalFiles.Any(kv => kv.Value == preferred && kv.Key != physicalKey)
                             && !_state.Locators.Any(kv => kv.Value == preferred && kv.Key != locatorKey))
                        proposed = preferred;
                }

                var winner = physicalId ?? locatorId ?? proposed ?? Guid.NewGuid();
                if (!_state.Locators.TryGetValue(locatorKey, out var current) || current != winner)
                {
                    _state.Locators[locatorKey] = winner;
                    changed = true;
                }
                if (physicalKey is not null && BindPhysical(physicalKey, winner, path))
                {
                    if (path is not null)
                    {
                        if (!physicalsByDocument.TryGetValue(winner, out var list)) physicalsByDocument[winner] = list = [];
                        list.Add((physicalKey, path));
                    }
                    changed = true;
                }
                if (RemoveTombstone(locatorKey)) changed = true;
                identifiers.Add(winner);
            }
            if (changed) PersistNow();
            return identifiers;
        }
    }

    /// <summary>Attaches an existing id to a locator (first save of an untitled document, overlap repair).</summary>
    public void Bind(Guid documentId, DocumentLocator locator, PhysicalFileIdentity? physical, string? canonicalPath = null)
    {
        lock (_lock)
        {
            ThrowIfUnreadable();
            var locatorKey = Key(locator);
            var changed = false;
            var immediate = false;
            if (!_state.Locators.TryGetValue(locatorKey, out var current) || current != documentId)
            {
                _state.Locators[locatorKey] = documentId;
                changed = immediate = true;
            }
            if (RemoveTombstone(locatorKey)) changed = immediate = true;
            if (physical is not null && BindPhysical(Key(physical), documentId, canonicalPath is null ? null : FileNames.Fold(canonicalPath)))
                changed = true;
            if (!changed) return;
            if (immediate) PersistNow(); else SchedulePersist();
        }
    }

    /// <summary>Moves an identity to a new locator and tombstones the old one.</summary>
    public Guid Migrate(DocumentLocator from, DocumentLocator to, PhysicalFileIdentity? physical, string? destinationPath = null, Guid? documentId = null)
    {
        lock (_lock)
        {
            ThrowIfUnreadable();
            var sourceKey = Key(from);
            var destinationKey = Key(to);
            var resolved = documentId
                ?? (_state.Locators.TryGetValue(sourceKey, out var s) ? s : (Guid?)null)
                ?? (physical is not null && _state.PhysicalFiles.TryGetValue(Key(physical), out var p) ? p : (Guid?)null)
                ?? Guid.NewGuid();
            _state.Locators.Remove(sourceKey);
            MarkTombstone(sourceKey, resolved);
            _state.Locators[destinationKey] = resolved;
            RemoveTombstone(destinationKey);
            if (physical is not null) BindPhysical(Key(physical), resolved, destinationPath is null ? null : FileNames.Fold(destinationPath));
            PruneOrphanedPhysicals();
            CompactTombstones();
            PersistNow();
            return resolved;
        }
    }

    public void Tombstone(DocumentLocator locator, Guid? documentId = null)
    {
        lock (_lock)
        {
            ThrowIfUnreadable();
            var key = Key(locator);
            Guid? previous = documentId ?? (_state.Locators.TryGetValue(key, out var existing) ? existing : null);
            var changed = _state.Locators.Remove(key);
            if (previous is { } id) changed = MarkTombstone(key, id) || changed;
            changed = PruneOrphanedPhysicals() || changed;
            changed = CompactTombstones() || changed;
            if (changed) PersistNow();
        }
    }

    /// <summary>Tombstones a folder's worth of locators after the folder is deleted or moved away.</summary>
    public void TombstoneDescendants(Guid workspaceId, string relativePath)
    {
        lock (_lock)
        {
            ThrowIfUnreadable();
            var prefix = workspaceId.ToString("D") + "\0";
            var folded = FileNames.Fold(relativePath);
            var directory = folded.EndsWith('/') ? folded : folded + "/";
            var keys = _state.Locators.Keys.Where(k =>
            {
                if (!k.StartsWith(prefix, StringComparison.Ordinal)) return false;
                var path = k[prefix.Length..];
                return path == folded || path.StartsWith(directory, StringComparison.Ordinal);
            }).ToList();
            if (keys.Count == 0) return;
            foreach (var key in keys)
            {
                var id = _state.Locators[key];
                _state.Locators.Remove(key);
                MarkTombstone(key, id);
            }
            PruneOrphanedPhysicals();
            CompactTombstones();
            PersistNow();
        }
    }

    public Guid? StoredDocumentId(DocumentLocator locator)
    {
        lock (_lock)
        {
            var key = Key(locator);
            return !_state.Tombstones.ContainsKey(key) && _state.Locators.TryGetValue(key, out var id) ? id : null;
        }
    }

    public Statistics GetStatistics()
    {
        lock (_lock) return new Statistics(_state.Locators.Count, _state.PhysicalFiles.Count, _state.Tombstones.Count);
    }

    /// <summary>Writes the latest complete state now. Call on shutdown and after a reported background failure.</summary>
    public void FlushPendingPersistence()
    {
        lock (_lock)
        {
            ThrowIfUnreadable();
            PersistNow();
        }
    }

    /// <summary>Background write failures are observable without taking the identity lock.</summary>
    public string? PersistenceFailureDescription()
    {
        lock (_persistLock) return _backgroundError?.Message;
    }

    public void Dispose()
    {
        lock (_persistLock)
        {
            _timer?.Dispose();
            _timer = null;
            _pendingToken = null;
        }
    }

    // ---- keys -----------------------------------------------------------------------------------

    private static string Key(DocumentLocator locator) => locator.WorkspaceId.ToString("D") + "\0" + FileNames.Fold(locator.RelativePath);

    private static string Key(PhysicalFileIdentity identity) => identity switch
    {
        PhysicalFileIdentity.Resource r => $"resource\0{r.Volume}\0{r.FileId}",
        PhysicalFileIdentity.ByPath p => $"path\0{FileNames.Fold(p.Path)}",
        _ => throw new ArgumentOutOfRangeException(nameof(identity)),
    };

    private void ThrowIfUnreadable()
    {
        if (_startupError is not null) throw _startupError;
    }

    // ---- physical file bookkeeping --------------------------------------------------------------

    private bool ReconcileObservedPaths(IReadOnlyList<DocumentIdentityCandidate> candidates)
    {
        var changed = false;
        var observedKeyByPath = new Dictionary<string, string>(candidates.Count);
        foreach (var candidate in candidates)
        {
            if (candidate.Physical is null || candidate.CanonicalPath is null) continue;
            var key = Key(candidate.Physical);
            var path = FileNames.Fold(candidate.CanonicalPath);
            observedKeyByPath[path] = key;
            if (!_state.PhysicalPaths.TryGetValue(key, out var known) || known != path)
            {
                _state.PhysicalPaths[key] = path;
                changed = true;
            }
        }

        var rebuilt = new Dictionary<string, string>(_state.PhysicalPaths.Count);
        var stale = new HashSet<string>();
        foreach (var (key, path) in _state.PhysicalPaths)
        {
            if (observedKeyByPath.TryGetValue(path, out var observed) && observed != key) stale.Add(key);
            else if (rebuilt.TryGetValue(path, out var existing) && existing != key)
            {
                var winner = observedKeyByPath.GetValueOrDefault(path, key);
                stale.Add(winner == key ? existing : key);
                rebuilt[path] = winner;
            }
            else rebuilt[path] = key;
        }
        foreach (var key in stale)
        {
            _state.PhysicalFiles.Remove(key);
            _state.PhysicalPaths.Remove(key);
            changed = true;
        }
        var filtered = rebuilt.Where(kv => !stale.Contains(kv.Value)).ToDictionary(kv => kv.Key, kv => kv.Value);
        if (_keyByPath.Count != filtered.Count || _keyByPath.Any(kv => !filtered.TryGetValue(kv.Key, out var v) || v != kv.Value))
        {
            _keyByPath.Clear();
            foreach (var (k, v) in filtered) _keyByPath[k] = v;
            changed = true;
        }
        return changed;
    }

    private bool BindPhysical(string key, Guid documentId, string? path)
    {
        var changed = false;
        if (path is not null && BindPhysicalPath(key, path)) changed = true;
        if (!_state.PhysicalFiles.TryGetValue(key, out var current) || current != documentId)
        {
            _state.PhysicalFiles[key] = documentId;
            changed = true;
        }
        return changed;
    }

    private bool BindPhysicalPath(string key, string path)
    {
        var changed = false;
        if (_state.PhysicalPaths.TryGetValue(key, out var old) && old != path && _keyByPath.TryGetValue(old, out var oldOwner) && oldOwner == key)
        {
            _keyByPath.Remove(old);
            changed = true;
        }
        if (_keyByPath.TryGetValue(path, out var superseded) && superseded != key)
        {
            RemovePhysical(superseded);
            changed = true;
        }
        if (!_state.PhysicalPaths.TryGetValue(key, out var current) || current != path)
        {
            _state.PhysicalPaths[key] = path;
            changed = true;
        }
        if (!_keyByPath.TryGetValue(path, out var owner) || owner != key)
        {
            _keyByPath[path] = key;
            changed = true;
        }
        return changed;
    }

    private void RemovePhysical(string key)
    {
        if (_state.PhysicalPaths.Remove(key, out var path) && _keyByPath.TryGetValue(path, out var owner) && owner == key)
            _keyByPath.Remove(path);
        _state.PhysicalFiles.Remove(key);
    }

    private bool PruneOrphanedPhysicals()
    {
        var live = new HashSet<Guid>(_state.Locators.Values);
        var stale = _state.PhysicalFiles.Where(kv => !live.Contains(kv.Value)).Select(kv => kv.Key).ToList();
        foreach (var key in stale) RemovePhysical(key);
        return stale.Count > 0;
    }

    private bool MarkTombstone(string key, Guid documentId)
    {
        var changed = !_state.Tombstones.TryGetValue(key, out var current) || current != documentId;
        _state.Tombstones[key] = documentId;
        _state.TombstoneOrder.RemoveAll(k => k == key);
        _state.TombstoneOrder.Add(key);
        return changed;
    }

    private bool RemoveTombstone(string key)
    {
        if (!_state.Tombstones.Remove(key)) return false;
        _state.TombstoneOrder.RemoveAll(k => k == key);
        return true;
    }

    private bool CompactTombstones()
    {
        var before = _state.TombstoneOrder.Count;
        _state.TombstoneOrder = [.. _state.TombstoneOrder.Where(_state.Tombstones.ContainsKey)];
        var changed = before != _state.TombstoneOrder.Count;
        while (_state.TombstoneOrder.Count > MaximumRetainedTombstones)
        {
            _state.Tombstones.Remove(_state.TombstoneOrder[0]);
            _state.TombstoneOrder.RemoveAt(0);
            changed = true;
        }
        return changed;
    }

    // ---- persistence ----------------------------------------------------------------------------

    private static State Normalize(State stored)
    {
        stored.Locators ??= [];
        stored.PhysicalFiles ??= [];
        stored.PhysicalPaths ??= [];
        stored.Tombstones ??= [];
        stored.TombstoneOrder ??= [.. stored.Tombstones.Keys];
        return stored;
    }

    /// <summary>Collapses duplicate path entries left by inode-swapping saves while loading.</summary>
    private void RebuildPathIndex()
    {
        foreach (var key in _state.PhysicalPaths.Keys.Order(StringComparer.Ordinal).ToList())
        {
            if (!_state.PhysicalPaths.TryGetValue(key, out var path)) continue;
            if (_keyByPath.TryGetValue(path, out var superseded) && superseded != key)
            {
                _state.PhysicalFiles.Remove(superseded);
                _state.PhysicalPaths.Remove(superseded);
            }
            _keyByPath[path] = key;
        }
    }

    private byte[] Serialize() => JsonSerializer.SerializeToUtf8Bytes(_state, CrashRecoveryJournal.Json);

    private void PersistNow()
    {
        if (_storagePath is null) return;
        lock (_persistLock)
        {
            _timer?.Dispose();
            _timer = null;
            _pendingToken = null;
        }
        var snapshot = Serialize();
        lock (_persistLock)
        {
            _writer(snapshot, _storagePath);
            _backgroundError = null;
        }
    }

    private void SchedulePersist()
    {
        if (_storagePath is null) return;
        var token = new object();
        lock (_persistLock)
        {
            _timer?.Dispose();
            _pendingToken = token;
            _timer = new Timer(_ => PersistInBackground(token), null, PersistDelay, Timeout.InfiniteTimeSpan);
        }
    }

    private void PersistInBackground(object token)
    {
        byte[] snapshot;
        lock (_lock)
        {
            lock (_persistLock)
            {
                if (_pendingToken != token) return;
                _pendingToken = null;
            }
            snapshot = Serialize();
        }
        lock (_persistLock)
        {
            try { _writer(snapshot, _storagePath!); _backgroundError = null; }
            catch (Exception e) { _backgroundError = e; }
        }
    }

    private static void WriteFile(byte[] data, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        AtomicFile.Write(path, data);
    }
}
