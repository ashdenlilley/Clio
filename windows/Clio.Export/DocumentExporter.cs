using System.Text;
using Clio.Core;

namespace Clio.Export;

/// <summary>What to export and where. <see cref="Source"/> is the editor text (LF line breaks); <see cref="Title"/> names the document in the PDF header, HTML title and file metadata.</summary>
public sealed record ExportRequest(
    ExportFormat Format,
    string Source,
    string Title,
    string DestinationPath,
    PdfPrintSettings? PdfSettings = null);

/// <summary>
/// UI-free export pipeline: parse, render to bytes, then commit through <see cref="AtomicFile"/>. A name collision is
/// never overwritten silently: the call throws <see cref="DestinationExistsException"/> carrying the exact
/// <see cref="ExportCollision"/>, and the caller retries with an <see cref="ExportCollisionResolution"/>.
/// </summary>
public static class DocumentExporter
{
    public static string Extension(ExportFormat format) => format switch
    {
        ExportFormat.Pdf => ".pdf",
        ExportFormat.Html => ".html",
        ExportFormat.Docx => ".docx",
        _ => ".txt",
    };

    /// <summary>"Notes.md" exports as "Notes.pdf" and so on; unsafe characters and reserved names are repaired.</summary>
    public static string SuggestedFileName(string documentName, ExportFormat format) =>
        FileNames.Safe(Path.GetFileNameWithoutExtension(documentName) is { Length: > 0 } stem ? stem + Extension(format) : "Untitled" + Extension(format));

    /// <summary>Renders without touching the file system.</summary>
    public static byte[] Render(ExportFormat format, string source, string title, PdfPrintSettings? pdfSettings = null, CancellationToken cancellationToken = default)
    {
        if (format == ExportFormat.Pdf)
            PdfPrintGeometry.Resolve(pdfSettings ?? PdfPrintSettings.RegionalDefault(), PdfPrintSettings.RegionalDefault());
        var document = MarkdownModelBuilder.Build(source, cancellationToken);
        cancellationToken.ThrowIfCancellationRequested();
        return format switch
        {
            ExportFormat.Html => new UTF8Encoding(false).GetBytes(HtmlRenderer.Render(document, title, cancellationToken: cancellationToken)),
            ExportFormat.Txt => new UTF8Encoding(false).GetBytes(PlainTextRenderer.Render(document, cancellationToken)),
            ExportFormat.Docx => DocxRenderer.Render(document, title, cancellationToken),
            ExportFormat.Pdf => PdfRenderer.Render(document, title, pdfSettings, cancellationToken),
            _ => throw new ArgumentOutOfRangeException(nameof(format)),
        };
    }

    public static Task<ExportReceipt> ExportAsync(ExportRequest request, ExportCollisionResolution? resolution = null, CancellationToken cancellationToken = default) =>
        Task.Run(() => Export(request, resolution, cancellationToken), cancellationToken);

    public static ExportReceipt Export(ExportRequest request, ExportCollisionResolution? resolution = null, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var reservation = ExportDestination.Resolve(request.DestinationPath, resolution);
        var bytes = Render(request.Format, request.Source, request.Title, request.PdfSettings, cancellationToken);
        if (bytes.LongLength > AtomicWriteTransactions.MaximumRecoverableByteCount)
            throw new ArtifactTooLargeException(reservation.Path, bytes.LongLength, AtomicWriteTransactions.MaximumRecoverableByteCount);
        cancellationToken.ThrowIfCancellationRequested();
        ExportDestination.Commit(reservation, bytes);
        return new ExportReceipt(
            request.Format, reservation.Path, bytes.LongLength, DateTimeOffset.UtcNow,
            DiskRevision.Digest(Encoding.UTF8.GetBytes(request.Source)));
    }
}
