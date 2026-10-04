using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Clio.Core;

public enum RecoveryReason
{
    DirtyBuffer,
    SaveFailed,
    ExternalConflict,
    ExternalDeletion,
    AtomicCandidate,
    AtomicDisplaced,
    InterruptedMove,
}

public readonly record struct BufferGeneration(Guid BufferId, ulong Revision);

public sealed record CrashRecoveryRecord(
    Guid Id,
    Guid DocumentId,
    BufferGeneration Generation,
    string Filename,
    string? TargetPath,
    RecoveryReason Reason,
    DateTimeOffset CreatedAt,
    byte[] Data,
    string ContentDigest)
{
    public static CrashRecoveryRecord Create(
        Guid documentId, BufferGeneration generation, string filename, string? targetPath,
        RecoveryReason reason, byte[] data, DateTimeOffset? createdAt = null, Guid? id = null) =>
        new(id ?? Guid.NewGuid(), documentId, generation, filename,
            targetPath is null ? null : Path.GetFullPath(targetPath), reason,
            createdAt ?? DateTimeOffset.UtcNow, data, DiskRevision.Digest(data));
}

/// <summary>Cheap hand-off from the UI thread: UTF-8 conversion and hashing happen when the journal drains.</summary>
public sealed record CrashRecoverySnapshot(
    Guid DocumentId, BufferGeneration Generation, string Filename, string? TargetPath,
    RecoveryReason Reason, string Source, DateTimeOffset? CreatedAt = null, Guid? Id = null)
{
    public CrashRecoveryRecord ToRecord() =>
        CrashRecoveryRecord.Create(DocumentId, Generation, Filename, TargetPath, Reason, Encoding.UTF8.GetBytes(Source), CreatedAt, Id);
}

/// <summary>
/// App-owned durable storage for editor generations not yet known to exist at their canonical path.
/// Records are append-only; a partial pending write never replaces an older valid generation, and a
/// file that does not validate is ignored but never deleted. Contract: spec/vectors/recovery-journal.json.
/// </summary>
public sealed class CrashRecoveryJournal
{
    public const long MaximumRecordByteCount = 64L * 1024 * 1024;
    public const string RecordExtension = ".clio-recovery";
    private const long MaximumFileByteCount = MaximumRecordByteCount / 3 * 4 + 64 * 1024; // base64 plus envelope
    private static readonly TimeSpan DrainDelay = TimeSpan.FromMilliseconds(10);

    internal static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static string DefaultRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Clio", "Crash Recovery");

    private readonly object _io = new();
    private readonly object _drain = new();
    private readonly object _state = new();
    private readonly Dictionary<Guid, CrashRecoverySnapshot> _pending = [];
    private readonly Dictionary<Guid, Exception> _errors = [];
    private bool _drainScheduled;

    public string Root { get; }

    /// <summary>Raised with the document id and null on success or a message on failure.</summary>
    public event Action<Guid, string?>? StatusChanged;

    public CrashRecoveryJournal(string? root = null) => Root = Path.GetFullPath(root ?? DefaultRoot);

    /// <summary>Queues the newest generation per document; an older revision than the one pending is dropped.</summary>
    public void Schedule(CrashRecoverySnapshot snapshot)
    {
        bool start;
        lock (_state)
        {
            if (_pending.TryGetValue(snapshot.DocumentId, out var current) && current.Generation.Revision > snapshot.Generation.Revision) return;
            _pending[snapshot.DocumentId] = snapshot;
            start = !_drainScheduled;
            _drainScheduled = true;
        }
        if (start) _ = Task.Delay(DrainDelay).ContinueWith(_ => Drain(), TaskScheduler.Default);
    }

    public string Checkpoint(CrashRecoveryRecord record)
    {
        if (record.Data.LongLength > MaximumRecordByteCount)
            throw new ClioException("Recovery record exceeds the 64 MiB journal limit.");
        lock (_io)
        {
            RemovePending(record.DocumentId, record.Generation.Revision);
            try
            {
                var path = Write(record);
                PruneSuperseded(record);
                Report(record.DocumentId, null);
                return path;
            }
            catch (Exception e)
            {
                Report(record.DocumentId, e);
                throw;
            }
        }
    }

    /// <summary>Writes whatever is pending and waits for any drain already in flight.</summary>
    public void Flush() => Drain();

    public Exception? LastError(Guid documentId)
    {
        lock (_state) return _errors.GetValueOrDefault(documentId);
    }

