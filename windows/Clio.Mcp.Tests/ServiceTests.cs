using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Clio.Mcp;
using Xunit;

namespace Clio.Mcp.Tests;

public class ServiceTests
{
    private static async Task<HttpStatusCode> PingAsync(ushort port, string token)
    {
        using var http = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{port}/mcp")
        { Content = new StringContent(Rig.Rpc("initialize", 1, new JsonObject { ["protocolVersion"] = "2025-11-25" }).ToJsonString(), Encoding.UTF8, "application/json") };
        request.Headers.TryAddWithoutValidation("Accept", "application/json, text/event-stream");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return (await http.SendAsync(request)).StatusCode;
    }

    private static HashSet<Guid> Scope(FakeHost host) => [host.WorkspaceId];

    [Fact]
    public void DefaultOffNothingListensAndCredentialsAreNotTouched()
    {
        var store = new CountingStore();
        using var service = new McpService(new FakeHost(), store, 0);
        service.StartConfigured();
        Assert.False(service.Enabled);
        Assert.Equal(0, service.Port);
        Assert.Equal(0, store.Loads);
        Assert.Equal("MCP is off", service.Status);
        service.QuiesceForQuit();
        Assert.False(service.Enabled);
        Assert.Empty(service.Clients);
        Assert.Equal(0, service.ConnectedSessions);
        Assert.Equal(0, store.Loads);
    }

    [Fact]
    public async Task EnabledPreferenceStartsTheServerAtLaunchAndPersistsChoices()
    {
        var host = new FakeHost();
        var store = new MemoryMcpClientStore();
        using var service = new McpService(host, store, 0);
        var id = service.AddClient("Claude Code", Scope(host))!.Value;
        Assert.True(service.SetEnabled(true));
        Assert.True(store.Enabled);
        var token = service.TokenText(id)!;
        Assert.Equal(HttpStatusCode.OK, await PingAsync(service.Port, token));
        service.Dispose();

        using var relaunch = new McpService(host, store, 0);
        relaunch.StartConfigured();
        Assert.True(relaunch.Enabled);
        Assert.Equal(["Claude Code"], relaunch.Clients.Select(c => c.Name));
        Assert.Equal(HttpStatusCode.OK, await PingAsync(relaunch.Port, token));
        Assert.True(relaunch.SetEnabled(false));
        Assert.False(store.Enabled);
        await Assert.ThrowsAnyAsync<HttpRequestException>(() => PingAsync(relaunch.Port == 0 ? (ushort)1 : relaunch.Port, token));
    }

    [Fact]
    public async Task QuiesceForQuitStopsServingButKeepsThePreference()
    {
        var host = new FakeHost();
        var store = new MemoryMcpClientStore();
        using var service = new McpService(host, store, 0);
        var id = service.AddClient("c", Scope(host))!.Value;
        service.SetEnabled(true);
        var port = service.Port;
        var token = service.TokenText(id)!;
        service.QuiesceForQuit();
        Assert.False(service.Enabled);
        Assert.True(store.Enabled);
        await Assert.ThrowsAnyAsync<HttpRequestException>(() => PingAsync(port, token));
        Assert.True(service.SetEnabled(true));
        Assert.Equal(HttpStatusCode.OK, await PingAsync(service.Port, token));
    }

    [Fact]
    public async Task RevocationEndsAccessImmediatelyAndPersists()
    {
        var host = new FakeHost();
        var store = new MemoryMcpClientStore();
        using var service = new McpService(host, store, 0);
        var id = service.AddClient("c", Scope(host))!.Value;
        service.SetEnabled(true);
        var token = service.TokenText(id)!;
        Assert.Equal(HttpStatusCode.OK, await PingAsync(service.Port, token));
        service.Revoke(id);
        Assert.Equal(HttpStatusCode.Unauthorized, await PingAsync(service.Port, token));
        Assert.Empty(service.Clients);
        Assert.Empty(store.Load());
        Assert.Null(service.TokenText(id));
    }

