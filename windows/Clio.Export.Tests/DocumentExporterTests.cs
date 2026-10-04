using System.Text;
using Clio.Core;
using Xunit;

namespace Clio.Export.Tests;

public class DocumentExporterTests
{
    private const string Source = "# Notes\n\n**Bold** and *italic* 🙂\n\n[Example](https://example.com)\n\n| Name | Value |\n| --- | --- |\n| First | Second |\n";

    private static ExportRequest Request(ExportFormat format, string destination, string source = Source) =>
        new(format, source, "Notes.md", destination, format == ExportFormat.Pdf ? PdfPrintSettings.RegionalDefault("US") : null);

    [Theory]
    [InlineData(ExportFormat.Txt)]
    [InlineData(ExportFormat.Html)]
    [InlineData(ExportFormat.Docx)]
    [InlineData(ExportFormat.Pdf)]
    public void WritesEachFormatAndNeverOverwritesSilently(ExportFormat format)
    {
        using var dir = new TempDirectory();
        var destination = dir.File("Notes" + DocumentExporter.Extension(format));

        var receipt = DocumentExporter.Export(Request(format, destination));

        Assert.Equal(destination, receipt.DestinationPath);
        var bytes = File.ReadAllBytes(destination);
        Assert.Equal(bytes.LongLength, receipt.ByteCount);
        Assert.Equal(DiskRevision.Digest(Encoding.UTF8.GetBytes(Source)), receipt.SourceFingerprint);
        Assert.True(bytes.Length > 0);

        var exists = Assert.Throws<DestinationExistsException>(() => DocumentExporter.Export(Request(format, destination)));
        Assert.Equal(destination, exists.Collision.DestinationPath);
        Assert.Equal(bytes, File.ReadAllBytes(destination));
        Assert.DoesNotContain(Directory.EnumerateFiles(dir.Path), f => AtomicFile.IsTempName(Path.GetFileName(f)));
    }

    [Fact]
    public void TextExportIsPlainUtf8WithoutBom()
    {
        using var dir = new TempDirectory();
        var destination = dir.File("Notes.txt");

        DocumentExporter.Export(Request(ExportFormat.Txt, destination));

        var bytes = File.ReadAllBytes(destination);
        Assert.NotEqual(0xEF, bytes[0]);
        var text = Encoding.UTF8.GetString(bytes);
        Assert.Contains("Bold and italic 🙂", text);
        Assert.Contains("Example (https://example.com)", text);
        Assert.Contains("Name\tValue", text);
        Assert.DoesNotContain("**Bold**", text);
    }

    [Fact]
    public void KeepBothUsesParenthesizedNumbers()
    {
        using var dir = new TempDirectory();
        var destination = dir.File("Notes.txt");
        File.WriteAllText(destination, "existing");
        File.WriteAllText(dir.File("Notes (2).txt"), "existing too");
        var collision = Assert.Throws<DestinationExistsException>(() => DocumentExporter.Export(Request(ExportFormat.Txt, destination))).Collision;

        var receipt = DocumentExporter.Export(Request(ExportFormat.Txt, destination), new ExportCollisionResolution(collision, CollisionChoice.KeepBoth));

        Assert.Equal(dir.File("Notes (3).txt"), receipt.DestinationPath);
        Assert.Equal("existing", File.ReadAllText(destination));
        Assert.Equal("existing too", File.ReadAllText(dir.File("Notes (2).txt")));
        Assert.Contains("Bold and italic", File.ReadAllText(receipt.DestinationPath));
    }

    [Fact]
    public void ReplaceOverwritesOnlyTheApprovedRevision()
    {
        using var dir = new TempDirectory();
        var destination = dir.File("Notes.html");
        File.WriteAllText(destination, "old");
        var collision = Assert.Throws<DestinationExistsException>(() => DocumentExporter.Export(Request(ExportFormat.Html, destination))).Collision;

        DocumentExporter.Export(Request(ExportFormat.Html, destination), new ExportCollisionResolution(collision, CollisionChoice.Replace));

        Assert.Contains("<!doctype html>", File.ReadAllText(destination));
    }

    [Fact]
    public void ReplaceIsRefusedWhenTheFileChangedAfterTheChoice()
    {
        using var dir = new TempDirectory();
        var destination = dir.File("Notes.html");
        File.WriteAllText(destination, "old");
        var collision = Assert.Throws<DestinationExistsException>(() => DocumentExporter.Export(Request(ExportFormat.Html, destination))).Collision;
        File.WriteAllText(destination, "someone else wrote this");

        var changed = Assert.Throws<DestinationChangedException>(() =>
            DocumentExporter.Export(Request(ExportFormat.Html, destination), new ExportCollisionResolution(collision, CollisionChoice.Replace)));

        Assert.Equal("someone else wrote this", File.ReadAllText(destination));
        Assert.NotNull(changed.Current);
        Assert.Equal(DocumentIO.CurrentRevision(destination), changed.Current!.Revision);
    }

    [Fact]
    public void ReplaceIsRefusedWhenTheFileVanished()
    {
        using var dir = new TempDirectory();
        var destination = dir.File("Notes.html");
        File.WriteAllText(destination, "old");
        var collision = Assert.Throws<DestinationExistsException>(() => DocumentExporter.Export(Request(ExportFormat.Html, destination))).Collision;
        File.Delete(destination);

        var changed = Assert.Throws<DestinationChangedException>(() =>
            DocumentExporter.Export(Request(ExportFormat.Html, destination), new ExportCollisionResolution(collision, CollisionChoice.Replace)));

        Assert.Null(changed.Current);
        Assert.False(File.Exists(destination));
    }

