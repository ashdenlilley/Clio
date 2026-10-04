using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Clio.Mcp;
using Xunit;

namespace Clio.Mcp.Tests;

/// <summary>Port of the framing test in MCPProtocolTests plus the loopback listener hardening.</summary>
public class HttpFramingTests
{
    private static readonly JsonElement V = Spec.Load("mcp-protocol.json");
    private static JsonElement Framing => V.GetProperty("httpFraming");
    private const ushort Port = 19847;

    private static byte[] Bytes(string text) => Encoding.UTF8.GetBytes(text);

    private static McpErrorCode Decode(string raw) =>
        Assert.Throws<McpException>(() => McpHttpRequest.Decode(Bytes(raw), Port)).Code;

    [Fact]
    public void FramingRejectsSmugglingAndPartialBodies()
    {
        var head = Framing.GetProperty("head").GetString()!;
        var body = Framing.GetProperty("body").GetString()!;
        Assert.Null(McpHttpRequest.Decode(Bytes(head + "\r\n" + Framing.GetProperty("incompleteBody").GetString()), Port));
        Assert.Equal(Bytes(body), McpHttpRequest.Decode(Bytes(head + "\r\n" + body), Port)!.Body);
        foreach (var row in Framing.GetProperty("extraHeadersRejected").EnumerateArray())
            Assert.Equal(Enum.Parse<McpErrorCode>(row.GetProperty("error").GetString()!, true),
                Decode(head + row.GetProperty("header").GetString() + "\r\n" + body));
        Assert.Equal(McpErrorCode.InvalidRequest, Decode(head + "\r\n" + Framing.GetProperty("trailingBytesRejected").GetString()));
        Assert.Equal(McpErrorCode.OversizedRequest, Decode(Spec.Repeated(Framing.GetProperty("oversizedWithoutHeadTerminator"))));
    }

    [Fact]
    public void MalformedRequestsAreRejectedWithTheSpecifiedError()
    {
        foreach (var row in Framing.GetProperty("malformed").EnumerateArray())
        {
            const string method = "{}";
            Assert.Equal(Enum.Parse<McpErrorCode>(row.GetProperty("error").GetString()!, true),
                Decode(row.GetProperty("head").GetString() + "\r\n" + method));
        }
    }

    [Fact]
    public void ErrorStatusMapping()
    {
        var map = Framing.GetProperty("errorStatus");
        Assert.Equal(map.GetProperty("forbiddenOrigin").GetInt32(), McpHttpRequest.StatusFor(new McpException(McpErrorCode.ForbiddenOrigin)));
        Assert.Equal(map.GetProperty("invalidHost").GetInt32(), McpHttpRequest.StatusFor(new McpException(McpErrorCode.InvalidHost)));
        Assert.Equal(map.GetProperty("oversizedRequest").GetInt32(), McpHttpRequest.StatusFor(new McpException(McpErrorCode.OversizedRequest)));
        Assert.Equal(map.GetProperty("other").GetInt32(), McpHttpRequest.StatusFor(new McpException(McpErrorCode.InvalidRequest)));
    }

    [Fact]
    public void GetAndDeleteWithoutBodyAreAccepted()
    {
        const string get = "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:19847\r\n\r\n";
        Assert.Equal("GET", McpHttpRequest.Decode(Bytes(get), Port)!.Method);
        const string delete = "DELETE /mcp HTTP/1.1\r\nHost: 127.0.0.1:19847\r\nContent-Length: 0\r\n\r\n";
        Assert.Equal("DELETE", McpHttpRequest.Decode(Bytes(delete), Port)!.Method);
    }

    [Fact]
    public void ContentLengthBeyondTheLimitIsOversizedAndNeverBuffered()
    {
        var head = Framing.GetProperty("head").GetString()!.Replace("Content-Length: 2", "Content-Length: 99999999999");
        Assert.Equal(McpErrorCode.OversizedRequest, Decode(head + "\r\n"));
        head = Framing.GetProperty("head").GetString()!.Replace("Content-Length: 2", "Content-Length: 1048577");
        Assert.Equal(McpErrorCode.OversizedRequest, Decode(head + "\r\n"));
    }