    [Fact]
    public async Task FailedPersistenceOfARevocationPausesMcp()
    {
        var host = new FakeHost();
        var store = new FailingRemoveStore();
        using var service = new McpService(host, store, 0);
        var id = service.AddClient("c", Scope(host))!.Value;
        service.SetEnabled(true);
        var token = service.TokenText(id)!;
        var port = service.Port;
        service.Revoke(id);
        Assert.False(service.Enabled);
        Assert.NotNull(service.ErrorMessage);
        await Assert.ThrowsAnyAsync<HttpRequestException>(() => PingAsync(port, token));
    }

    [Fact]
    public void AddClientRejectsUnknownWorkspacesBlankNamesAndEmptyScope()
    {
        var host = new FakeHost();
        using var service = new McpService(host, new MemoryMcpClientStore(), 0);
        Assert.Null(service.AddClient("c", new HashSet<Guid> { Guid.NewGuid() }));
        Assert.NotNull(service.ErrorMessage);
        Assert.Null(service.AddClient("c", new HashSet<Guid>()));
        Assert.Null(service.AddClient("  ", Scope(host)));
        Assert.Empty(service.Clients);
        Assert.NotNull(service.AddClient("c", Scope(host)));
        Assert.Null(service.ErrorMessage);
    }

    [Fact]
    public void AddClientThatCannotPersistIsNotAuthorized()
    {
        var host = new FakeHost();
        using var service = new McpService(host, new FailingAddStore(), 0);
        Assert.Null(service.AddClient("c", Scope(host)));
        Assert.Empty(service.Clients);
        service.SetEnabled(true);
        Assert.Empty(service.Clients);
    }

    [Fact]
    public void PortInUseFailsClosedWithAMessage()
    {
        var host = new FakeHost();
        using var holder = new McpHttpServer(0);
        holder.Start();
        using var service = new McpService(host, new MemoryMcpClientStore(), holder.Port);
        Assert.False(service.SetEnabled(true));
        Assert.False(service.Enabled);
        Assert.Contains("in use", service.ErrorMessage);
        Assert.Equal("MCP unavailable", service.Status);
    }

    [Fact]
    public void ClientSnippetsCarryTheTokenOnlyOnRequest()
    {
        var host = new FakeHost();
        using var service = new McpService(host, new MemoryMcpClientStore(), 0);
        var id = service.AddClient("c", Scope(host))!.Value;
        var token = service.TokenText(id)!;
        Assert.Equal(32, Convert.FromBase64String(token).Length);
        Assert.Contains(token, service.DesktopConfig(id, @"C:\Clio\clio-mcp-bridge.exe"));
        Assert.Contains(token, service.ClaudeCodeConfig(id));
        Assert.DoesNotContain(token, service.Status);
        Assert.Null(service.DesktopConfig(Guid.NewGuid(), "x"));
        Assert.Null(service.ClaudeCodeConfig(Guid.NewGuid()));
        Assert.DoesNotContain(token, string.Join("|", service.Clients.Select(c => c.Name + c.Id)));
    }

    [Fact]
    public async Task ChangedFiresForUiUpdatesAndConnectionsAreCounted()
    {
        var host = new FakeHost();
        using var service = new McpService(host, new MemoryMcpClientStore(), 0);
        var changes = 0;
        service.Changed += () => Interlocked.Increment(ref changes);
        var id = service.AddClient("c", Scope(host))!.Value;
        service.SetEnabled(true);
        Assert.True(changes >= 2);
        Assert.Equal(HttpStatusCode.OK, await PingAsync(service.Port, service.TokenText(id)!));
        Assert.Equal(1, service.ConnectedSessions);
        service.QuiesceForQuit();
        Assert.Equal(0, service.ConnectedSessions);
    }

    private sealed class CountingStore : IMcpClientStore
    {
        public int Loads { get; private set; }
        public bool Enabled { get; set; }
        public IReadOnlyList<McpStoredClient> Load() { Loads++; return []; }
        public void Add(McpStoredClient client) { }
        public void Remove(Guid id) { }
    }

