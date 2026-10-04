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

    /// <summary>Any file Clio creates beside a document for crash safety: temp, displaced and manifest names.</summary>
    public static bool IsTempName(string name) => name.StartsWith(".clio-", StringComparison.Ordinal);

    /// <summary>
    /// Replaces or creates <paramref name="destination"/> inside a recoverable transaction. A manifest is flushed
    /// first; the old file is kept as a displaced sibling until the swap is confirmed. <paramref name="phaseHook"/>
    /// is a test seam: if it throws, the writer behaves as if killed there and leaves every artifact in place.
    /// </summary>
    public static void Write(string destination, ReadOnlySpan<byte> contents, DiskRevision? expected = null, Action<AtomicWritePhase>? phaseHook = null)
    {
        var full = Path.GetFullPath(destination);
        var parent = Path.GetDirectoryName(full) ?? throw new LinkException(destination);
        if (IsLink(full) || IsLink(parent)) throw new LinkException(destination);

        var exists = File.Exists(full);
        var transaction = AtomicWriteTransactions.Begin(
            contents, full, exists ? AtomicWriteOperation.Replace : AtomicWriteOperation.Create,
            exists ? expected ?? DocumentIO.CurrentRevision(full) : null);
        var temp = transaction.Manifest.TemporaryPath;
        var displaced = transaction.Manifest.DisplacedPath;
        var crashed = false;
        var swapped = false;

        void At(AtomicWritePhase phase)
        {
            if (phaseHook is null) return;
            try { phaseHook(phase); }
            catch { crashed = true; throw; }
        }

        try
        {
            At(AtomicWritePhase.ManifestSynced);
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(contents);
                stream.Flush(flushToDisk: true);
            }
            At(AtomicWritePhase.CandidateSynced);
            if (exists) Retry(() => Replace(full, temp, displaced));
            else Retry(() => File.Move(temp, full));
            swapped = true;
            At(AtomicWritePhase.Swapped);
            At(AtomicWritePhase.ParentSynced);
            AtomicWriteTransactions.Finish(transaction);
        }
        catch (Exception) when (!crashed)
        {
            if (!swapped) Abandon(full, temp, displaced, transaction.ManifestPath);
            throw;
        }
    }

    /// <summary>
    /// Undoes a failed save. ReplaceFileW can fail after it has already moved the old file aside
    /// (ERROR_UNABLE_TO_MOVE_REPLACEMENT): put it back first, and keep the manifest if it cannot be.
    /// </summary>
    private static void Abandon(string full, string temp, string displaced, string manifest)
    {
        try
        {
            if (!File.Exists(full) && File.Exists(displaced)) File.Move(displaced, full);
            Delete(temp);
            if (!File.Exists(displaced)) Delete(manifest);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private static void Delete(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
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

    /// <summary>Swaps <paramref name="temp"/> in; the old file moves to <paramref name="displaced"/> so its bytes survive a crash.</summary>
    private static void Replace(string destination, string temp, string displaced)
    {
        if (ReplaceFile(Extended(destination), Extended(temp), Extended(displaced), 0, 0, 0)) return;
        // Read the error once: formatting the message makes further system calls that can overwrite it.
        var error = Marshal.GetLastWin32Error();
        throw new IOException(new Win32Exception(error).Message, error);
    }

    /// <summary>ReplaceFileW has no automatic long-path handling unless the process opted in; the \\?\ prefix always works.</summary>
    private static string Extended(string fullPath) =>
        fullPath.StartsWith(@"\\?\", StringComparison.Ordinal) ? fullPath
        : fullPath.StartsWith(@"\\", StringComparison.Ordinal) ? @"\\?\UNC\" + fullPath[2..]
        : @"\\?\" + fullPath;

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