    [Fact]
    public void InvalidUtf8AndBareLineFeedsAreRejected()
    {
        var invalid = new List<byte>(Bytes("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:19847\r\nX-A: "));
        invalid.AddRange([0xFF, 0xFE]);
        invalid.AddRange(Bytes("\r\n\r\n"));
        Assert.Equal(McpErrorCode.InvalidRequest, Assert.Throws<McpException>(() => McpHttpRequest.Decode(invalid.ToArray(), Port)).Code);
        // A header line with a bare LF is not a line break: it becomes part of one value and trips the control check.
        Assert.Equal(McpErrorCode.InvalidRequest,
            Decode("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:19847\nX-A: b\r\nContent-Length: 0\r\n\r\n"));
    }

    [Fact]
    public void ResponseEncodingNeverAllowsHeaderInjection()
    {
        var response = new McpHttpResponse(200, new Dictionary<string, string> { ["MCP-Session-Id"] = "ok", ["X-Evil"] = "a\r\nSet-Cookie: x" }, "{}"u8.ToArray());
        var text = Encoding.ASCII.GetString(response.Encode());
        Assert.Contains("MCP-Session-Id: ok\r\n", text);
        Assert.DoesNotContain("Set-Cookie", text);
        Assert.Contains("Content-Length: 2\r\n", text);
        Assert.StartsWith("HTTP/1.1 200 OK\r\n", text);
    }
}