    public IReadOnlyList<CrashRecoveryRecord> ValidRecords()
    {
        lock (_io)
        {
            if (!Directory.Exists(Root)) return [];
            return [.. Directory.EnumerateFiles(Root).Select(ValidRecord).OfType<CrashRecoveryRecord>()
                .OrderBy(r => r.CreatedAt).ThenBy(r => r.Generation.Revision)];
        }
    }

    /// <summary>Drops dirty-buffer checkpoints of <paramref name="documentId"/> up to <paramref name="through"/>; other reasons stay.</summary>
    public void Clear(Guid documentId, ulong through)
    {
        lock (_io)
        {
            RemovePending(documentId, through);
            if (!Directory.Exists(Root)) return;
            foreach (var path in Directory.EnumerateFiles(Root))
                if (ValidRecord(path) is { Reason: RecoveryReason.DirtyBuffer } r && r.DocumentId == documentId && r.Generation.Revision <= through)
                    TryDelete(path);
        }
    }

    public void Remove(Guid recordId)
    {
        lock (_io)
        {
            if (!Directory.Exists(Root)) return;
            var needle = recordId.ToString("D");
            foreach (var path in Directory.EnumerateFiles(Root))
                if (Path.GetFileName(path).Contains(needle, StringComparison.OrdinalIgnoreCase) && ValidRecord(path)?.Id == recordId)
                    TryDelete(path);
        }
    }

    // ---- internals ------------------------------------------------------------------------------

    private void Drain()
    {
        lock (_drain)
        {
            while (true)
            {
                CrashRecoverySnapshot[] batch;
                lock (_state)
                {
                    batch = [.. _pending.Values];
                    _pending.Clear();
                    if (batch.Length == 0) { _drainScheduled = false; return; }
                }
                foreach (var snapshot in batch)
                {
                    var record = snapshot.ToRecord();
                    lock (_io)
                    {
                        try
                        {
                            Write(record);
                            PruneSuperseded(record);
                            Report(record.DocumentId, null);
                        }
                        catch (Exception e) { Report(record.DocumentId, e); }
                    }
                }
            }
        }
    }

    private void RemovePending(Guid documentId, ulong upTo)
    {
        lock (_state)
            if (_pending.TryGetValue(documentId, out var p) && p.Generation.Revision <= upTo) _pending.Remove(documentId);
    }

    private void Report(Guid documentId, Exception? error)
    {
        lock (_state)
        {
            if (error is null) _errors.Remove(documentId); else _errors[documentId] = error;
        }
        StatusChanged?.Invoke(documentId, error?.Message);
    }

    private string Write(CrashRecoveryRecord record)
    {
        Directory.CreateDirectory(Root);
        var stem = $"buffer-{record.DocumentId:D}-{record.Generation.Revision}-{record.Id:D}";
        var pending = Path.Combine(Root, $".{stem}.pending");
        var final = Path.Combine(Root, stem + RecordExtension);

        if (File.Exists(final) && ValidRecord(final) is { } existing && existing.Id == record.Id && existing.ContentDigest == record.ContentDigest)
            return final;

        var bytes = JsonSerializer.SerializeToUtf8Bytes(record, Json);
        try
        {
            using (var stream = new FileStream(pending, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(pending, final, overwrite: false);
        }
        catch
        {
            TryDelete(pending);
            throw;
        }
        return final;
    }

    private void PruneSuperseded(CrashRecoveryRecord newest)
    {
        if (newest.Reason != RecoveryReason.DirtyBuffer) return;
        foreach (var path in Directory.EnumerateFiles(Root))
            if (ValidRecord(path) is { } r && r.DocumentId == newest.DocumentId && r.Id != newest.Id
                && r.Reason == RecoveryReason.DirtyBuffer && r.Generation.Revision <= newest.Generation.Revision)
                File.Delete(path);
    }

    private CrashRecoveryRecord? ValidRecord(string path)
    {
        try
        {
            if (!PathSafety.SameDirectory(path, Path.Combine(Root, "x")) || PathSafety.IsLink(path)) return null;
            var info = new FileInfo(path);
            if (!info.Exists || info.Length > MaximumFileByteCount) return null;
            var record = JsonSerializer.Deserialize<CrashRecoveryRecord>(File.ReadAllBytes(path), Json);
            return record is { Data: not null } && record.ContentDigest == DiskRevision.Digest(record.Data) ? record : null;
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException)
        {
            return null;
        }
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
