namespace Clio.App;

/// <summary>
/// Path helpers for choosing which workspace a file belongs to. Core's own checks (<c>PathSafety</c>, internal)
/// still decide what may be read or written; these only route.
/// </summary>
public static class AppPaths
{
    public static string Normalize(string path) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    /// <summary>NTFS is case-insensitive, so containment is too.</summary>
    public static bool IsContained(string path, string root)
    {
        var p = Normalize(path);
        var r = Normalize(root);
        return p.Length > r.Length &&
               p.StartsWith(r, StringComparison.OrdinalIgnoreCase) &&
               (p[r.Length] == Path.DirectorySeparatorChar || p[r.Length] == Path.AltDirectorySeparatorChar);
    }
}
