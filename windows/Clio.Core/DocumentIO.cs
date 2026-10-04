using System.Security.Cryptography;
using System.Text;

namespace Clio.Core;

public enum LineEnding { Lf, CrLf }

/// <summary>Contract: spec/vectors/revision-digest.json. Digest is lowercase hex SHA-256 of the raw bytes.</summary>
public sealed record DiskRevision(long ByteCount, DateTimeOffset Modified, string ContentDigest)
{
    public static string Digest(ReadOnlySpan<byte> data) => Convert.ToHexStringLower(SHA256.HashData(data));
}

public sealed record LoadedDocument(string Text, bool Bom, LineEnding LineEnding, DiskRevision Revision);

/// <summary>Contract: spec/vectors/line-endings.json.</summary>
public static class DocumentIO
{
    private static readonly byte[] Bom = [0xEF, 0xBB, 0xBF];
    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    public static DiskRevision Revision(string path, byte[] bytes) =>
        new(bytes.LongLength, File.GetLastWriteTimeUtc(path), DiskRevision.Digest(bytes));

    public static DiskRevision CurrentRevision(string path) => Revision(path, File.ReadAllBytes(path));

    public static LoadedDocument Load(string path) => Decode(path, File.ReadAllBytes(path));

    public static LoadedDocument Decode(string path, byte[] bytes)
    {
        var revision = Revision(path, bytes);
        var bom = bytes.AsSpan().StartsWith(Bom);
        string raw;
        try { raw = StrictUtf8.GetString(bytes, bom ? Bom.Length : 0, bytes.Length - (bom ? Bom.Length : 0)); }
        catch (DecoderFallbackException) { throw new NotUtf8Exception(); }

        var crlf = CountOf(raw, "\r\n");
        var lf = CountOf(raw, "\n") - crlf;
        var ending = crlf > lf ? LineEnding.CrLf : LineEnding.Lf;
        return new LoadedDocument(crlf > 0 ? raw.Replace("\r\n", "\n") : raw, bom, ending, revision);
    }

    public static byte[] Encode(string text, bool bom, LineEnding ending)
    {
        var body = StrictUtf8.GetBytes(ending == LineEnding.CrLf ? text.Replace("\n", "\r\n") : text);
        return bom ? [.. Bom, .. body] : body;
    }

    /// <summary>Saves <paramref name="text"/>. A mismatch with <paramref name="expected"/> throws <see cref="ConflictException"/> and leaves the file untouched.</summary>
    public static DiskRevision Save(string path, string text, bool bom, LineEnding ending, DiskRevision? expected)
    {
        if (expected is not null && File.Exists(path) && CurrentRevision(path).ContentDigest != expected.ContentDigest)
            throw new ConflictException();
        var bytes = Encode(text, bom, ending);
        AtomicFile.Write(path, bytes);
        return Revision(path, bytes);
    }

    private static int CountOf(string s, string needle)
    {
        var n = 0;
        for (var i = s.IndexOf(needle, StringComparison.Ordinal); i >= 0; i = s.IndexOf(needle, i + needle.Length, StringComparison.Ordinal)) n++;
        return n;
    }
}