    private sealed class FailingRemoveStore : IMcpClientStore
    {
        private readonly List<McpStoredClient> _clients = [];
        public bool Enabled { get; set; }
        public IReadOnlyList<McpStoredClient> Load() => [.. _clients];
        public void Add(McpStoredClient client) => _clients.Add(client);
        public void Remove(Guid id) => throw new IOException("credential store unavailable");
    }

    private sealed class FailingAddStore : IMcpClientStore
    {
        public bool Enabled { get; set; }
        public IReadOnlyList<McpStoredClient> Load() => [];
        public void Add(McpStoredClient client) => throw new IOException("credential store unavailable");
        public void Remove(Guid id) { }
    }
}

public class CredentialStoreTests
{
    private sealed class MemoryVault : ICredentialVault
    {
        public Dictionary<string, byte[]> Secrets { get; } = [];
        public bool FailDelete { get; set; }
        public byte[]? Read(string target) => Secrets.GetValueOrDefault(target);
        public void Write(string target, string userName, byte[] secret) => Secrets[target] = secret;
        public void Delete(string target)
        {
            if (FailDelete) throw new IOException("delete failed");
            Secrets.Remove(target);
        }
    }

    private static McpStoredClient Client(string name = "Claude") =>
        new(Guid.NewGuid(), name, new HashSet<Guid> { Guid.NewGuid() }, Enumerable.Repeat((byte)9, 32).ToArray());

    [Fact]
    public void RoundTripKeepsTokensOutOfTheMetadataFile()
    {
        using var temp = new TempDirectory();
        var vault = new MemoryVault();
        var path = temp.Combine("mcp.json");
        var store = new CredentialMcpClientStore(vault, path);
        var client = Client();
        store.Add(client);
        store.Enabled = true;
        var loaded = new CredentialMcpClientStore(vault, path).Load().Single();
        Assert.Equal(client.Id, loaded.Id);
        Assert.Equal(client.Token, loaded.Token);
        Assert.Equal(client.WorkspaceIds, loaded.WorkspaceIds);
        Assert.True(new CredentialMcpClientStore(vault, path).Enabled);
        var file = File.ReadAllText(path);
        Assert.DoesNotContain(Convert.ToBase64String(client.Token), file);
        Assert.Contains("Claude", file);
    }

    [Fact]
    public void ARevokedClientNeverComesBackEvenIfTheCredentialSurvives()
    {
        using var temp = new TempDirectory();
        var vault = new MemoryVault();
        var path = temp.Combine("mcp.json");
        var store = new CredentialMcpClientStore(vault, path);
        var client = Client();
        store.Add(client);
        vault.FailDelete = true;
        Assert.Throws<IOException>(() => store.Remove(client.Id));
        Assert.Empty(new CredentialMcpClientStore(vault, path).Load());
        Assert.True(vault.Secrets.Count == 1);
    }

    [Fact]
    public void ClientsMissingEitherHalfAreIgnored()
    {
        using var temp = new TempDirectory();
        var vault = new MemoryVault();
        var store = new CredentialMcpClientStore(vault, temp.Combine("mcp.json"));
        var kept = Client("kept");
        var lost = Client("lost");
        store.Add(kept);
        store.Add(lost);
        vault.Secrets.Remove("Clio.MCP.client." + lost.Id.ToString("D"));
        vault.Secrets["Clio.MCP.client." + kept.Id.ToString("D")] = new byte[5];
        Assert.Empty(store.Load());
        vault.Secrets["Clio.MCP.client." + kept.Id.ToString("D")] = kept.Token;
        Assert.Equal(["kept"], store.Load().Select(c => c.Name));
    }

    [Fact]
    public void DamagedMetadataIsDefaultOffAndNeverThrows()
    {
        using var temp = new TempDirectory();
        var path = temp.Combine("mcp.json");
        File.WriteAllText(path, "{ this is not json");
        var store = new CredentialMcpClientStore(new MemoryVault(), path);
        Assert.False(store.Enabled);
        Assert.Empty(store.Load());
        File.WriteAllBytes(path, new byte[300 * 1024]);
        Assert.False(store.Enabled);
    }

