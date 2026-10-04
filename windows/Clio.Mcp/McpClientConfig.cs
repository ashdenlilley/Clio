using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Clio.Mcp;

/// <summary>
/// Setup snippets for the supported local clients. Every snippet contains the client's private token:
/// treat the output as a secret (the app clears the clipboard after 60 seconds, as on macOS).
/// </summary>
public static class McpClientConfig
{
    public const string EnvironmentVariable = "CLIO_MCP_TOKEN";
    public const string BridgeFileName = "clio-mcp-bridge.exe";
    public static string Endpoint { get; } = $"http://127.0.0.1:{McpLimits.Port}/mcp";

    private static readonly JsonSerializerOptions Pretty = new()
    {
        WriteIndented = true,
        // Keep base64 tokens readable and greppable ("+" would otherwise become 002B).
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>Claude Desktop reads <c>%APPDATA%\Claude\claude_desktop_config.json</c>.</summary>
    public static string ClaudeDesktopConfigPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude", "claude_desktop_config.json");

    /// <summary>The <c>clio</c> entry for Claude Desktop's <c>mcpServers</c>, as a complete standalone document.</summary>
    public static string ClaudeDesktopEntry(string bridgePath, byte[] token) =>
        Merge(null, bridgePath, token);

    /// <summary>
    /// Merge the <c>clio</c> entry into an existing Claude Desktop configuration, preserving every other
    /// key and every other server. Throws <see cref="McpException"/> if the existing text is not a JSON object,
    /// so a damaged file is never overwritten.
    /// </summary>
    public static string Merge(string? existing, string bridgePath, byte[] token)
    {
        if (token.Length != 32) throw new McpException(McpErrorCode.InvalidRequest);
        JsonObject root;
        if (string.IsNullOrWhiteSpace(existing)) root = new JsonObject();
        else
        {
            try { root = JsonNode.Parse(existing, documentOptions: new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip })?.AsObject()
                    ?? throw new McpException(McpErrorCode.InvalidRequest); }
            catch (Exception e) when (e is JsonException or InvalidOperationException) { throw new McpException(McpErrorCode.InvalidRequest); }
        }
        if (root["mcpServers"] is not JsonObject servers)
        {
            if (root["mcpServers"] is not null) throw new McpException(McpErrorCode.InvalidRequest);
            servers = new JsonObject();
            root["mcpServers"] = servers;
        }
        servers["clio"] = new JsonObject
        {
            ["command"] = bridgePath,
            ["env"] = new JsonObject { [EnvironmentVariable] = Convert.ToBase64String(token) },
        };
        return root.ToJsonString(Pretty);
    }

    /// <summary>Server definition for <c>claude mcp add-json clio '…'</c> or a project <c>.mcp.json</c> entry (Streamable HTTP).</summary>
    public static string ClaudeCodeJson(byte[] token)
    {
        if (token.Length != 32) throw new McpException(McpErrorCode.InvalidRequest);
        return new JsonObject
        {
            ["type"] = "http",
            ["url"] = Endpoint,
            ["headers"] = new JsonObject { ["Authorization"] = "Bearer " + Convert.ToBase64String(token) },
        }.ToJsonString(Pretty);
    }

    /// <summary>
    /// The bridge shipped next to the app. Falls back to the plain file name so a hand-edited path still
    /// points somewhere sensible.
    /// </summary>
    public static string BridgePath(string appDirectory) => Path.Combine(appDirectory, BridgeFileName);

    /// <summary>
    /// Writes a config file that contains a token: replaces atomically, keeps a copy of the old file and never
    /// touches a file it cannot parse. The file inherits the user-profile permissions of its folder.
    /// </summary>
    public static void WriteDesktopConfig(string path, string bridgePath, byte[] token)
    {
        string? existing = File.Exists(path) ? File.ReadAllText(path, Encoding.UTF8) : null;
        var merged = Merge(existing, bridgePath, token);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        if (existing is not null) File.Copy(path, path + ".bak", overwrite: true);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, merged, new UTF8Encoding(false));
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
