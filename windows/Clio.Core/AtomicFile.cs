using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Clio.Core;

public class ClioException(string message, Exception? inner = null) : Exception(message, inner);

public sealed class ConflictException() : ClioException("File changed on disk since it was read.");

public sealed class LinkException(string path)
    : ClioException($"Refusing to write through a symbolic link or junction: {path}");

public sealed class NotUtf8Exception() : ClioException("File is not valid UTF-8.");

/// <summary>
/// Atomic save: temp file in the destination directory, flushed to disk, then swapped in
/// with <c>ReplaceFileW</c>. The original survives any failure before the swap.
/// </summary>
public static partial class AtomicFile
{
    public const string TempPrefix = ".clio-save-";
    private const int Retries = 6;

    [LibraryImport("kernel32.dll", EntryPoint = "ReplaceFileW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ReplaceFile(string replaced, string replacement, string? backup, uint flags, nint exclude, nint reserved);

    public static bool IsTempName(string name) => name.StartsWith(TempPrefix, StringComparison.Ordinal);

    public static void Write(string destination, ReadOnlySpan<byte> contents)
    {
        var full = Path.GetFullPath(destination);
        var parent = Path.GetDirectoryName(full) ?? throw new LinkException(destination);
        if (IsLink(full) || IsLink(parent)) throw new LinkException(destination);

        var temp = Path.Combine(parent, TempPrefix + Guid.NewGuid().ToString("N"));
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(contents);
                stream.Flush(flushToDisk: true);
            }
            if (File.Exists(full)) Retry(() => Replace(full, temp));
            else Retry(() => File.Move(temp, full));
        }
        catch
        {
            try { File.Delete(temp); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            throw;
        }
    }

    /// <summary>Creates <paramref name="destination"/> only if nothing exists there. Returns false when the name is taken.</summary>
    public static bool TryCreate(string destination, ReadOnlySpan<byte> contents)
    {
        var full = Path.GetFullPath(destination);
        var parent = Path.GetDirectoryName(full) ?? throw new LinkException(destination);
        if (IsLink(parent)) throw new LinkException(destination);

        var temp = Path.Combine(parent, TempPrefix + Guid.NewGuid().ToString("N"));
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(contents);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temp, full, overwrite: false);
            return true;
        }
        catch (IOException) when (File.Exists(full) || Directory.Exists(full))
        {
            try { File.Delete(temp); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            return false;
        }
        catch
        {
            try { File.Delete(temp); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            throw;
        }
    }

    private static void Replace(string destination, string temp)
    {
        if (!ReplaceFile(destination, temp, null, 0, 0, 0))
            throw new IOException(new Win32Exception(Marshal.GetLastWin32Error()).Message, Marshal.GetLastWin32Error());
    }

    private static bool IsLink(string path) =>
        (File.Exists(path) || Directory.Exists(path)) && new FileInfo(path).LinkTarget is not null;

    /// <summary>Sharing violations from antivirus, OneDrive or the indexer are transient: back off and retry.</summary>
    private static void Retry(Action op)
    {
        var delay = 20;
        for (var attempt = 0; ; attempt++)
        {
            try { op(); return; }
            catch (Exception e) when (attempt < Retries && IsTransient(e))
            {
                Thread.Sleep(delay);
                delay *= 2;
            }
        }
    }

    private static bool IsTransient(Exception e) =>
        e is UnauthorizedAccessException || (e is IOException io && (io.HResult & 0xFFFF) is 5 or 32 or 33 or 1175);
}
