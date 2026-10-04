using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using Clio.Mcp;
using Clio.McpBridge;
using Xunit;

namespace Clio.Mcp.Tests;

public class BridgeTests
{
    private static readonly string Token = Convert.ToBase64String(Enumerable.Repeat((byte)7, 32).ToArray());

    private static async Task<(List<JsonNode> Replies, string Error)> RunAsync(StdioBridge bridge, params string[] lines)
    {
        var input = new MemoryStream(Encoding.UTF8.GetBytes(string.Concat(lines.Select(l => l + "\n"))));
        var output = new MemoryStream();
        var error = new MemoryStream();
        await bridge.RunAsync(input, output, error).WaitAsync(TimeSpan.FromSeconds(30));
        var text = Encoding.UTF8.GetString(output.ToArray());
        Assert.DoesNotContain("\r", text);
        var replies = text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => JsonNode.Parse(l)!).ToList();
        return (replies, Encoding.UTF8.GetString(error.ToArray()));
    }

    private static string Line(string method, int? id = null, JsonObject? parameters = null) => Rig.Rpc(method, id, parameters).ToJsonString();

    private sealed class Live : IDisposable
    {
        public Rig Rig { get; } = new();
        public McpHttpServer Server { get; } = new(0);
        public Live() { Server.Handler = r => Rig.Router.RespondAsync(r); Server.Start(); }
        public Uri Endpoint => new($"http://127.0.0.1:{Server.Port}/mcp");
        public void Dispose() { Server.Dispose(); Rig.Dispose(); }
    }

    [Fact]
    public async Task FullHandshakeAndToolCallThroughRealHttp()
    {
        using var live = new Live();
        live.Rig.Host.Add("a.md", "alpha");
        using var bridge = new StdioBridge(Token, live.Endpoint);
        var (replies, error) = await RunAsync(bridge,
            Line("initialize", 1, new JsonObject { ["protocolVersion"] = "2025-06-18" }),
            Line("notifications/initialized"),
            Line("tools/list", 2),
            Line("tools/call", 3, new JsonObject
            {
                ["name"] = "list_documents",
                ["arguments"] = new JsonObject { ["workspaceID"] = McpTools.Id(live.Rig.Host.WorkspaceId) },
            }));
        Assert.Empty(error);
        Assert.Equal(3, replies.Count); // the notification has no reply
        var byId = replies.ToDictionary(r => r["id"]!.GetValue<int>());
        Assert.Equal("2025-06-18", byId[1]["result"]!["protocolVersion"]!.GetValue<string>());
        Assert.Equal(12, byId[2]["result"]!["tools"]!.AsArray().Count);
        Assert.Contains("a.md", byId[3]["result"]!["content"]![0]!["text"]!.GetValue<string>());
    }

    [Fact]
    public async Task RevokedOrWrongTokenBecomesAJsonRpcErrorWithoutTheToken()
    {
        using var live = new Live();
        var wrong = Convert.ToBase64String(new byte[32]);
        using var bridge = new StdioBridge(wrong, live.Endpoint);
        var (replies, error) = await RunAsync(bridge, Line("initialize", 1, new JsonObject { ["protocolVersion"] = "2025-11-25" }));
        var message = replies.Single()["error"]!["message"]!.GetValue<string>();
        Assert.Contains("unavailable or access was revoked", message);
        Assert.DoesNotContain(wrong, message + error);
    }

    [Fact]
    public async Task ClioNotRunningIsAnErrorPerRequest()
    {
        var closed = new TcpListener(IPAddress.Loopback, 0);
        closed.Start();
        var port = ((IPEndPoint)closed.LocalEndpoint).Port;
        closed.Stop();
        using var bridge = new StdioBridge(Token, new Uri($"http://127.0.0.1:{port}/mcp"));
        var (replies, _) = await RunAsync(bridge,
            Line("initialize", 1, new JsonObject { ["protocolVersion"] = "2025-11-25" }), Line("notifications/initialized"), Line("tools/list", 2));
        Assert.Equal([1, 2], replies.Select(r => r["id"]!.GetValue<int>()).Order());
        Assert.All(replies, r => Assert.Equal(-32000, r["error"]!["code"]!.GetValue<int>()));
    }

    [Fact]
    public async Task RedirectsAreRefusedSoTheTokenNeverReachesAnotherOrigin()
    {
        var target = new TcpListener(IPAddress.Loopback, 0);
        target.Start();
        var targetPort = ((IPEndPoint)target.LocalEndpoint).Port;
        var hits = 0;
        var accepting = Task.Run(async () =>
        {
            try { while (true) { using var _ = await target.AcceptTcpClientAsync(); Interlocked.Increment(ref hits); } }
            catch (Exception) { }
        });
        var redirector = new TcpListener(IPAddress.Loopback, 0);
        redirector.Start();
        var redirectorPort = ((IPEndPoint)redirector.LocalEndpoint).Port;
        var serving = Task.Run(async () =>
        {
            try
            {
                while (true)
                {
                    using var client = await redirector.AcceptTcpClientAsync();
                    var stream = client.GetStream();
                    var buffer = new byte[8192];
                    _ = await stream.ReadAsync(buffer);
                    var response = $"HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:{targetPort}/mcp\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    await stream.WriteAsync(Encoding.ASCII.GetBytes(response));
                }
            }
            catch (Exception) { }
        });
        try
        {
            using var bridge = new StdioBridge(Token, new Uri($"http://127.0.0.1:{redirectorPort}/mcp"));
            var (replies, _) = await RunAsync(bridge, Line("initialize", 1, new JsonObject { ["protocolVersion"] = "2025-11-25" }));
            Assert.Equal(-32000, replies.Single()["error"]!["code"]!.GetValue<int>());
            await Task.Delay(200);
            Assert.Equal(0, hits);
        }
        finally { target.Stop(); redirector.Stop(); }
        _ = accepting; _ = serving;
    }

    [Theory]
    [InlineData("http://localhost:19847/mcp")]
    [InlineData("http://192.168.1.5:19847/mcp")]
    [InlineData("https://127.0.0.1:19847/mcp")]
    [InlineData("http://127.0.0.1:19847/other")]
    [InlineData("http://[::1]:19847/mcp")]
    [InlineData("http://evil.example/mcp")]
    public void OnlyTheLoopbackEndpointIsAccepted(string endpoint) =>
        Assert.Throws<ArgumentException>(() => new StdioBridge(Token, new Uri(endpoint)));

    [Theory]
    [InlineData("")]
    [InlineData("not base64!")]
    [InlineData("AAAA")]
    public void TheTokenMustBe32Bytes(string token) =>
        Assert.Throws<ArgumentException>(() => new StdioBridge(token));

    [Fact]
    public async Task InvalidLinesAreReportedAndSkippedOversizedInputStops()
    {
        using var live = new Live();
        using var bridge = new StdioBridge(Token, live.Endpoint);
        var (replies, error) = await RunAsync(bridge, "not json", "[]", "{\"method\":5}",
            Line("initialize", 1, new JsonObject { ["protocolVersion"] = "2025-11-25" }));
        Assert.Equal(3, error.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length);
        Assert.Single(replies);

        using var second = new StdioBridge(Token, live.Endpoint);
        var big = new string('x', 1_048_577);
        var (afterBig, bigError) = await RunAsync(second, big, Line("initialize", 1, new JsonObject { ["protocolVersion"] = "2025-11-25" }));
        Assert.Contains("oversized", bigError);
        Assert.Empty(afterBig);
    }

    private sealed class BlockingHandler(string reply) : HttpMessageHandler
    {
        public TaskCompletionSource Release { get; } = new();
        public int Started;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref Started);
            await Release.Task.WaitAsync(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(reply, Encoding.UTF8, "application/json") };
        }
    }

    [Fact]
    public async Task OutstandingRequestsAreCappedAt16()
    {
        var handler = new BlockingHandler("""{"jsonrpc":"2.0","id":1,"result":{}}""");
        using var bridge = new StdioBridge(Token, handler: handler);
        var lines = Enumerable.Range(1, 20).Select(i => Line("ping", i)).ToArray();
        var input = new MemoryStream(Encoding.UTF8.GetBytes(string.Concat(lines.Select(l => l + "\n"))));
        var output = new MemoryStream();
        var run = bridge.RunAsync(input, output, Stream.Null);
        await Task.Delay(500);
        var early = Encoding.UTF8.GetString(output.ToArray()).Split('\n', StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(4, early.Length);
        Assert.All(early, l => Assert.Contains("Too many outstanding requests", l));
        handler.Release.SetResult();
        await run.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(16, handler.Started);
    }

    [Fact]
    public async Task RepliesWithRawLineBreaksAreCompactedSoFramingHolds()
    {
        var handler = new BlockingHandler("{\n  \"jsonrpc\": \"2.0\",\r\n  \"id\": 1,\n  \"result\": {}\n}");
        handler.Release.SetResult();
        using var bridge = new StdioBridge(Token, handler: handler);
        var (replies, _) = await RunAsync(bridge, Line("ping", 1));
        Assert.Single(replies);
        Assert.Equal(1, replies[0]!["id"]!.GetValue<int>());
    }

    [Fact]
    public async Task NonJsonRepliesAreDroppedNotForwarded()
    {
        var handler = new BlockingHandler("<html>captive portal</html>");
        handler.Release.SetResult();
        using var bridge = new StdioBridge(Token, handler: handler);
        var (replies, _) = await RunAsync(bridge, Line("ping", 1));
        Assert.Empty(replies);
    }

    // ---- the real executable --------------------------------------------------------------------------

    private static (int Exit, string Out, string Err) RunExe(string stdin, string? token)
    {
        var dll = Path.Combine(AppContext.BaseDirectory, "clio-mcp-bridge.dll");
        Assert.True(File.Exists(dll), "bridge not built next to the tests");
        var start = new ProcessStartInfo("dotnet", $"\"{dll}\"")
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true,
        };
        start.Environment.Remove(StdioBridge.TokenVariable);
        if (token is not null) start.Environment[StdioBridge.TokenVariable] = token;
        using var process = Process.Start(start)!;
        process.StandardInput.Write(stdin);
        process.StandardInput.Close();
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        Assert.True(process.WaitForExit(30_000), "bridge did not exit");
        return (process.ExitCode, stdout.Result, stderr.Result);
    }

    [Fact]
    public void ExecutableRefusesToStartWithoutAValidToken()
    {
        var (exit, stdout, stderr) = RunExe("", null);
        Assert.Equal(1, exit);
        Assert.Empty(stdout);
        Assert.Contains("CLIO_MCP_TOKEN", stderr);
        var (badExit, _, badErr) = RunExe("", "super-secret-but-wrong");
        Assert.Equal(1, badExit);
        Assert.DoesNotContain("super-secret", badErr);
    }

    /// <summary>
    /// Set CLIO_BRIDGE_EXE to a published (single-file, trimmed) bridge to prove the shipped binary works end
    /// to end against a live server on the real port (19847).
    /// </summary>
    [Fact]
    public async Task PublishedBridgeWorksEndToEnd()
    {
        var exe = Environment.GetEnvironmentVariable("CLIO_BRIDGE_EXE");
        if (string.IsNullOrEmpty(exe)) return;
        // The shipped binary only dials 19847; hold that port with a real server for the duration.
        using var live = new Rig();
        using var server = new McpHttpServer(McpLimits.Port);
        server.Handler = r => live.Router.RespondAsync(r);
        server.Start();
        live.Host.Add("a.md", "alpha");
        var start = new ProcessStartInfo(exe)
        { RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        start.Environment[StdioBridge.TokenVariable] = Token;
        using var process = Process.Start(start)!;
        await process.StandardInput.WriteLineAsync(Line("initialize", 1, new JsonObject { ["protocolVersion"] = "2025-11-25" }));
        await process.StandardInput.WriteLineAsync(Line("notifications/initialized"));
        await process.StandardInput.WriteLineAsync(Line("tools/call", 2, new JsonObject
        {
            ["name"] = "list_documents",
            ["arguments"] = new JsonObject { ["workspaceID"] = McpTools.Id(live.Host.WorkspaceId) },
        }));
        process.StandardInput.Close();
        var output = await process.StandardOutput.ReadToEndAsync();
        Assert.True(process.WaitForExit(30_000));
        Assert.Equal(0, process.ExitCode);
        Assert.Contains("\"protocolVersion\":\"2025-11-25\"", output);
        Assert.Contains("a.md", output);
    }

    [Fact]
    public void ExecutableTalksToTheFixedPortOnly()
    {
        // Nothing listens on 19847 in the test environment; the bridge must answer with an error, not hang or crash.
        using var probe = new TcpListener(IPAddress.Loopback, McpLimits.Port);
        try { probe.Start(); } catch (SocketException) { return; } // the real app is running: skip
        probe.Stop();
        var (exit, stdout, _) = RunExe(Line("initialize", 1, new JsonObject { ["protocolVersion"] = "2025-11-25" }) + "\n", Token);
        Assert.Equal(0, exit);
        Assert.Contains("unavailable or access was revoked", stdout);
        Assert.DoesNotContain(Token, stdout);
    }
}
