using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Clio.Mcp;

namespace Clio.Mcp.Tests;

/// <summary>Locates the shared cross-platform spec (repo-root /spec).</summary>
internal static class Spec
{
    public static string RepoRoot { get; } = FindRepoRoot();

    private static string FindRepoRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (Directory.Exists(Path.Combine(dir.FullName, "spec", "vectors"))) return dir.FullName;
        throw new DirectoryNotFoundException("spec/vectors not found above " + AppContext.BaseDirectory);
    }

    public static JsonElement Load(string name) =>
        JsonDocument.Parse(File.ReadAllText(Path.Combine(RepoRoot, "spec", "vectors", name))).RootElement;

    /// <summary>Expands <c>{"repeat":"x","count":n}</c> rows.</summary>
    public static string Repeated(JsonElement row) =>
        new(row.GetProperty("repeat").GetString()![0], row.GetProperty("count").GetInt32());
}

internal sealed class TempDirectory : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ClioMcp-" + Guid.NewGuid().ToString("N"));
    public TempDirectory() => Directory.CreateDirectory(Path);
    public string Combine(params string[] parts) => System.IO.Path.Combine([Path, .. parts]);
    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}

/// <summary>An in-memory app: documents, one workspace and scriptable native UI.</summary>
internal sealed class FakeHost : IMcpHost
{
    public sealed class Doc
    {
        public Guid Id = Guid.NewGuid();
        public string Filename = "";
        public string Text = "";
        public ulong Revision = 1;
        public bool Dirty;
        public string? Path;
    }

    private readonly McpRevisionTracker _tracker = new();
    public Guid WorkspaceId { get; } = Guid.NewGuid();
    public Guid OtherWorkspaceId { get; } = Guid.NewGuid();
    public Dictionary<Guid, Doc> Docs { get; } = [];
    public List<string> Trashed { get; } = [];
    public List<string> Created { get; } = [];
    public Func<McpDeletionRequest, Task<bool>> Confirm { get; set; } = _ => Task.FromResult(true);
    public int ConfirmCalls { get; private set; }

    public IReadOnlyList<McpWorkspaceInfo> Workspaces =>
        [new(WorkspaceId, "Notes"), new(OtherWorkspaceId, "Other")];

    public Doc Add(string filename, string text)
    {
        var doc = new Doc { Filename = filename, Text = text, Path = System.IO.Path.Combine(@"C:\Notes", filename) };
        Docs[doc.Id] = doc;
        return doc;
    }

    public McpDocumentInfo Info(Doc doc) => new(doc.Id, WorkspaceId, doc.Filename,
        _tracker.For(doc, doc.Id, doc.Revision), doc.Dirty ? "pending" : "saved");

    private Doc Find(Guid documentId) => Docs.TryGetValue(documentId, out var doc) ? doc : throw new McpException(McpErrorCode.OutsideWorkspace);

    public Task<McpDiscovery> DiscoverAsync(Guid workspaceId, string? query, McpAuthority authority, CancellationToken ct)
    {
        authority.Validate(workspaceId);
        var hits = Docs.Values.Where(d => query is null || d.Text.Contains(query, StringComparison.OrdinalIgnoreCase)
                                          || d.Filename.Contains(query, StringComparison.OrdinalIgnoreCase))
            .Select(d => new McpDiscoveryEntry(d.Id, workspaceId, d.Filename)).ToList();
        return Task.FromResult(new McpDiscovery(hits, false, true));
    }

    public Task<McpDocumentSnapshot> SnapshotAsync(Guid workspaceId, Guid documentId, McpAuthority authority, CancellationToken ct)
    {
        authority.Validate(workspaceId);
        var doc = Find(documentId);
        return Task.FromResult(new McpDocumentSnapshot(Info(doc), doc.Text, doc.Path));
    }

    public Task<McpActiveDocument?> ActiveDocumentAsync(McpAuthority authority, CancellationToken ct) =>
        Task.FromResult<McpActiveDocument?>(Docs.Values.FirstOrDefault() is { } d ? new McpActiveDocument(Info(d), 1, 2) : null);

    public Task OpenAsync(Guid workspaceId, Guid documentId, McpAuthority authority, CancellationToken ct)
    {
        authority.Validate(workspaceId);
        Find(documentId);
        return Task.CompletedTask;
    }

    private void Check(Doc doc, McpRevision expected)
    {
        var current = Info(doc).Revision;
        if (current != expected)
            throw new McpToolFailure("stale_revision", new Dictionary<string, string> { ["currentRevision"] = current.Encode() });
    }

    public Task<McpDocumentInfo> SelectTextAsync(Guid workspaceId, Guid documentId, McpRevision expected, int location, int length,
        McpAuthority authority, CancellationToken ct)
    {
        authority.Validate(workspaceId);
        var doc = Find(documentId);
        Check(doc, expected);
        _ = new McpTextReplacement(location, length, "").Applying(doc.Text);
        return Task.FromResult(Info(doc));
    }

    public Task<McpCommit> CreateAsync(Guid workspaceId, string filename, string text, McpAuthority authority, CancellationToken ct)
    {
        authority.Validate(workspaceId);
        var doc = Add(filename, text);
        Created.Add(filename);
        return Task.FromResult(new McpCommit(Info(doc), false));
    }