    [Fact]
    public void FailedMetadataWriteRollsTheCredentialBack()
    {
        using var temp = new TempDirectory();
        var vault = new MemoryVault();
        // A directory where the file should be makes the replace fail.
        var path = temp.Combine("mcp.json");
        Directory.CreateDirectory(path);
        var store = new CredentialMcpClientStore(vault, path);
        Assert.ThrowsAny<Exception>(() => store.Add(Client()));
        Assert.Empty(vault.Secrets);
    }

    [Fact]
    public void WindowsCredentialManagerRoundTrip()
    {
        var vault = new WindowsCredentialVault();
        var target = "Clio.MCP.test." + Guid.NewGuid().ToString("N");
        var secret = Enumerable.Range(0, 32).Select(i => (byte)(i * 7)).ToArray();
        try
        {
            Assert.Null(vault.Read(target));
            vault.Write(target, "test-user", secret);
            Assert.Equal(secret, vault.Read(target));
            var updated = secret.Reverse().ToArray();
            vault.Write(target, "test-user", updated);
            Assert.Equal(updated, vault.Read(target));
            vault.Delete(target);
            Assert.Null(vault.Read(target));
            vault.Delete(target); // deleting a missing credential is fine
        }
        finally { try { vault.Delete(target); } catch { } }
        Assert.Throws<ArgumentOutOfRangeException>(() => vault.Write(target, "u", []));
        Assert.Throws<ArgumentOutOfRangeException>(() => vault.Write(target, "u", new byte[WindowsCredentialVault.MaximumSecretBytes + 1]));
    }

    [Fact]
    public void EndToEndWithCredentialManagerAndTheMetadataFile()
    {
        using var temp = new TempDirectory();
        var vault = new WindowsCredentialVault();
        var store = new CredentialMcpClientStore(vault, temp.Combine("mcp.json"));
        var client = Client();
        try
        {
            store.Add(client);
            Assert.Equal(client.Token, store.Load().Single().Token);
            store.Remove(client.Id);
            Assert.Empty(store.Load());
            Assert.Null(vault.Read("Clio.MCP.client." + client.Id.ToString("D")));
        }
        finally { try { vault.Delete("Clio.MCP.client." + client.Id.ToString("D")); } catch { } }
    }
}

public class ClientConfigTests
{
    private static readonly byte[] Token = Enumerable.Repeat((byte)3, 32).ToArray();
    private static readonly string TokenText = Convert.ToBase64String(Token);

    [Fact]
    public void DesktopEntryShape()
    {
        var node = JsonNode.Parse(McpClientConfig.ClaudeDesktopEntry(@"C:\Clio\clio-mcp-bridge.exe", Token))!;
        Assert.Equal(@"C:\Clio\clio-mcp-bridge.exe", node["mcpServers"]!["clio"]!["command"]!.GetValue<string>());
        Assert.Equal(TokenText, node["mcpServers"]!["clio"]!["env"]![McpClientConfig.EnvironmentVariable]!.GetValue<string>());
    }

    [Fact]
    public void MergePreservesEveryOtherKeyAndServer()
    {
        const string existing = """
            { "theme": "dark", "mcpServers": { "files": { "command": "npx", "args": ["x"] }, "clio": { "command": "old" } },
              "other": [1, 2] }
            """;
        var merged = JsonNode.Parse(McpClientConfig.Merge(existing, "bridge.exe", Token))!;
        Assert.Equal("dark", merged["theme"]!.GetValue<string>());
        Assert.Equal("npx", merged["mcpServers"]!["files"]!["command"]!.GetValue<string>());
        Assert.Equal("bridge.exe", merged["mcpServers"]!["clio"]!["command"]!.GetValue<string>());
        Assert.Equal(2, merged["other"]!.AsArray().Count);
        Assert.Equal(2, merged["mcpServers"]!.AsObject().Count);
    }

