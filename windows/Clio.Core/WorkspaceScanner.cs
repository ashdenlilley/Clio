namespace Clio.Core;

public sealed record WorkspaceEntry(string Path, string Relative, bool IsDirectory);

/// <summary>Markdown files and folders under a root. Skips hidden entries, links, Clio sidecars and .gitignore matches.</summary>
public static class WorkspaceScanner
{
    public static bool IsMarkdown(string path) =>
        Path.GetExtension(path).Equals(".md", StringComparison.OrdinalIgnoreCase)
        || Path.GetExtension(path).Equals(".markdown", StringComparison.OrdinalIgnoreCase);

    public static IReadOnlyList<WorkspaceEntry> Scan(string root)
    {
        var rootFull = Path.GetFullPath(root);
        var result = new List<WorkspaceEntry>();
        Walk(rootFull, rootFull, [], result);
        return result;
    }

    private static void Walk(string root, string dir, List<GitIgnoreFile> inherited, List<WorkspaceEntry> result)
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
            if (!isDir && !IsMarkdown(entry.Name)) continue;

            var relative = System.IO.Path.GetRelativePath(root, entry.FullName).Replace('\\', '/');
            result.Add(new WorkspaceEntry(entry.FullName, relative, isDir));
            if (isDir) Walk(root, entry.FullName, rules, result);
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