    [Fact]
    public void ResolutionForAnotherDestinationIsRejected()
    {
        using var dir = new TempDirectory();
        File.WriteAllText(dir.File("A.txt"), "a");
        File.WriteAllText(dir.File("B.txt"), "b");
        var collision = Assert.Throws<DestinationExistsException>(() => DocumentExporter.Export(Request(ExportFormat.Txt, dir.File("A.txt")))).Collision;

        Assert.Throws<InvalidCollisionResolutionException>(() =>
            DocumentExporter.Export(Request(ExportFormat.Txt, dir.File("B.txt")), new ExportCollisionResolution(collision, CollisionChoice.Replace)));
        Assert.Equal("b", File.ReadAllText(dir.File("B.txt")));
    }

    [Fact]
    public void CancelChoiceCancelsAndWritesNothing()
    {
        using var dir = new TempDirectory();
        var destination = dir.File("Notes.txt");
        File.WriteAllText(destination, "keep");
        var collision = Assert.Throws<DestinationExistsException>(() => DocumentExporter.Export(Request(ExportFormat.Txt, destination))).Collision;

        Assert.Throws<OperationCanceledException>(() =>
            DocumentExporter.Export(Request(ExportFormat.Txt, destination), new ExportCollisionResolution(collision, CollisionChoice.Cancel)));
        Assert.Equal("keep", File.ReadAllText(destination));
    }

    [Fact]
    public void CancelledTokenLeavesNoFile()
    {
        using var dir = new TempDirectory();
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        Assert.Throws<OperationCanceledException>(() => DocumentExporter.Export(Request(ExportFormat.Html, dir.File("Notes.html")), cancellationToken: cts.Token));
        Assert.Empty(Directory.EnumerateFileSystemEntries(dir.Path));
    }

    [Fact]
    public void CancellationDuringRenderingKeepsAnExistingDestination()
    {
        using var dir = new TempDirectory();
        var destination = dir.File("Notes.txt");
        File.WriteAllText(destination, "existing");
        var collision = Assert.Throws<DestinationExistsException>(() => DocumentExporter.Export(Request(ExportFormat.Txt, destination))).Collision;
        using var cts = new CancellationTokenSource();
        var big = string.Join("\n\n", Enumerable.Repeat("paragraph of text", 200_000));
        cts.CancelAfter(TimeSpan.FromMilliseconds(5));

        Assert.ThrowsAny<OperationCanceledException>(() =>
            DocumentExporter.Export(Request(ExportFormat.Txt, destination, big), new ExportCollisionResolution(collision, CollisionChoice.Replace), cts.Token));
        Assert.Equal("existing", File.ReadAllText(destination));
        Assert.DoesNotContain(Directory.EnumerateFiles(dir.Path), f => AtomicFile.IsTempName(Path.GetFileName(f)));
    }

    [Theory]
    [InlineData("CON.txt")]
    [InlineData("nul")]
    [InlineData("trailing.")]
    [InlineData("bad<name>.txt")]
    public void ReservedAndIllegalNamesAreNotDestinations(string name)
    {
        using var dir = new TempDirectory();

        Assert.Throws<UnsupportedDestinationException>(() => DocumentExporter.Export(Request(ExportFormat.Txt, Path.Combine(dir.Path, name))));
    }

    [Fact]
    public void DirectoriesAndMissingFoldersAreNotDestinations()
    {
        using var dir = new TempDirectory();
        Directory.CreateDirectory(dir.File("Folder.txt"));

        Assert.Throws<UnsupportedDestinationException>(() => DocumentExporter.Export(Request(ExportFormat.Txt, dir.File("Folder.txt"))));
        Assert.Throws<UnsupportedDestinationException>(() => DocumentExporter.Export(Request(ExportFormat.Txt, dir.File(Path.Combine("missing", "Notes.txt")))));
    }

    [Fact]
    public void InvalidPdfSettingsFailBeforeAnythingIsWritten()
    {
        using var dir = new TempDirectory();
        var bad = new PdfPrintSettings(null, 612, 792, new PrintMargins(54, 400, 54, 400), PaperOrientation.Portrait);

        Assert.Throws<InvalidPrintSettingsException>(() =>
            DocumentExporter.Export(new ExportRequest(ExportFormat.Pdf, Source, "t", dir.File("Notes.pdf"), bad)));
        Assert.Empty(Directory.EnumerateFileSystemEntries(dir.Path));
    }

    [Fact]
    public async Task ExportAsyncRunsOffTheCallingThread()
    {
        using var dir = new TempDirectory();

        var receipt = await DocumentExporter.ExportAsync(Request(ExportFormat.Html, dir.File("Notes.html")));

        Assert.True(File.Exists(receipt.DestinationPath));
    }

    [Theory]
    [InlineData("Notes.md", ExportFormat.Pdf, "Notes.pdf")]
    [InlineData("My: Notes?.md", ExportFormat.Docx, "My- Notes-.docx")]
    [InlineData("", ExportFormat.Txt, "Untitled.txt")]
    [InlineData("CON.md", ExportFormat.Html, "CON-.html")]
    public void SuggestedFileNameFollowsTheDocumentAndRepairsUnsafeNames(string document, ExportFormat format, string expected)
    {
        var suggested = DocumentExporter.SuggestedFileName(document, format);

        Assert.True(FileNames.IsSafeComponent(suggested), suggested);
        Assert.EndsWith(DocumentExporter.Extension(format), suggested);
        if (document is "Notes.md" or "") Assert.Equal(expected, suggested);
    }
}
