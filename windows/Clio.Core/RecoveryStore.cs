using System.Text;

namespace Clio.Core;

public sealed record RecoveryReceipt(Guid DocumentId, string RecoveryPath, DateTimeOffset CreatedAt, DateTimeOffset? SourceModified);

/// <summary>
/// Recovery copies of replaced or conflicting files in a user-visible folder, kept 7 days.
/// Contract: spec/vectors/recovery-store.json.
/// </summary>
public sealed class RecoveryStore
{
    public static readonly TimeSpan Retention = TimeSpan.FromDays(7);

    public static string PreferredRoot =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Clio Recovery");

    private readonly Func<DateTimeOffset> _now;

    public string Root { get; }

    public RecoveryStore(string? root = null, Func<DateTimeOffset>? now = null)
    {
        Root = Path.GetFullPath(root ?? PreferredRoot);
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public static string RecoveredName(string filename, DateTimeOffset stamp, Guid documentId)
    {
        var safe = FileNames.Safe(filename);
        var ext = Path.GetExtension(safe);
        var stem = safe[..(safe.Length - ext.Length)];
        var suffix = documentId.ToString("D").ToLowerInvariant()[..8];
        return $"{stem} — {FileNames.Stamp(stamp)} — {suffix}{ext}";
    }

    public RecoveryReceipt Preserve(Guid documentId, string filename, ReadOnlySpan<byte> data, DateTimeOffset? sourceModified = null)
    {
        var createdAt = _now();
        Directory.CreateDirectory(Root);
        PruneExpired(createdAt);

        var name = RecoveredName(filename, sourceModified ?? createdAt, documentId);
        var bytes = data.ToArray();
        for (var attempt = 0; attempt < FileNames.MaximumCollisionAttempts; attempt++)
        {
            name = FileNames.Available(name, n => PathExists(Path.Combine(Root, n)));
            var path = Path.Combine(Root, name);
            if (!AtomicFile.TryCreate(path, bytes)) continue; // lost a race for the name; take the next
            // Retention counts from when the copy was made, not from the source's age.
            File.SetLastWriteTimeUtc(path, createdAt.UtcDateTime);
            return new RecoveryReceipt(documentId, path, createdAt, sourceModified);
        }
        throw new ClioException($"No available recovery name for {filename}.");
    }

    public RecoveryReceipt Preserve(Guid documentId, string filename, string source, DateTimeOffset? date = null) =>
        Preserve(documentId, filename, Encoding.UTF8.GetBytes(source), date);

    public void PruneExpired(DateTimeOffset? now = null) => Prune((now ?? _now()) - Retention);

    /// <summary>Deletes regular, visible top-level files whose modification time is strictly before <paramref name="olderThan"/>.</summary>
    public void Prune(DateTimeOffset olderThan)
    {
        if (!Directory.Exists(Root)) return;
        foreach (var path in Directory.EnumerateFiles(Root))
        {
            var info = new FileInfo(path);
            if (info.Name.StartsWith('.') || info.Attributes.HasFlag(FileAttributes.Hidden) || info.LinkTarget is not null) continue;
            if (info.LastWriteTimeUtc >= olderThan.UtcDateTime) continue;
            // A copy held open by a scanner or the user is skipped; it is pruned next time.
            try { info.Delete(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }

    private static bool PathExists(string path) => !PathSafety.IsAbsent(path);
}
