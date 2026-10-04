namespace Clio.Core;

/// <summary>A document's bytes and the revision they were read at, taken in one read.</summary>
public sealed record FileSnapshot(byte[] Data, DiskRevision Revision);

internal static class FileSnapshots
{
    public const long MaximumBytes = 50L * 1024 * 1024;

    /// <summary>
    /// Reads a file in one pass and refuses links, so a file repointed at a private target after a metadata check is
    /// never read. Sharing flags let editors keep writing. Files over 50 MiB are refused.
    /// </summary>
    public static FileSnapshot Read(string path)
    {
        if (PathSafety.IsLink(path)) throw new ClioException("Refusing to read through a link.");
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (stream.Length > MaximumBytes) throw new ClioException("File too large to read safely.");
        var data = new byte[stream.Length];
        stream.ReadExactly(data);
        return new FileSnapshot(data, new DiskRevision(data.LongLength, File.GetLastWriteTimeUtc(path), DiskRevision.Digest(data)));
    }
}
