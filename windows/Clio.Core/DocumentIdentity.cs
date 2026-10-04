using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Clio.Core;

public readonly record struct DocumentLocator(Guid WorkspaceId, string RelativePath);

/// <summary>
/// What survives a rename: the NTFS volume serial and 128-bit file id. NTFS and ReFS reuse ids after a delete,
/// which is why the store prunes superseded ids. Falls back to the folded path where the filesystem has no id.
/// </summary>
public abstract record PhysicalFileIdentity
{
    public sealed record Resource(string Volume, string FileId) : PhysicalFileIdentity;

    public sealed record ByPath(string Path) : PhysicalFileIdentity;

    [StructLayout(LayoutKind.Sequential)]
    private struct FileIdInfo
    {
        public ulong VolumeSerialNumber;
        public ulong FileIdLow;
        public ulong FileIdHigh;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int informationClass, out FileIdInfo info, uint size);

    private const int FileIdInfoClass = 18;

    public static PhysicalFileIdentity OfFile(string path)
    {
        var full = Path.GetFullPath(path);
        try
        {
            using var handle = File.OpenHandle(full, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (GetFileInformationByHandleEx(handle, FileIdInfoClass, out var info, (uint)Marshal.SizeOf<FileIdInfo>()))
                return new Resource(info.VolumeSerialNumber.ToString("x16"), info.FileIdHigh.ToString("x16") + info.FileIdLow.ToString("x16"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return new ByPath(FileNames.Fold(full));
    }
}

public sealed record DocumentIdentityCandidate(
    DocumentLocator Locator,
    PhysicalFileIdentity? Physical = null,
    string? CanonicalPath = null,
    Guid? PreferredId = null);

public sealed class IdentityStoreException(string path) : ClioException($"Clio's document identity store is unreadable at {path}.");