    public Task<McpDocumentInfo> ReplaceAsync(Guid workspaceId, Guid documentId, McpRevision expected, McpTextReplacement edit,
        McpAuthority authority, CancellationToken ct)
    {
        authority.Validate(workspaceId);
        var doc = Find(documentId);
        Check(doc, expected);
        doc.Text = edit.Applying(doc.Text);
        doc.Revision++;
        doc.Dirty = true;
        return Task.FromResult(Info(doc));
    }

    public Task<McpCommit> MoveAsync(McpMoveRequest request, McpAuthority authority, CancellationToken ct)
    {
        authority.Validate(request.WorkspaceId);
        authority.Validate(request.DestinationWorkspaceId);
        var doc = Find(request.DocumentId);
        Check(doc, request.Revision);
        if (Docs.Values.Any(d => d != doc && d.Filename == request.Filename)) throw new McpToolFailure("destination_exists");
        doc.Filename = request.Filename;
        return Task.FromResult(new McpCommit(Info(doc), false));
    }

    public Task<bool> ConfirmDeletionAsync(McpDeletionRequest request, CancellationToken ct)
    {
        ConfirmCalls++;
        // A real prompt closes when the operation is cancelled.
        return Confirm(request).WaitAsync(ct);
    }

    public Task<bool> TrashAsync(Guid workspaceId, Guid documentId, McpRevision approved, McpAuthority authority, CancellationToken ct)
    {
        authority.Validate(workspaceId);
        var doc = Find(documentId);
        Check(doc, approved);
        Docs.Remove(documentId);
        Trashed.Add(doc.Filename);
        return Task.FromResult(false);
    }

    public Task<McpRevision> ExportAsync(McpExportRequest request, McpAuthority authority, CancellationToken ct)
    {
        authority.Validate(request.WorkspaceId);
        authority.Validate(request.DestinationWorkspaceId);
        var doc = Find(request.DocumentId);
        Check(doc, request.Revision);
        return Task.FromResult(Info(doc).Revision);
    }
}

internal sealed class ManualClock : TimeProvider
{
    private long _ticks;
    public override long GetTimestamp() => _ticks;
    public override long TimestampFrequency => TimeSpan.TicksPerSecond;
    public void Advance(TimeSpan by) => _ticks += by.Ticks;
}

/// <summary>Drives the router the way the HTTP layer would.</summary>
internal sealed class Rig : IDisposable
{
    public FakeHost Host { get; } = new();
    public McpAccessController Access { get; } = new();
    public McpTools Tools { get; }
    public McpRouter Router { get; }
    public byte[] Token { get; } = Enumerable.Repeat((byte)7, 32).ToArray();
    public Guid ClientId { get; }

    public Rig(bool enable = true, byte tokenByte = 7)
    {
        Token = Enumerable.Repeat(tokenByte, 32).ToArray();
        ClientId = Access.AuthorizeClient("Test client", Token, new HashSet<Guid> { Host.WorkspaceId });
        Tools = new McpTools(Host, Access) { ClientName = _ => "Test client" };
        Router = new McpRouter(Access, Tools);
        if (enable) Access.SetEnabled(true);
    }

    public static McpHttpRequest Request(string method, byte[]? token, JsonObject? body = null, string? session = null,
        string version = "2025-11-25")
    {
        var headers = new Dictionary<string, string> { ["mcp-protocol-version"] = version };
        if (token is not null) headers["authorization"] = "Bearer " + Convert.ToBase64String(token);
        if (session is not null) headers["mcp-session-id"] = session;
        return new McpHttpRequest(method, headers, Encoding.UTF8.GetBytes(body?.ToJsonString() ?? ""));
    }

    public static JsonObject Rpc(string method, int? id = null, JsonObject? parameters = null)
    {
        var o = new JsonObject { ["jsonrpc"] = "2.0", ["method"] = method, ["params"] = parameters ?? new JsonObject() };
        if (id is { } i) o["id"] = i;
        return o;
    }

    public Task<McpHttpResponse> Post(JsonObject body, byte[]? token = null, string? session = null, string version = "2025-11-25") =>
        Router.RespondAsync(Request("POST", token ?? Token, body, session, version));

    public async Task<string> OpenSession(string protocol = "2025-11-25")
    {
        var initial = await Post(Rpc("initialize", 1, new JsonObject { ["protocolVersion"] = protocol }), version: protocol);
        var session = initial.Headers!["MCP-Session-Id"];
        var negotiated = Json(initial)["result"]!["protocolVersion"]!.GetValue<string>();
        await Post(Rpc("notifications/initialized"), session: session, version: negotiated);
        return session;
    }

    public async Task<JsonObject> Call(string session, string tool, JsonObject arguments, int id = 100)
    {
        var response = await Post(Rpc("tools/call", id, new JsonObject { ["name"] = tool, ["arguments"] = arguments }), session: session);
        return ToolJson(response);
    }

    public static JsonObject Json(McpHttpResponse response) => JsonNode.Parse(response.BodyBytes)!.AsObject();

    public static JsonObject ToolJson(McpHttpResponse response)
    {
        var result = Json(response)["result"]!;
        var text = result["content"]![0]!["text"]!.GetValue<string>();
        var parsed = JsonNode.Parse(text)!.AsObject();
        parsed["__isError"] = result["isError"]!.GetValue<bool>();
        return parsed;
    }

    public void Dispose() => Router.Stop();
}
