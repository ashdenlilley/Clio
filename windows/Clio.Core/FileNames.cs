using System.Globalization;
using System.Text;

namespace Clio.Core;

/// <summary>Contract: spec/vectors/file-names.json. macOS rules plus Windows-only hardening.</summary>
public static class FileNames
{
    public const string DefaultName = "untitled.md";
    public const int MaximumLength = 255;
    public const int MaximumCollisionAttempts = 10_000;

    private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³",
    };

    private const string Illegal = "/:\\*?\"<>|";

    public static string Safe(string suggestion)
    {
        var name = suggestion.TrimEnd('/', '\\');
        var cut = name.LastIndexOfAny(['/', '\\']);
        if (cut >= 0) name = name[(cut + 1)..];
        name = name.Trim();

        var cleaned = new StringBuilder(name.Length);
        foreach (var c in name)
            if (!char.IsControl(c) && !Illegal.Contains(c)) cleaned.Append(c);
        // Win32 strips trailing dots and spaces, so such a file would not round-trip.
        name = cleaned.ToString().TrimEnd(' ', '.');

        if (name.Length == 0 || name.StartsWith('.')) name = DefaultName;
        if (Path.GetExtension(name).Length == 0) name += ".md";

        var firstDot = name.IndexOf('.');
        var stem = (firstDot < 0 ? name : name[..firstDot]).TrimEnd();
        if (Reserved.Contains(stem)) name = "_" + name;

        return name.Length <= MaximumLength ? name : Truncate(name);
    }

    /// <summary>
    /// True for a single plain folder or file name: no separators, illegal or control characters, trailing dot or
    /// space, "." or "..", and no reserved device stem.
    /// </summary>
    public static bool IsSafeComponent(string name)
    {
        if (name.Length == 0 || name.Length > MaximumLength || name is "." or "..") return false;
        if (name.TrimEnd(' ', '.') != name) return false;
        if (name.Any(c => char.IsControl(c) || Illegal.Contains(c))) return false;
        var firstDot = name.IndexOf('.');
        return !Reserved.Contains((firstDot < 0 ? name : name[..firstDot]).TrimEnd());
    }

    private static string Truncate(string name)
    {
        var ext = Path.GetExtension(name);
        if (ext.Length > 32) ext = "";
        var room = MaximumLength - ext.Length;
        var stem = name[..(name.Length - ext.Length)];
        if (room < stem.Length && char.IsHighSurrogate(stem[room - 1])) room--;
        return stem[..room].TrimEnd(' ', '.') + ext;
    }

    /// <summary>First free name: <paramref name="name"/>, then "stem (2).ext", "stem (3).ext" and so on.</summary>
    public static string Available(string name, Func<string, bool> exists)
    {
        if (!exists(name)) return name;
        var ext = Path.GetExtension(name);
        var stem = name[..(name.Length - ext.Length)];
        for (var n = 2; n <= MaximumCollisionAttempts; n++)
        {
            var candidate = $"{stem} ({n}){ext}";
            if (!exists(candidate)) return candidate;
        }
        throw new ClioException($"No available file name for {name}.");
    }

    /// <summary>NTFS is case-insensitive and treats both slashes alike; identity keys must too.</summary>
    public static string Fold(string path) => path.Replace('\\', '/').ToUpperInvariant();

    internal static string Stamp(DateTimeOffset when) =>
        when.UtcDateTime.ToString("yyyy-MM-dd HH-mm-ss", CultureInfo.InvariantCulture);
}
