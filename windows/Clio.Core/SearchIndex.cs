using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using Microsoft.Data.Sqlite;

namespace Clio.Core;

/// <summary>
/// SQLite FTS5 search over workspace documents (macOS <c>SQLiteSearchIndex</c>). The database is a disposable
/// cache: authoritative document ids live in <see cref="DocumentIdentityStore"/>. Queries follow
/// <c>spec/vectors/search-queries.json</c>: at most 500 results, a quick unranked first batch, then a ranked final one.
/// Not yet ported: the ignored-file tier and discovery policy (the Windows scanner has no ignore reasons to store).
/// </summary>
public sealed class SearchIndex : IDisposable
{
    public const long MaximumIndexedFileBytes = 50L * 1024 * 1024;
    private const int FirstBatchLimit = 20;

    private enum QueryMode { Filename, Content }

    private readonly SqliteConnection _db;
    private readonly object _dbLock = new();
    private readonly DocumentIdentityStore _identities;
    private readonly bool _ownsIdentities;
    private readonly Func<string, FileSnapshot> _snapshot;
    private readonly bool _includeText;
    private List<WorkspaceDescriptor> _workspaces = [];
    private long _operation;

    public static string DefaultDatabasePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Clio", "SearchIndex.sqlite3");

    public SearchIndex(string? databasePath = null, DocumentIdentityStore? identities = null, Func<string, FileSnapshot>? snapshot = null, bool includeTextFiles = false)
    {
        databasePath ??= DefaultDatabasePath;
        _identities = identities ?? new DocumentIdentityStore(DocumentIdentityStore.DefaultStoragePath);
        _ownsIdentities = identities is null;
        _snapshot = snapshot ?? ReadSnapshot;
        _includeText = includeTextFiles;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(databasePath))!);
            _db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = databasePath, Pooling = false }.ToString());
            _db.Open();
            Configure();
        }
        catch (Exception e) when (e is SqliteException or IOException or UnauthorizedAccessException)
        {
            throw new SearchIndexException($"Could not open Clio's search index: {e.Message}", e);
        }
    }

    public void Dispose()
    {
        lock (_dbLock) _db.Dispose();
        if (_ownsIdentities) _identities.Dispose();
    }

    // ---- indexing -------------------------------------------------------------------------------

    /// <summary>
    /// Replaces the index with the current contents of <paramref name="workspaces"/>. Scanning happens outside the
    /// database lock, so searches keep reading the previous index until the new one commits in one transaction.
    /// A newer rebuild or update that starts meanwhile cancels this one.
    /// </summary>
    public async Task RebuildAsync(IReadOnlyList<WorkspaceDescriptor> workspaces, CancellationToken ct = default)
    {
        var operation = Interlocked.Increment(ref _operation);
        var distinct = DistinctRoots(workspaces);
        var scanned = new List<(WorkspaceDescriptor Workspace, IReadOnlyList<WorkspaceFile> Files)>();
        foreach (var workspace in distinct)
        {
            ct.ThrowIfCancellationRequested();
            var files = await Task.Run(() => WorkspaceScanner.ScanFiles(workspace.Id, workspace.RootPath, _identities, _includeText), ct);
            scanned.Add((workspace, files));
        }
        ct.ThrowIfCancellationRequested();
        if (Interlocked.Read(ref _operation) != operation) throw new OperationCanceledException();

        // Read every document before taking the lock; only inserts run inside the transaction.
        var rows = new List<Row>();
        foreach (var (workspace, files) in scanned)
            foreach (var file in files)
            {
                ct.ThrowIfCancellationRequested();
                if (TryRead(file.DocumentId, workspace, file.RelativePath, file.Path, file.ByteCount) is { } row) rows.Add(row);
            }
        ct.ThrowIfCancellationRequested();

        lock (_dbLock)
        {
            Transaction(() =>
            {
                Execute("DELETE FROM documents");
                foreach (var row in rows) Insert(row);
            });
            _workspaces = distinct;
        }
    }

    /// <summary>
    /// Applies watcher events: moves and deletions reconcile document identity first, then the affected rows are
    /// refreshed from disk. Events that cannot be applied precisely (<c>.gitignore</c>, folders, overflow markers) rebuild.
    /// Access failures are lifecycle signals, not index mutations: the last durable index stays queryable.
    /// </summary>
    public async Task ApplyAsync(IReadOnlyList<WorkspaceEvent> events, CancellationToken ct = default)
    {
        var relevant = events.Where(e => e.Kind is not (WorkspaceEventKind.AccessLost or WorkspaceEventKind.Error)).ToList();
        if (relevant.Count == 0) return;
        List<WorkspaceDescriptor> indexed;
        lock (_dbLock) indexed = _workspaces;
        var affectedIds = relevant.Select(e => e.WorkspaceId).ToHashSet();
        var affected = indexed.Where(w => affectedIds.Contains(w.Id)).ToList();
        if (affected.Count == 0) return;

        foreach (var e in relevant)
            if (affected.FirstOrDefault(w => w.Id == e.WorkspaceId) is { } workspace) ReconcileIdentity(e, workspace);

        if (relevant.Any(RequiresFullRebuild))
        {
            await RebuildAsync(indexed, ct);
            return;
        }

        var operation = Interlocked.Increment(ref _operation);
        var updates = new List<Update>();
        foreach (var e in relevant)
        {
            ct.ThrowIfCancellationRequested();
            if (affected.FirstOrDefault(w => w.Id == e.WorkspaceId) is not { } workspace) continue;
            var previous = e.PreviousPath is null ? null : RelativePath(e.PreviousPath, workspace);
            var current = e.Path is null ? null : RelativePath(e.Path, workspace);
            Row? row = null;
            if (e.Path is not null && e.Kind != WorkspaceEventKind.Deleted && IsSupported(e.Path) && current is not null)
            {
                // Notifications race real disk activity: a path that vanished during inspection is a deletion, so
                // stale search results cannot survive an atomic replace.
                row = await Task.Run(() => RowFor(workspace, current, e.Path), ct);
            }
            updates.Add(new Update(workspace, previous ?? (e.Kind == WorkspaceEventKind.Deleted ? current : null),
                e.Kind == WorkspaceEventKind.Moved ? previous : null, row, current));
        }
        ct.ThrowIfCancellationRequested();
        if (Interlocked.Read(ref _operation) != operation) throw new OperationCanceledException();

        lock (_dbLock)
        {
            Transaction(() =>
            {
                foreach (var u in updates)
                {
                    if (u.Removed is not null) Delete(u.Workspace.Id, u.Removed);
                    if (u.MovedFrom is not null && u.Row is not null) Delete(u.Workspace.Id, u.Row.RelativePath);
                    if (u.Row is not null) Insert(u.Row);
                    else if (u.Current is not null) Delete(u.Workspace.Id, u.Current);
                }
            });
        }
    }

    private sealed record Update(WorkspaceDescriptor Workspace, string? Removed, string? MovedFrom, Row? Row, string? Current);

    private sealed record Row(Guid DocumentId, Guid WorkspaceId, string RelativePath, string Content, double Modified, long ByteCount);

    private Row? RowFor(WorkspaceDescriptor workspace, string relative, string path)
    {
        FileInfo info;
        try
        {
            info = new FileInfo(path);
            if (!info.Exists) return null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
        if (PhysicalFileIdentity.TryOfFile(path) is not { } physical) return null;
        var id = _identities.Resolve(new DocumentIdentityCandidate(new DocumentLocator(workspace.Id, relative), physical, path));
        return TryRead(id, workspace, relative, path, info.Length);
    }

    private Row? TryRead(Guid id, WorkspaceDescriptor workspace, string relative, string path, long scannedBytes)
    {
        if (scannedBytes > MaximumIndexedFileBytes) return null;
        FileSnapshot snapshot;
        try { snapshot = _snapshot(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ClioException) { return null; }
        // The scanner's size check can race a writer: the snapshot revision is the truth.
        if (snapshot.Data.LongLength > MaximumIndexedFileBytes) return null;
        string content;
        try
        {
            var data = snapshot.Data;
            var skip = data.AsSpan().StartsWith("﻿"u8) ? 3 : 0;
            content = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(data, skip, data.Length - skip);
        }
        catch (DecoderFallbackException) { return null; }
        return new Row(id, workspace.Id, relative, content, snapshot.Revision.Modified.ToUnixTimeMilliseconds() / 1000.0, snapshot.Revision.ByteCount);
    }

    /// <summary>Refuses links, so a file repointed after the scanner's metadata check is never indexed.</summary>
    internal static FileSnapshot ReadSnapshot(string path) => FileSnapshots.Read(path);

    private void ReconcileIdentity(WorkspaceEvent e, WorkspaceDescriptor workspace)
    {
        switch (e.Kind)
        {
            case WorkspaceEventKind.Moved:
                if (e.PreviousPath is null || e.Path is null
                    || RelativePath(e.PreviousPath, workspace) is not { } from
                    || RelativePath(e.Path, workspace) is not { } to) return;
                _identities.Migrate(new DocumentLocator(workspace.Id, from), new DocumentLocator(workspace.Id, to),
                    PhysicalFileIdentity.TryOfFile(e.Path), e.Path);
                break;
            case WorkspaceEventKind.Deleted:
                if (e.Path is null || RelativePath(e.Path, workspace) is not { } path) return;
                if (IsSupported(e.Path)) _identities.Tombstone(new DocumentLocator(workspace.Id, path));
                else _identities.TombstoneDescendants(workspace.Id, path);
                break;
        }
    }

    private bool RequiresFullRebuild(WorkspaceEvent e)
    {
        if (e.Kind is WorkspaceEventKind.RootChanged or WorkspaceEventKind.RescanRequired) return true;
        var paths = new[] { e.Path, e.PreviousPath }.OfType<string>().ToList();
        if (paths.Any(p => Path.GetFileName(p) == ".gitignore")) return true;
        if (paths.Any(Directory.Exists)) return true;
        return e.Kind == WorkspaceEventKind.Deleted && e.Path is { } deleted && !IsSupported(deleted);
    }

    private bool IsSupported(string path) => WorkspaceScanner.IsDocument(path, _includeText);

    private static string? RelativePath(string path, WorkspaceDescriptor workspace)
    {
        var root = SnapshotDiff.Standardize(workspace.RootPath);
        var full = SnapshotDiff.Standardize(path);
        if (!full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return null;
        return full[(root.Length + 1)..].Replace('\\', '/');
    }

    private static List<WorkspaceDescriptor> DistinctRoots(IReadOnlyList<WorkspaceDescriptor> workspaces)
    {
        var result = new List<WorkspaceDescriptor>();
        foreach (var candidate in workspaces)
        {
            var root = SnapshotDiff.Standardize(candidate.RootPath);
            if (result.Any(w => SnapshotDiff.SamePath(SnapshotDiff.Standardize(w.RootPath), root))) continue;
            result.Add(candidate);
        }
        return result;
    }

    // ---- searching ------------------------------------------------------------------------------

    /// <summary>Filename search: case-insensitive substring of the relative path, prefix matches first.</summary>
    public IAsyncEnumerable<SearchBatch> QuickOpenAsync(SearchQuery query, CancellationToken ct = default) =>
        Stream(query, QueryMode.Filename, ct);

    /// <summary>Content search over FTS5: an unranked first batch, then a ranked final batch.</summary>
    public IAsyncEnumerable<SearchBatch> SearchAsync(SearchQuery query, CancellationToken ct = default) =>
        Stream(query, QueryMode.Content, ct);

    private async IAsyncEnumerable<SearchBatch> Stream(SearchQuery query, QueryMode mode, [EnumeratorCancellation] CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var firstLimit = Math.Min(FirstBatchLimit, query.Limit);
        var first = Results(query, mode, firstLimit, prioritizesLatency: true, ct);
        // Content's early batch skips ranking, so even a short result list needs a ranked final batch; otherwise a
        // short query would expose provisional scores and order.
        var needsSettledPass = mode == QueryMode.Content ? first.Count > 0 : query.Limit > firstLimit && first.Count == firstLimit;
        yield return new SearchBatch(first, !needsSettledPass);
        if (!needsSettledPass) yield break;

        await Task.Yield();
        ct.ThrowIfCancellationRequested();
        yield return new SearchBatch(Results(query, mode, query.Limit, prioritizesLatency: false, ct), true);
    }

    private List<SearchResult> Results(SearchQuery query, QueryMode mode, int limit, bool prioritizesLatency, CancellationToken ct)
    {
        List<WorkspaceDescriptor> workspaces;
        List<SearchResult> results;
        lock (_dbLock)
        {
            workspaces = _workspaces;
            results = mode == QueryMode.Filename ? FilenameResults(query, limit, ct) : ContentResults(query, limit, prioritizesLatency, ct);
        }
        return query.WorkspaceFilter is null ? DeduplicatePhysicalFiles(results, workspaces) : results;
    }

    private List<SearchResult> FilenameResults(SearchQuery query, int limit, CancellationToken ct)
    {
        var like = SearchQueryText.EscapeLike(query.Text);
        var conditions = new List<string> { "relative_path LIKE $like ESCAPE '\\' COLLATE NOCASE" };
        var parameters = new List<(string, object)> { ("$like", "%" + like + "%") };
        if (query.WorkspaceFilter is { } filter) { conditions.Add("workspace_id = $workspace"); parameters.Add(("$workspace", filter.ToString("D"))); }
        if (!query.IncludesIgnored) conditions.Add("excluded_pattern IS NULL");
        parameters.Add(("$prefix", like + "%"));
        parameters.Add(("$limit", (long)limit));
        var sql = $"""
            SELECT document_id, workspace_id, relative_path
            FROM documents
            WHERE {string.Join(" AND ", conditions)}
            ORDER BY
                CASE WHEN relative_path LIKE $prefix ESCAPE '\' COLLATE NOCASE THEN 0 ELSE 1 END,
                length(relative_path),
                relative_path COLLATE NOCASE
            LIMIT $limit
            """;
        return Query(sql, parameters, ct, r =>
        {
            var path = r.GetString(2);
            var match = FindMatch(path, query.Text);
            return new SearchResult(Guid.Parse(r.GetString(0)), Guid.Parse(r.GetString(1)), path, null, match, match,
                path.StartsWith(query.Text, StringComparison.OrdinalIgnoreCase) ? 2 : 1);
        });
    }

    private List<SearchResult> ContentResults(SearchQuery query, int limit, bool prioritizesLatency, CancellationToken ct)
    {
        var terms = SearchQueryText.Terms(query.Text);
        if (SearchQueryText.FullTextQuery(terms) is not { } fts) return FilenameResults(query, limit, ct);

        var conditions = new List<string> { "documents_fts MATCH $fts" };
        var parameters = new List<(string, object)> { ("$fts", fts) };
        if (query.WorkspaceFilter is { } filter) { conditions.Add("d.workspace_id = $workspace"); parameters.Add(("$workspace", filter.ToString("D"))); }
        if (!query.IncludesIgnored) conditions.Add("d.excluded_pattern IS NULL");
        parameters.Add(("$limit", (long)limit));
        parameters.Add(("$first", terms[0]));
        var ordering = prioritizesLatency ? "documents_fts.rowid" : "bm25(documents_fts), d.relative_path COLLATE NOCASE";
        var score = prioritizesLatency ? "0.0" : "bm25(documents_fts)";
        var resultOrdering = prioritizesLatency ? "matches.document_rowid" : "matches.ranking, d.relative_path COLLATE NOCASE";
        // FTS stays the outer loop even with a workspace filter. Ordering by its rowid lets FTS stream the first
        // LIMIT directly. Only candidate ids and scores are materialized before excerpts are loaded.
        var sql = $"""
            WITH matches AS MATERIALIZED (
                SELECT documents_fts.rowid AS document_rowid, {score} AS ranking
                FROM documents_fts
                CROSS JOIN documents d ON d.rowid = documents_fts.rowid
                WHERE {string.Join(" AND ", conditions)}
                ORDER BY {ordering}
                LIMIT $limit
            )
            SELECT d.document_id, d.workspace_id, d.relative_path,
                   substr(d.content, max(1, instr(lower(d.content), lower($first)) - 240), 1024),
                   matches.ranking
            FROM matches
            CROSS JOIN documents d ON d.rowid = matches.document_rowid
            ORDER BY {resultOrdering}
            """;
        return Query(sql, parameters, ct, r =>
        {
            var excerpt = r.GetString(3);
            return new SearchResult(Guid.Parse(r.GetString(0)), Guid.Parse(r.GetString(1)), r.GetString(2), excerpt, null,
                FirstMatch(excerpt, terms), -r.GetDouble(4));
        });
    }

    private static List<SearchResult> DeduplicatePhysicalFiles(List<SearchResult> results, List<WorkspaceDescriptor> workspaces)
    {
        var roots = workspaces.ToDictionary(w => w.Id, w => SnapshotDiff.Standardize(w.RootPath));
        var positions = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var unique = new List<SearchResult>();
        foreach (var result in results)
        {
            if (!roots.TryGetValue(result.WorkspaceId, out var root)) continue;
            var physical = SnapshotDiff.Standardize(Path.Combine(root, result.RelativePath));
            if (positions.TryGetValue(physical, out var at))
            {
                // The same file through nested roots: attribute it to the most specific workspace.
                if (root.Length > roots[unique[at].WorkspaceId].Length) unique[at] = result;
            }
            else
            {
                positions[physical] = unique.Count;
                unique.Add(result);
            }
        }
        return unique;
    }

    private static TextSpan? FindMatch(string text, string needle)
    {
        if (needle.Length == 0) return null;
        var index = CultureInfo.InvariantCulture.CompareInfo.IndexOf(text.AsSpan(), needle.AsSpan(),
            CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace, out var length);
        return index < 0 ? null : new TextSpan(index, length);
    }

    private static TextSpan? FirstMatch(string excerpt, IReadOnlyList<string> terms) =>
        terms.Select(t => FindMatch(excerpt, t)).OfType<TextSpan>().Cast<TextSpan?>().MinBy(s => s!.Value.Start);

    // ---- sqlite ---------------------------------------------------------------------------------

    private void Configure()
    {
        DiscardLegacySchema();
        foreach (var sql in new[]
        {
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=NORMAL",
            "PRAGMA temp_store=MEMORY",
            "PRAGMA foreign_keys=ON",
            "PRAGMA recursive_triggers=ON",
            """
            CREATE TABLE IF NOT EXISTS documents (
                document_id TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                content TEXT NOT NULL,
                modification_time REAL NOT NULL,
                byte_count INTEGER NOT NULL,
                excluded_pattern TEXT,
                excluded_source TEXT,
                excluded_line INTEGER,
                excluded_builtin TEXT,
                PRIMARY KEY(workspace_id, relative_path)
            )
            """,
            "CREATE INDEX IF NOT EXISTS documents_path ON documents(workspace_id, relative_path COLLATE NOCASE)",
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
                relative_path,
                content,
                content = 'documents',
                content_rowid = 'rowid',
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """,
            """
            CREATE TRIGGER IF NOT EXISTS documents_fts_insert AFTER INSERT ON documents BEGIN
                INSERT INTO documents_fts(rowid, relative_path, content) VALUES (new.rowid, new.relative_path, new.content);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS documents_fts_delete AFTER DELETE ON documents BEGIN
                INSERT INTO documents_fts(documents_fts, rowid, relative_path, content) VALUES ('delete', old.rowid, old.relative_path, old.content);
            END
            """,
            """
            CREATE TRIGGER IF NOT EXISTS documents_fts_update AFTER UPDATE ON documents BEGIN
                INSERT INTO documents_fts(documents_fts, rowid, relative_path, content) VALUES ('delete', old.rowid, old.relative_path, old.content);
                INSERT INTO documents_fts(rowid, relative_path, content) VALUES (new.rowid, new.relative_path, new.content);
            END
            """,
        }) Execute(sql);
    }

    /// <summary>The index is a cache, so an incompatible older schema is dropped and rebuilt rather than migrated.</summary>
    private void DiscardLegacySchema()
    {
        using var command = _db.CreateCommand();
        command.CommandText = "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'documents'";
        var schema = (command.ExecuteScalar() as string)?.ToUpperInvariant();
        if (schema is null || !schema.Contains("DOCUMENT_ID TEXT PRIMARY KEY")) return;
        foreach (var sql in new[]
        {
            "DROP TRIGGER IF EXISTS documents_fts_insert", "DROP TRIGGER IF EXISTS documents_fts_delete",
            "DROP TRIGGER IF EXISTS documents_fts_update", "DROP TABLE IF EXISTS documents_fts", "DROP TABLE IF EXISTS documents",
        }) Execute(sql);
    }

    private void Transaction(Action body)
    {
        Execute("BEGIN IMMEDIATE TRANSACTION");
        try
        {
            body();
            Execute("COMMIT");
        }
        catch
        {
            try { Execute("ROLLBACK"); } catch (SqliteException) { }
            throw;
        }
    }

    private void Insert(Row row)
    {
        Delete(row.WorkspaceId, row.RelativePath);
        Execute("""
            INSERT OR REPLACE INTO documents (document_id, workspace_id, relative_path, content, modification_time, byte_count)
            VALUES ($id, $workspace, $path, $content, $modified, $bytes)
            """,
            ("$id", row.DocumentId.ToString("D")), ("$workspace", row.WorkspaceId.ToString("D")), ("$path", row.RelativePath),
            ("$content", row.Content), ("$modified", row.Modified), ("$bytes", row.ByteCount));
    }

    private void Delete(Guid workspaceId, string relativePath) =>
        Execute("DELETE FROM documents WHERE workspace_id = $workspace AND relative_path = $path",
            ("$workspace", workspaceId.ToString("D")), ("$path", relativePath));

    private void Execute(string sql, params (string Name, object Value)[] parameters)
    {
        try
        {
            using var command = _db.CreateCommand();
            command.CommandText = sql;
            foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
            command.ExecuteNonQuery();
        }
        catch (SqliteException e) { throw new SearchIndexException($"Clio's search index failed: {e.Message}", e); }
    }

    private List<SearchResult> Query(string sql, List<(string Name, object Value)> parameters, CancellationToken ct, Func<SqliteDataReader, SearchResult> read)
    {
        try
        {
            using var command = _db.CreateCommand();
            command.CommandText = sql;
            foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
            using var reader = command.ExecuteReader();
            var results = new List<SearchResult>();
            while (reader.Read())
            {
                ct.ThrowIfCancellationRequested();
                results.Add(read(reader));
            }
            return results;
        }
        catch (SqliteException e) { throw new SearchIndexException($"Clio's search index failed: {e.Message}", e); }
    }
}
