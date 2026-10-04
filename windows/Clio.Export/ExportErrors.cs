using Clio.Core;

namespace Clio.Export;

public enum ExportFormat { Pdf, Html, Docx, Txt }

/// <summary>The exact destination state shown to the user when an export collides. A replace decision is only valid for this revision.</summary>
public sealed record ExportCollision(string DestinationPath, DiskRevision Revision);

public sealed record ExportCollisionResolution(ExportCollision Collision, CollisionChoice Choice);

public sealed record ExportReceipt(ExportFormat Format, string DestinationPath, long ByteCount, DateTimeOffset CompletedAt, string SourceFingerprint);

public sealed class DestinationExistsException(ExportCollision collision)
    : ClioException($"A file named {Path.GetFileName(collision.DestinationPath)} already exists.")
{
    public ExportCollision Collision { get; } = collision;
}

public sealed class DestinationChangedException(string path, ExportCollision? current)
    : ClioException($"{Path.GetFileName(path)} changed while Clio was exporting. Choose again.")
{
    public ExportCollision? Current { get; } = current;
}

public sealed class InvalidCollisionResolutionException()
    : ClioException("That collision choice belongs to a different export. Choose again.");

public sealed class InvalidPrintSettingsException()
    : ClioException("The selected paper size and margins leave no printable area.");

public sealed class EmptyPdfPageException()
    : ClioException("Clio could not fit any document content on the selected page.");

public sealed class UnsupportedDestinationException(string path)
    : ClioException($"Clio cannot export to {path}. Choose a regular file destination.");

public sealed class ArtifactTooLargeException(string path, long byteCount, long maximumByteCount)
    : ClioException($"{Path.GetFileName(path)} expanded to {byteCount:N0} bytes, beyond Clio's recoverable export limit of {maximumByteCount:N0} bytes.");
