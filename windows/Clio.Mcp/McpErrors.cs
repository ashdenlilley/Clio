namespace Clio.Mcp;

/// <summary>Port of macOS <c>MCPAccessError</c>. Names match the spec vectors.</summary>
public enum McpErrorCode
{
    Disabled, Unauthorized, ForbiddenOrigin, InvalidHost, OversizedRequest,
    InvalidRequest, OutsideWorkspace, StaleRevision, InvalidRange,
    RetryConflict, RetryCapacity, ApprovalRequired, ExpiredApproval,
}

public sealed class McpException(McpErrorCode code) : Exception(code.ToString())
{
    public McpErrorCode Code { get; } = code;

    /// <summary>The case name as it appears in spec vectors and tool errors (camelCase).</summary>
    public string Name => char.ToLowerInvariant(Code.ToString()[0]) + Code.ToString()[1..];
}

/// <summary>A tool-level failure with a stable code. Never carries paths, secrets or raw system errors.</summary>
public sealed class McpToolFailure(string code, IReadOnlyDictionary<string, string>? details = null) : Exception(code)
{
    public string FailureCode { get; } = code;
    public IReadOnlyDictionary<string, string> Details { get; } = details ?? new Dictionary<string, string>();
}

public static class McpLimits
{
    public const ushort Port = 19847;
    public const int MaximumBodyBytes = 1_048_576;
    public const int MaximumHeadBytes = 16_384;
    public const int MaximumClients = 32;
    public const int MaximumSessions = 32;
    public const int MaximumInFlight = 16;
    public const int MaximumConnections = 16;
    public const int ReadPageUtf16 = 16_384;
    public const int ListPage = 100;
    public const int ListDefault = 30;
    public const int QueryUtf8Bytes = 256;
    public const int FilenameUtf8Bytes = 128;
    public const int MutationDocumentBytes = 256 * 1024;
    public const int ReadDocumentBytes = 1_048_576;
    public static readonly TimeSpan SessionLifetime = TimeSpan.FromHours(1);
    public static readonly TimeSpan ToolDeadline = TimeSpan.FromSeconds(110);
    public static readonly TimeSpan ApprovalLifetime = TimeSpan.FromSeconds(60);
}
