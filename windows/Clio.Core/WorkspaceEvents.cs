namespace Clio.Core;

public enum WorkspaceEventKind { Created, Modified, Moved, Deleted, RootChanged, RescanRequired, AccessLost, Error }

/// <summary>One observed change. Paths are absolute. <see cref="PreviousPath"/> is set only for moves.</summary>
public sealed record WorkspaceEvent(Guid WorkspaceId, WorkspaceEventKind Kind, string? Path, string? PreviousPath = null)
{
    public DateTimeOffset ObservedAt { get; init; } = DateTimeOffset.UtcNow;
}

/// <summary>What the watcher remembers about one document between scans.</summary>
internal sealed record FileState(PhysicalFileIdentity Identity, string Path, DateTime ModifiedUtc, long Length);

/// <summary>
/// Pure snapshot comparison (macOS <c>WorkspaceWatcher.emitChanges</c>), shared through
/// <c>spec/vectors/workspace-snapshot-diff.json</c>. Moves are found by identity, never by path guessing.
/// </summary>
internal static class SnapshotDiff
{
    public sealed record Change(WorkspaceEventKind Kind, string Path, string? PreviousPath = null);

    public static string Standardize(string path) => System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(path));

    public static List<Change> Compute(
        IReadOnlyDictionary<PhysicalFileIdentity, FileState> previous,
        IReadOnlyDictionary<PhysicalFileIdentity, FileState> next)
    {
        var changes = new List<Change>();
        var removed = previous.Where(p => !next.ContainsKey(p.Key)).ToDictionary(p => p.Key, p => p.Value);
        var inserted = next.Where(n => !previous.ContainsKey(n.Key)).ToDictionary(n => n.Key, n => n.Value);

        // Atomic replacement changes the file identity while the path stays. Pair those as modifications so an
        // open buffer is never marked deleted.
        foreach (var (oldId, old) in removed.ToList())
        {
            var match = inserted.FirstOrDefault(i => SamePath(i.Value.Path, old.Path));
            if (match.Value is null) continue;
            changes.Add(new Change(WorkspaceEventKind.Modified, match.Value.Path));
            removed.Remove(oldId);
            inserted.Remove(match.Key);
        }

        foreach (var (id, old) in previous)
        {
            if (!next.TryGetValue(id, out var current)) continue;
            if (!SamePath(old.Path, current.Path))
                changes.Add(new Change(WorkspaceEventKind.Moved, current.Path, old.Path));
            else if (old.ModifiedUtc != current.ModifiedUtc || old.Length != current.Length)
                changes.Add(new Change(WorkspaceEventKind.Modified, current.Path));
        }

        changes.AddRange(removed.Values.OrderBy(s => s.Path, StringComparer.Ordinal).Select(s => new Change(WorkspaceEventKind.Deleted, s.Path)));
        changes.AddRange(inserted.Values.OrderBy(s => s.Path, StringComparer.Ordinal).Select(s => new Change(WorkspaceEventKind.Created, s.Path)));
        return changes;
    }

    public static bool SamePath(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
}
