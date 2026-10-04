namespace Clio.Core;

/// <summary>
/// Containment and link checks for recovery code that acts on paths read from manifests. Only symbolic
/// links and junctions count as links: cloud placeholders (OneDrive) are reparse points but ordinary files.
/// </summary>
internal static class PathSafety
{
    private static readonly StringComparison Cmp = StringComparison.OrdinalIgnoreCase;

    public static string Normalize(string path) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    public static bool IsAbsent(string path)
    {
        try { File.GetAttributes(path); return false; }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { return true; }
        catch (Exception) { return false; }
    }

    public static bool IsLink(string path)
    {
        if (IsAbsent(path)) return false;
        try { return new FileInfo(path).LinkTarget is not null; }
        catch (IOException) { return false; }
    }

    /// <summary>True when the parent directory of <paramref name="path"/> is <paramref name="root"/> or below it.</summary>
    public static bool IsContained(string path, string root)
    {
        var parent = Path.GetDirectoryName(Normalize(path));
        if (parent is null) return false;
        var r = Normalize(root);
        return parent.Equals(r, Cmp) || parent.StartsWith(r + Path.DirectorySeparatorChar, Cmp);
    }

    public static bool HasLinkBetween(string path, string root)
    {
        var r = Normalize(root);
        for (var dir = Path.GetDirectoryName(Normalize(path)); dir is not null && !dir.Equals(r, Cmp); dir = Path.GetDirectoryName(dir))
            if (IsLink(dir)) return true;
        return false;
    }

    public static bool IsSafeRegularFile(string path, string root) =>
        IsContained(path, root) && !HasLinkBetween(path, root) && File.Exists(path) && !IsLink(path);

    public static bool SameDirectory(string a, string b) =>
        string.Equals(Path.GetDirectoryName(Normalize(a)), Path.GetDirectoryName(Normalize(b)), Cmp);

    /// <summary>Files named like <paramref name="pattern"/> under <paramref name="root"/>, never descending into links.</summary>
    public static IEnumerable<string> EnumerateManifests(string root, string pattern, bool recursive)
    {
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0)
        {
            var dir = pending.Pop();
            IEnumerable<string> files;
            try { files = Directory.EnumerateFiles(dir, pattern).ToList(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
            foreach (var f in files) yield return f;
            if (!recursive) continue;
            IEnumerable<string> subs;
            try { subs = Directory.EnumerateDirectories(dir).ToList(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
            foreach (var s in subs) if (!IsLink(s)) pending.Push(s);
        }
    }
}
