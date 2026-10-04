using Xunit;

namespace Clio.Core.Tests;

public sealed class DocumentIOTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("clio-test-").FullName;
    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private string P(string name) => Path.Combine(_dir, name);

    [Fact]
    public void DigestMatchesSharedVectors()
    {
        foreach (var v in SpecVectors.Load("revision-digest.json").GetProperty("vectors").EnumerateArray())
            Assert.Equal(v.GetProperty("sha256").GetString(), DiskRevision.Digest(SpecVectors.Hex(v.GetProperty("bytesHex").GetString()!)));
    }

    [Fact]
    public void LineEndingsMatchSharedVectors()
    {
        var root = SpecVectors.Load("line-endings.json");
        foreach (var v in root.GetProperty("vectors").EnumerateArray())
        {
            var name = v.GetProperty("name").GetString()!;
            var bytes = SpecVectors.Hex(v.GetProperty("fileHex").GetString()!);
            var doc = DocumentIO.Decode(P(name), bytes);
            Assert.Equal(v.GetProperty("text").GetString(), doc.Text);
            Assert.Equal(v.GetProperty("bom").GetBoolean(), doc.Bom);
            Assert.Equal(v.GetProperty("ending").GetString(), doc.LineEnding == LineEnding.CrLf ? "crlf" : "lf");
            // Round trip only when the file used one consistent ending.
            if (!name.StartsWith("mixed", StringComparison.Ordinal))
                Assert.Equal(bytes, DocumentIO.Encode(doc.Text, doc.Bom, doc.LineEnding));
        }
        foreach (var v in root.GetProperty("invalid").EnumerateArray())
            Assert.Throws<NotUtf8Exception>(() => DocumentIO.Decode(P("bad"), SpecVectors.Hex(v.GetProperty("fileHex").GetString()!)));
    }

    [Fact]
    public void SaveDetectsExternalEditAndKeepsFile()
    {
        File.WriteAllText(P("a.md"), "x");
        var doc = DocumentIO.Load(P("a.md"));
        File.WriteAllText(P("a.md"), "changed elsewhere");
        Assert.Throws<ConflictException>(() => DocumentIO.Save(P("a.md"), "mine", false, LineEnding.Lf, doc.Revision));
        Assert.Equal("changed elsewhere", File.ReadAllText(P("a.md")));
    }

    [Fact]
    public void SaveCreatesThenReplacesWithoutLeftovers()
    {
        DocumentIO.Save(P("a.md"), "one", false, LineEnding.Lf, null);
        DocumentIO.Save(P("a.md"), "two", false, LineEnding.Lf, null);
        Assert.Equal("two", File.ReadAllText(P("a.md")));
        Assert.DoesNotContain(Directory.GetFiles(_dir), f => AtomicFile.IsTempName(Path.GetFileName(f)));
    }

    [Fact]
    public void FailedReplaceKeepsOriginalAndCleansTemp()
    {
        DocumentIO.Save(P("a.md"), "keep", false, LineEnding.Lf, null);
        using (new FileStream(P("a.md"), FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.ThrowsAny<Exception>(() => AtomicFile.Write(P("a.md"), "lost"u8));
        Assert.Equal("keep", File.ReadAllText(P("a.md")));
        Assert.DoesNotContain(Directory.GetFiles(_dir), f => AtomicFile.IsTempName(Path.GetFileName(f)));
    }

    [Fact]
    public void RefusesWriteThroughJunction()
    {
        // Junctions need no privilege, unlike symlinks.
        Directory.CreateDirectory(P("real"));
        File.WriteAllText(P("real\\a.md"), "real");
        var psi = new System.Diagnostics.ProcessStartInfo("cmd.exe", $"/c mklink /J \"{P("link")}\" \"{P("real")}\"")
            { CreateNoWindow = true, RedirectStandardOutput = true };
        using (var proc = System.Diagnostics.Process.Start(psi)!) { proc.WaitForExit(); Assert.Equal(0, proc.ExitCode); }

        Assert.Throws<LinkException>(() => AtomicFile.Write(P("link\\a.md"), "x"u8));
        Assert.Equal("real", File.ReadAllText(P("real\\a.md")));
        Directory.Delete(P("link")); // removes the junction only, not the target
    }
}
