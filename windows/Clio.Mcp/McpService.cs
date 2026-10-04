using System.Net.Sockets;
using System.Security.Cryptography;

namespace Clio.Mcp;

/// <summary>
/// App-owned lifecycle for local MCP (macOS <c>ClioMCPService</c>), UI-free. Default off: nothing listens
/// until <see cref="SetEnabled"/> succeeds, and creating the service never touches Credential Manager.
/// The tray icon, settings page and login toggle sit on top of this API; tokens reach the clipboard only
/// through <see cref="DesktopConfig"/>, <see cref="ClaudeCodeConfig"/> and <see cref="TokenText"/>.
/// </summary>
public sealed class McpService : IDisposable
{
    private readonly IMcpHost _host;
    private readonly IMcpClientStore _store;
    private readonly McpAccessController _access = new();
    private readonly McpHttpServer _server;
    private readonly McpRouter _router;
    private readonly object _lock = new();
    private List<McpStoredClient> _clients = [];
    private bool _loaded;

    public McpService(IMcpHost host, IMcpClientStore store, ushort port = McpLimits.Port)
    {
        _host = host;
        _store = store;
        _server = new McpHttpServer(port);
        var tools = new McpTools(host, _access) { ClientName = ClientName };
        _router = new McpRouter(_access, tools);
        _router.ConnectionsChanged += count => { ConnectedSessions = count; RaiseChanged(); };
        _server.Handler = request => _router.RespondAsync(request);
        _server.Failed += message =>
        {
            // The listener died: fail closed.
            _access.SetEnabled(false);
            _router.Stop();
            Enabled = false;
            Status = message;
            RaiseChanged();
        };
    }

    public bool Enabled { get; private set; }
    public string Status { get; private set; } = "MCP is off";
    public int ConnectedSessions { get; private set; }
    public string? ErrorMessage { get; private set; }
    public ushort Port => _server.Port;

    public IReadOnlyList<McpClientInfo> Clients
    {
        get { lock (_lock) return [.. _clients.Select(c => c.Info)]; }
    }

    /// <summary>Raised after any state change, on an arbitrary thread. Marshal to the UI thread in the handler.</summary>
    public event Action? Changed;

    /// <summary>Call once at launch: starts the server only when the owner previously switched MCP on.</summary>
    public void StartConfigured()
    {
        if (_store.Enabled) SetEnabled(true);
    }