/// <summary>Real sockets: the listener is loopback-only, exclusive and strict.</summary>
public class HttpServerTests
{
    private static async Task<string> RawAsync(ushort port, string request, int bytesToSend = -1)
    {
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, port);
        var stream = client.GetStream();
        var data = Encoding.UTF8.GetBytes(request);
        await stream.WriteAsync(data.AsMemory(0, bytesToSend < 0 ? data.Length : bytesToSend));
        var buffer = new byte[65_536];
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var all = new MemoryStream();
        try
        {
            int count;
            while ((count = await stream.ReadAsync(buffer, timeout.Token)) > 0) all.Write(buffer, 0, count);
        }
        catch (Exception e) when (e is IOException or OperationCanceledException) { }
        return Encoding.UTF8.GetString(all.ToArray());
    }

    private static string Post(ushort port, string body, string extra = "", string host = "")
    {
        host = host.Length == 0 ? $"127.0.0.1:{port}" : host;
        return $"POST /mcp HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\n{extra}Content-Length: {Encoding.UTF8.GetByteCount(body)}\r\n\r\n{body}";
    }

    private sealed class Running : IDisposable
    {
        public Rig Rig { get; } = new();
        public McpHttpServer Server { get; } = new(0);
        public Running()
        {
            Server.Handler = request => Rig.Router.RespondAsync(request);
            Server.Start();
        }
        public ushort Port => Server.Port;
        public void Dispose() { Server.Dispose(); Rig.Dispose(); }
    }

    [Fact]
    public void BindsTheIPv4LoopbackOnly()
    {
        using var running = new Running();
        var listeners = System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners()
            .Where(l => l.Port == running.Port).ToList();
        Assert.Single(listeners);
        Assert.Equal(IPAddress.Loopback, listeners[0].Address);
    }

    [Fact]
    public void SecondListenerOnTheSamePortIsRefused()
    {
        using var running = new Running();
        using var second = new McpHttpServer(running.Port);
        Assert.Throws<SocketException>(() => second.Start());
        Assert.False(second.IsListening);
    }

    [Fact]
    public async Task EndToEndInitializeListAndCall()
    {
        using var running = new Running();
        running.Rig.Host.Add("a.md", "alpha");
        var token = Convert.ToBase64String(running.Rig.Token);
        using var http = new HttpClient();
        async Task<(HttpResponseMessage Response, JsonNode? Body)> Send(JsonObject body, string? session = null)
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{running.Port}/mcp")
            { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
            request.Headers.TryAddWithoutValidation("Accept", "application/json, text/event-stream");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            if (session is not null)
            {
                request.Headers.Add("MCP-Session-Id", session);
                request.Headers.Add("MCP-Protocol-Version", "2025-11-25");
            }
            var response = await http.SendAsync(request);
            var text = await response.Content.ReadAsStringAsync();
            return (response, text.Length == 0 ? null : JsonNode.Parse(text));
        }
        var (init, initBody) = await Send(Rig.Rpc("initialize", 1, new JsonObject { ["protocolVersion"] = "2025-11-25" }));
        Assert.Equal(HttpStatusCode.OK, init.StatusCode);
        var session = init.Headers.GetValues("MCP-Session-Id").Single();
        Assert.Equal("2025-11-25", initBody!["result"]!["protocolVersion"]!.GetValue<string>());
        Assert.Equal(HttpStatusCode.Accepted, (await Send(Rig.Rpc("notifications/initialized"), session)).Response.StatusCode);
        var (_, list) = await Send(Rig.Rpc("tools/list", 2), session);
        Assert.Equal(12, list!["result"]!["tools"]!.AsArray().Count);
        var (_, call) = await Send(Rig.Rpc("tools/call", 3, new JsonObject
        {
            ["name"] = "list_documents",
            ["arguments"] = new JsonObject { ["workspaceID"] = McpTools.Id(running.Rig.Host.WorkspaceId) },
        }), session);
        Assert.False(call!["result"]!["isError"]!.GetValue<bool>());
        Assert.Contains("a.md", call["result"]!["content"]![0]!["text"]!.GetValue<string>());
    }

    [Fact]
    public async Task WrongTokenIs401WithoutDetail()
    {
        using var running = new Running();
        var body = Rig.Rpc("initialize", 1, new JsonObject { ["protocolVersion"] = "2025-11-25" }).ToJsonString();
        var response = await RawAsync(running.Port, Post(running.Port, body, "Authorization: Bearer " + Convert.ToBase64String(new byte[32]) + "\r\n"));
        Assert.StartsWith("HTTP/1.1 401 Unauthorized", response);
        Assert.DoesNotContain("Test client", response);
        response = await RawAsync(running.Port, Post(running.Port, body));
        Assert.StartsWith("HTTP/1.1 401", response);
    }

    [Theory]
    [InlineData("evil.example:PORT")]
    [InlineData("localhost:PORT")]
    [InlineData("127.0.0.1:1")]
    [InlineData("[::1]:PORT")]
    public async Task ForeignHostHeaderIsRefusedBeforeAnyAuthentication(string host)
    {
        using var running = new Running();
        var response = await RawAsync(running.Port, Post(running.Port, "{}", host: host.Replace("PORT", running.Port.ToString())));
        Assert.StartsWith("HTTP/1.1 403 Forbidden", response);
    }

    [Fact]
    public async Task BrowserOriginIsRefusedEvenWhenItIsLoopback()
    {
        using var running = new Running();
        foreach (var origin in new[] { "null", $"http://127.0.0.1:{running.Port}", "https://evil.example" })
        {
            var response = await RawAsync(running.Port, Post(running.Port, "{}", $"Origin: {origin}\r\n"));
            Assert.StartsWith("HTTP/1.1 403 Forbidden", response);
        }
    }

    [Fact]
    public async Task OversizedAndMalformedRequestsGetStatusCodes()
    {
        using var running = new Running();
        var oversized = $"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{running.Port}\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: 2000000\r\n\r\n";
        Assert.StartsWith("HTTP/1.1 413", await RawAsync(running.Port, oversized));
        Assert.StartsWith("HTTP/1.1 400", await RawAsync(running.Port, "NONSENSE\r\n\r\n"));
        Assert.StartsWith("HTTP/1.1 400", await RawAsync(running.Port,
            Post(running.Port, "{}", "Transfer-Encoding: chunked\r\n")));
    }

    [Fact]
    public async Task StopClosesTheListenerAndOpenConnections()
    {
        var running = new Running();
        var port = running.Port;
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, port);
        running.Dispose();
        await Assert.ThrowsAnyAsync<Exception>(async () =>
        {
            using var again = new TcpClient();
            await again.ConnectAsync(IPAddress.Loopback, port);
        });
        var buffer = new byte[16];
        var read = await Task.WhenAny(client.GetStream().ReadAsync(buffer).AsTask(), Task.Delay(3000));
        Assert.True(read.IsCompleted);
    }

    [Fact]
    public async Task ConnectionCapAppliesAndServerRecovers()
    {
        using var running = new Running();
        var held = new List<TcpClient>();
        try
        {
            for (var i = 0; i < McpLimits.MaximumConnections + 4; i++)
            {
                var c = new TcpClient();
                await c.ConnectAsync(IPAddress.Loopback, running.Port);
                held.Add(c);
            }
        }
        finally { foreach (var c in held) c.Dispose(); }
        await Task.Delay(300);
        var response = await RawAsync(running.Port, "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:" + running.Port + "\r\n\r\n");
        Assert.StartsWith("HTTP/1.1 401", response);
    }
}
