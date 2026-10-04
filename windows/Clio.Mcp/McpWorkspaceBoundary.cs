using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Clio.Mcp;

/// <summary>
/// Canonical path defense in depth (macOS <c>MCPWorkspaceBoundary</c>). The host must still use its
/// authorized workspace API and revalidate at the operation's commit boundary.
///
/// Rules: no <c>..</c>, no device or extended-length prefixes, no alternate data streams, every existing
/// ancestor is checked, and no reparse point (junction or symlink) is followed or accepted inside the
/// approved root. Links above the root (for example a redirected Documents folder) are resolved.
/// A missing leaf, or a whole missing tail, is valid only after every existing ancestor has been checked.
/// </summary>
public static class McpWorkspaceBoundary
{
    public static void Validate(string file, string root)
    {
        if (string.IsNullOrEmpty(file) || string.IsNullOrEmpty(root) || file.Contains('\0') || root.Contains('\0'))
            throw Outside();
        if (!Path.IsPathFullyQualified(file) || !Path.IsPathFullyQualified(root)) throw Outside();
        if (IsDevicePath(file) || IsDevicePath(root)) throw Outside();
        if (file.Split('\\', '/').Contains("..")) throw Outside();

        string fullFile, fullRoot;
        try { fullFile = Path.GetFullPath(file); fullRoot = Path.GetFullPath(root); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { throw Outside(); }

        // Alternate data streams and drive-relative tricks live in the segments after the root.
        var tail = fullFile[Path.GetPathRoot(fullFile)!.Length..];
        if (tail.Contains(':')) throw Outside();

        fullFile = ExpandShortNames(fullFile);
        var canonicalRoot = CanonicalExisting(fullRoot, mustBeDirectory: true) ?? throw Outside();
        var baseParts = Split(canonicalRoot);

        bool Within(IReadOnlyList<string> parts, bool includingRoot = false) =>
            parts.Count >= baseParts.Count + (includingRoot ? 0 : 1)
            && baseParts.Select((p, i) => string.Equals(p, parts[i], StringComparison.OrdinalIgnoreCase)).All(x => x);

        var fileParts = Split(fullFile);
        var current = new List<string> { fileParts[0] };
        for (var i = 1; i < fileParts.Count; i++)
        {
            var candidateParts = current.Append(fileParts[i]).ToList();
            var candidate = Join(candidateParts);
            FileAttributes attributes;
            try { attributes = File.GetAttributes(candidate); }
            catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
            {
                // Only a genuinely missing path may continue. Permission errors, invalid names and
                // "a file where a directory should be" all fail closed.
                if (Within(candidateParts) && !ParentIsFile(current)) return;
                throw Outside();
            }
            catch { throw Outside(); }

            if (attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                // Root aliases above the approved root are valid. Within the root, never follow a link,
                // even when it currently points at another in-root directory.
                if (Within(current, includingRoot: true)) throw Outside();
                var resolved = CanonicalExisting(candidate, mustBeDirectory: false) ?? throw Outside();
                current = Split(resolved);
            }
            else
            {
                current = candidateParts;
            }
        }
        if (!Within(current)) throw Outside();
    }

    /// <summary>
    /// Expands 8.3 aliases ("PROGRA~1") in the part of the path that exists, so it compares with the canonical
    /// root. This does not resolve links: reparse points are still found, and rejected, by the walk.
    /// </summary>
    private static string ExpandShortNames(string fullPath)
    {
        var parts = Split(fullPath);
        for (var n = parts.Count; n >= 1; n--)
        {
            var candidate = Join(parts.Take(n).ToList());
            try { File.GetAttributes(candidate); }
            catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { continue; }
            catch { throw Outside(); }
            var buffer = new StringBuilder(1024);
            var length = GetLongPathName(candidate, buffer, buffer.Capacity);
            if (length == 0) return fullPath;
            if (length >= buffer.Capacity)
            {
                buffer.EnsureCapacity((int)length + 1);
                length = GetLongPathName(candidate, buffer, buffer.Capacity);
                if (length == 0) return fullPath;
            }
            var expanded = Split(buffer.ToString());
            expanded.AddRange(parts.Skip(n));
            return Join(expanded);
        }
        return fullPath;
    }

    private static bool ParentIsFile(List<string> parts)
    {
        try { return !File.GetAttributes(Join(parts)).HasFlag(FileAttributes.Directory); }
        catch { return true; }
    }

    private static McpException Outside() => new(McpErrorCode.OutsideWorkspace);

    private static bool IsDevicePath(string path) =>
        path.StartsWith(@"\\?\", StringComparison.Ordinal) || path.StartsWith(@"\\.\", StringComparison.Ordinal)
        || path.StartsWith("//?/", StringComparison.Ordinal) || path.StartsWith("//./", StringComparison.Ordinal);

    /// <summary>Root (drive or UNC share) followed by each segment.</summary>
    private static List<string> Split(string fullPath)
    {
        var root = Path.GetPathRoot(fullPath)!;
        var parts = new List<string> { Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar };
        parts.AddRange(fullPath[root.Length..].Split(['\\', '/'], StringSplitOptions.RemoveEmptyEntries));
        return parts;
    }

    private static string Join(List<string> parts) =>
        parts.Count == 1 ? parts[0] : Path.Combine(parts[0], Path.Combine([.. parts.Skip(1)]));

    /// <summary>Resolves links and 8.3 aliases for a path that exists. Null when it does not or cannot be opened.</summary>
    private static string? CanonicalExisting(string path, bool mustBeDirectory)
    {
        using var handle = CreateFile(path, 0, FileShare.ReadWrite | FileShare.Delete, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle.IsInvalid) return null;
        var buffer = new StringBuilder(1024);
        var length = GetFinalPathNameByHandle(handle, buffer, buffer.Capacity, 0);
        if (length == 0) return null;
        if (length >= buffer.Capacity)
        {
            buffer.EnsureCapacity((int)length + 1);
            length = GetFinalPathNameByHandle(handle, buffer, buffer.Capacity, 0);
            if (length == 0) return null;
        }
        var result = buffer.ToString();
        if (result.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) result = @"\\" + result[8..];
        else if (result.StartsWith(@"\\?\", StringComparison.Ordinal)) result = result[4..];
        if (mustBeDirectory && !Directory.Exists(result)) return null;
        return result;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string name, uint access, FileShare share, IntPtr security,
        uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetLongPathName(string shortPath, StringBuilder longPath, int size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, int size, uint flags);
}