    public bool SetEnabled(bool value)
    {
        ErrorMessage = null;
        if (!value)
        {
            _access.SetEnabled(false);
            _router.Stop();
            _server.Stop();
            Enabled = false;
            Status = "MCP is paused";
            TryPersistEnabled(false);
            RaiseChanged();
            return true;
        }
        try
        {
            LoadCredentials();
            _access.SetEnabled(true);
            _server.Start();
            Enabled = true;
            Status = $"Listening on 127.0.0.1:{_server.Port}";
            TryPersistEnabled(true);
            RaiseChanged();
            return true;
        }
        catch (Exception error) when (error is SocketException or McpException or IOException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        {
            _access.SetEnabled(false);
            _server.Stop();
            Enabled = false;
            ErrorMessage = error is SocketException
                ? $"MCP could not start. Port {_server.RequestedPort} may be in use."
                : "MCP could not start. Check Credential Manager access.";
            Status = "MCP unavailable";
            RaiseChanged();
            return false;
        }
    }

    /// <summary>
    /// Loads the stored clients so a settings page can list them, without starting the server (macOS
    /// <c>prepareSettingsPage</c>). Returns false with <see cref="ErrorMessage"/> set when Credential Manager is unavailable.
    /// </summary>
    public bool PrepareSettingsPage()
    {
        try { LoadCredentials(); ErrorMessage = null; RaiseChanged(); return true; }
        catch (Exception error) when (error is McpException or IOException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        {
            ErrorMessage = "Allow Credential Manager access to manage MCP clients.";
            RaiseChanged();
            return false;
        }
    }

    /// <summary>Quiesce BEFORE the quit-save gate so cancellation of a save cannot admit new tool writes. The preference stays.</summary>
    public void QuiesceForQuit()
    {
        _access.SetEnabled(false);
        _router.Stop();
        _server.Stop();
        Enabled = false;
        Status = "MCP stopped";
        RaiseChanged();
    }

    /// <summary>
    /// Authorize a named client for an exact set of workspaces. The UI must have shown the owner that set.
    /// Returns the client id, or null with <see cref="ErrorMessage"/> set.
    /// </summary>
    public Guid? AddClient(string name, IReadOnlySet<Guid> workspaces)
    {
        try
        {
            LoadCredentials();
            if (!workspaces.IsSubsetOf(_host.Workspaces.Select(w => w.Id))) throw new McpException(McpErrorCode.OutsideWorkspace);
            var token = RandomNumberGenerator.GetBytes(32);
            var id = _access.AuthorizeClient(name, token, workspaces);
            var record = new McpStoredClient(id, name, workspaces.ToHashSet(), token);
            try { _store.Add(record); }
            catch { _access.Revoke(id); throw; }
            lock (_lock) _clients.Add(record);
            ErrorMessage = null;
            RaiseChanged();
            return id;
        }
        catch (Exception error) when (error is McpException or IOException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        {
            ErrorMessage = "Client was not added. Select at least one folder, use a short name, and allow Credential Manager access.";
            RaiseChanged();
            return null;
        }
    }

    /// <summary>Revocation takes effect in memory even if persisting it fails; then MCP pauses until the owner retries.</summary>
    public void Revoke(Guid id)
    {
        _access.Revoke(id);
        _router.Revoke(id);
        lock (_lock) _clients.RemoveAll(c => c.Id == id);
        try { _store.Remove(id); ErrorMessage = null; }
        catch (Exception error) when (error is IOException or System.ComponentModel.Win32Exception or UnauthorizedAccessException)
        {
            SetEnabled(false);
            ErrorMessage = "Access is paused. Credential Manager could not persist revocation; retry Remove before enabling MCP again.";
        }
        RaiseChanged();
    }

    /// <summary>Base64 token for the explicit "Copy token" action. A secret.</summary>
    public string? TokenText(Guid id) => Token(id) is { } token ? Convert.ToBase64String(token) : null;

    /// <summary>Claude Desktop entry for the bridge at <paramref name="bridgePath"/>. A secret.</summary>
    public string? DesktopConfig(Guid id, string bridgePath) =>
        Token(id) is { } token ? McpClientConfig.ClaudeDesktopEntry(bridgePath, token) : null;

    /// <summary>Claude Code Streamable HTTP definition. A secret.</summary>
    public string? ClaudeCodeConfig(Guid id) => Token(id) is { } token ? McpClientConfig.ClaudeCodeJson(token) : null;

    /// <summary>Merge the entry into Claude Desktop's own config file, preserving the owner's other servers.</summary>
    public bool WriteClaudeDesktopConfig(Guid id, string bridgePath, string? configPath = null)
    {
        if (Token(id) is not { } token) return false;
        try { McpClientConfig.WriteDesktopConfig(configPath ?? McpClientConfig.ClaudeDesktopConfigPath, bridgePath, token); return true; }
        catch (Exception error) when (error is McpException or IOException or UnauthorizedAccessException)
        {
            ErrorMessage = "Claude Desktop's configuration could not be updated. Copy the entry and merge it by hand.";
            RaiseChanged();
            return false;
        }
    }

    public void Dispose()
    {
        QuiesceForQuit();
        _server.Dispose();
    }

    private byte[]? Token(Guid id)
    {
        lock (_lock) return _clients.FirstOrDefault(c => c.Id == id)?.Token;
    }

    private string ClientName(Guid id)
    {
        lock (_lock) return _clients.FirstOrDefault(c => c.Id == id)?.Name ?? "MCP client";
    }

    private void LoadCredentials()
    {
        lock (_lock)
        {
            if (_loaded) return;
            var stored = _store.Load();
            try
            {
                foreach (var client in stored)
                    _access.AuthorizeClient(client.Name, client.Token, client.WorkspaceIds, client.Id);
            }
            catch { _access.Stop(); throw; }
            _clients = [.. stored];
            _loaded = true;
        }
    }

    private void TryPersistEnabled(bool value)
    {
        try { _store.Enabled = value; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    private void RaiseChanged() => Changed?.Invoke();
}
