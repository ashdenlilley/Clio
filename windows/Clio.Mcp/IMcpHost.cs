namespace Clio.Mcp;

public sealed record McpWorkspaceInfo(Guid Id, string Name);

public sealed record McpDocumentInfo(Guid DocumentId, Guid WorkspaceId, string Filename, McpRevision Revision, string SaveState);

/// <summary>A settled live read. <see cref="FilePath"/> is only used for the native deletion prompt and never returned to clients.</summary>
public sealed record McpDocumentSnapshot(McpDocumentInfo Info, string Text, string? FilePath);

public sealed record McpDiscoveryEntry(Guid DocumentId, Guid WorkspaceId, string Filename);

/// <summary>Discovery result: every match the host will return, before pagination.</summary>
public sealed record McpDiscovery(IReadOnlyList<McpDiscoveryEntry> Matches, bool Capped, bool IndexComplete);

public sealed record McpActiveDocument(McpDocumentInfo Info, int SelectionLocation, int SelectionLength);

/// <summary>A change that may leave the search index behind the file system.</summary>
public sealed record McpCommit(McpDocumentInfo Info, bool IndexUpdatePending);

public sealed record McpDeletionRequest(string ClientName, string Filename, string FilePath);

public sealed record McpExportRequest(Guid WorkspaceId, Guid DocumentId, McpRevision Revision,
    Guid DestinationWorkspaceId, string Filename, McpExportFormat Format);

public enum McpExportFormat { Pdf, Html, Docx, Txt }

public sealed record McpMoveRequest(Guid WorkspaceId, Guid DocumentId, McpRevision Revision,
    Guid DestinationWorkspaceId, string Filename, string ParentRelativePath);

/// <summary>
/// Handed to every host call. The host MUST call <see cref="Validate"/> after every suspension point and
/// immediately before it observes or mutates a buffer, so pause, revoke or quit ends work in flight.
/// </summary>
public sealed class McpAuthority(McpAccessController access, McpClientGrant grant)
{
    public Guid ClientId => grant.Id;
    public void Validate(Guid workspaceId) => access.Validate(grant, workspaceId);
}

/// <summary>
/// The app side of local MCP. Everything here runs against the app's live buffers, workspace services and
/// native UI; the protocol, authorization and argument handling stay in this library. Implementations must:
/// settle pending editor edits before reading, apply edits through the editor's undo and autosave pipeline,
/// never write backing files directly, and reject documents outside the approved workspaces with
/// <see cref="McpErrorCode.OutsideWorkspace"/> (use <see cref="McpWorkspaceBoundary"/>).
/// </summary>
public interface IMcpHost
{
    IReadOnlyList<McpWorkspaceInfo> Workspaces { get; }

    /// <summary>List (null query) or search an approved workspace. Live buffers override indexed results.</summary>
    Task<McpDiscovery> DiscoverAsync(Guid workspaceId, string? query, McpAuthority authority, CancellationToken ct);

    Task<McpDocumentSnapshot> SnapshotAsync(Guid workspaceId, Guid documentId, McpAuthority authority, CancellationToken ct);

    Task<McpActiveDocument?> ActiveDocumentAsync(McpAuthority authority, CancellationToken ct);

    Task OpenAsync(Guid workspaceId, Guid documentId, McpAuthority authority, CancellationToken ct);

    /// <summary>Select a UTF-16 range at <paramref name="expected"/>. Throw <c>stale_revision</c> on mismatch.</summary>
    Task<McpDocumentInfo> SelectTextAsync(Guid workspaceId, Guid documentId, McpRevision expected, int location, int length,
        McpAuthority authority, CancellationToken ct);

    Task<McpCommit> CreateAsync(Guid workspaceId, string filename, string text, McpAuthority authority, CancellationToken ct);

    /// <summary>
    /// Apply through the editor with undo. Reject a stale revision with
    /// <c>McpToolFailure("stale_revision", {currentRevision})</c>, marked text with <c>editor_busy_retry</c>
    /// and a conflicted or oversized document with <c>document_conflicted_or_too_large</c>.
    /// </summary>
    Task<McpDocumentInfo> ReplaceAsync(Guid workspaceId, Guid documentId, McpRevision expected, McpTextReplacement edit,
        McpAuthority authority, CancellationToken ct);

    /// <summary>Rename or move without replacing a destination. The source must be saved.</summary>
    Task<McpCommit> MoveAsync(McpMoveRequest request, McpAuthority authority, CancellationToken ct);

    /// <summary>
    /// Native confirmation UI naming the document and the requesting client. Must open Clio's UI even when
    /// no editor window exists, expire after <see cref="McpLimits.ApprovalLifetime"/>, and return false on
    /// cancel, timeout or cancellation. Nothing a client sends can complete it.
    /// </summary>
    Task<bool> ConfirmDeletionAsync(McpDeletionRequest request, CancellationToken ct);

    /// <summary>Move to the Recycle Bin. Revalidate the revision and scope; return whether the index is behind.</summary>
    Task<bool> TrashAsync(Guid workspaceId, Guid documentId, McpRevision approved, McpAuthority authority, CancellationToken ct);

    Task<McpRevision> ExportAsync(McpExportRequest request, McpAuthority authority, CancellationToken ct);
}
