namespace Clio.Core;

public sealed record WorkspaceEntry(string Path, string Relative, bool IsDirectory);

/// <summary>Markdown files and folders under a root. Skips hidden entries, links, Clio sidecars and .gitignore matches.</summary>
public static class WorkspaceScanner
{
    public static bool IsMarkdown(string path) =>
        Path.GetExtension(path).Equals(".md", StringComparison.OrdinalIgnoreCase)
        || Path.GetExtension(path).Equals(".markdown", StringComparison.OrdinalIgnoreCase);

    public static bool IsDocument(string path, bool includeText) =>
        IsMarkdown(path) || (includeText && Path.GetExtension(path).Equals(".txt", StringComparison.OrdinalIgnoreCase));

    public static IReadOnlyList<WorkspaceEntry> Scan(string root, bool includeText = false)
    {
        var rootFull = Path.GetFullPath(root);
        var result = new List<WorkspaceEntry>();
        Walk(rootFull, rootFull, [], result, includeText);
        return result;
    }

    /// <summary>
    /// Documents under <paramref name="root"/> with the stable ids the identity store resolves for them in one batch,
    /// so a rename between scans keeps its id and a recreated path gets a new one.
    /// </summary>
    public static IReadOnlyList<WorkspaceFile> ScanFiles(Guid workspaceId, string root, DocumentIdentityStore identities, bool includeText = false)
    {
        var found = new List<(WorkspaceEntry Entry, FileInfo Info)>();
        foreach (var entry in Scan(root, includeText))
        {
            if (entry.IsDirectory) continue;
            try
            {
                var info = new FileInfo(entry.Path);
                if (info.Exists) found.Add((entry, info));
            }
            catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { }
        }

        var candidates = new List<DocumentIdentityCandidate>(found.Count);
        var kept = new List<(WorkspaceEntry Entry, FileInfo Info)>(found.Count);
        foreach (var item in found)
        {
            // The identity is read from the file itself; a file that vanished mid-scan is skipped, not path-keyed.
            if (PhysicalFileIdentity.TryOfFile(item.Entry.Path) is not { } physical) continue;
            candidates.Add(new DocumentIdentityCandidate(new DocumentLocator(workspaceId, item.Entry.Relative), physical, item.Entry.Path));
            kept.Add(item);
        }
        var ids = identities.Resolve(candidates);
        return [.. kept.Select((item, i) => new WorkspaceFile(ids[i], item.Entry.Path, item.Entry.Relative, item.Info.Length, item.Info.LastWriteTimeUtc))];
    }

    private static void Walk(string root, string dir, List<GitIgnoreFile> inherited, List<WorkspaceEntry> result, bool includeText)
    {
        var rules = inherited;
        var ignoreFile = System.IO.Path.Combine(dir, ".gitignore");
        if (File.Exists(ignoreFile))
        {
            rules = [.. inherited, new GitIgnoreFile(dir, File.ReadAllLines(ignoreFile))];
        }

        var entries = new DirectoryInfo(dir).EnumerateFileSystemInfos()
            .OrderBy(e => e.Name, StringComparer.OrdinalIgnoreCase);
        foreach (var entry in entries)
        {
            if (entry.Name.StartsWith('.') || AtomicFile.IsTempName(entry.Name)) continue;
            if (entry.LinkTarget is not null || entry.Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
            var isDir = entry is DirectoryInfo;
            if (rules.Any(r => r.Ignores(entry.FullName, isDir))) continue;
            if (!isDir && !IsDocument(entry.Name, includeText)) continue;

            var relative = System.IO.Path.GetRelativePath(root, entry.FullName).Replace('\\', '/');
            result.Add(new WorkspaceEntry(entry.FullName, relative, isDir));
            if (isDir) Walk(root, entry.FullName, rules, result, includeText);
        }
    }

    private sealed class GitIgnoreFile
    {
        private readonly string _baseDir;
        private readonly Ignore.Ignore _ignore = new();

        public GitIgnoreFile(string baseDir, IEnumerable<string> lines)
        {
            _baseDir = baseDir;
            _ignore.Add(lines);
        }

        public bool Ignores(string fullPath, bool isDirectory)
        {
            var rel = System.IO.Path.GetRelativePath(_baseDir, fullPath).Replace('\\', '/');
            if (rel.StartsWith("..", StringComparison.Ordinal)) return false;
            return _ignore.IsIgnored(isDirectory ? rel + "/" : rel);
        }
    }
}