    [Fact]
    public void MergeToleratesCommentsAndTrailingCommasButNeverOverwritesDamage()
    {
        var merged = McpClientConfig.Merge("// my config\n{ \"a\": 1, }", "b.exe", Token);
        Assert.Equal(1, JsonNode.Parse(merged)!["a"]!.GetValue<int>());
        foreach (var bad in new[] { "{ not json", "[]", "\"text\"", "{ \"mcpServers\": [] }", "{ \"mcpServers\": 5 }" })
            Assert.Equal(McpErrorCode.InvalidRequest, Assert.Throws<McpException>(() => McpClientConfig.Merge(bad, "b.exe", Token)).Code);
        Assert.Equal(McpErrorCode.InvalidRequest, Assert.Throws<McpException>(() => McpClientConfig.Merge(null, "b.exe", new byte[5])).Code);
    }

    [Fact]
    public void ClaudeCodeShapeMatchesTheVector()
    {
        var shape = Spec.Load("mcp-protocol.json").GetProperty("clientConfig").GetProperty("claudeCode").GetProperty("shape");
        var node = JsonNode.Parse(McpClientConfig.ClaudeCodeJson(Token))!;
        Assert.Equal(shape.GetProperty("type").GetString(), node["type"]!.GetValue<string>());
        Assert.Equal(shape.GetProperty("url").GetString(), node["url"]!.GetValue<string>());
        Assert.Equal("Bearer " + TokenText, node["headers"]!["Authorization"]!.GetValue<string>());
        Assert.Equal("http://127.0.0.1:19847/mcp", McpClientConfig.Endpoint);
    }

    [Fact]
    public void DesktopShapeMatchesTheVector()
    {
        var shape = Spec.Load("mcp-protocol.json").GetProperty("clientConfig").GetProperty("claudeDesktop").GetProperty("shape");
        var node = JsonNode.Parse(McpClientConfig.ClaudeDesktopEntry("<path>", Token))!;
        Assert.True(shape.GetProperty("mcpServers").TryGetProperty("clio", out var clio));
        Assert.Equal(clio.EnumerateObject().Select(p => p.Name).Order(), node["mcpServers"]!["clio"]!.AsObject().Select(p => p.Key).Order());
    }

    [Fact]
    public void WritingTheDesktopFileKeepsABackupAndOtherServers()
    {
        using var temp = new TempDirectory();
        var path = temp.Combine("Claude", "claude_desktop_config.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "{ \"mcpServers\": { \"keep\": { \"command\": \"k\" } } }");
        McpClientConfig.WriteDesktopConfig(path, "bridge.exe", Token);
        var written = JsonNode.Parse(File.ReadAllText(path))!;
        Assert.Equal("k", written["mcpServers"]!["keep"]!["command"]!.GetValue<string>());
        Assert.Equal("bridge.exe", written["mcpServers"]!["clio"]!["command"]!.GetValue<string>());
        Assert.Contains("keep", File.ReadAllText(path + ".bak"));
        Assert.DoesNotContain(TokenText, File.ReadAllText(path + ".bak"));
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(path)!, "*.tmp"));
        // A damaged file is left alone.
        File.WriteAllText(path, "{ broken");
        Assert.Throws<McpException>(() => McpClientConfig.WriteDesktopConfig(path, "bridge.exe", Token));
        Assert.Equal("{ broken", File.ReadAllText(path));
    }

    [Fact]
    public void ServiceWriteReportsFailureInsteadOfThrowing()
    {
        using var temp = new TempDirectory();
        var host = new FakeHost();
        using var service = new McpService(host, new MemoryMcpClientStore(), 0);
        var id = service.AddClient("c", new HashSet<Guid> { host.WorkspaceId })!.Value;
        var path = temp.Combine("claude_desktop_config.json");
        File.WriteAllText(path, "{ broken");
        Assert.False(service.WriteClaudeDesktopConfig(id, "b.exe", path));
        Assert.NotNull(service.ErrorMessage);
        File.Delete(path);
        Assert.True(service.WriteClaudeDesktopConfig(id, "b.exe", path));
        Assert.False(service.WriteClaudeDesktopConfig(Guid.NewGuid(), "b.exe", path));
    }
}
