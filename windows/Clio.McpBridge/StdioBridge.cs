using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Clio.McpBridge;

/// <summary>
/// Client-launched stdio-to-HTTP adapter, not a daemon. It never launches Clio and never touches documents:
/// every authorization decision stays in the running app. It talks only to the fixed loopback endpoint,
/// uses no proxy, and refuses redirects so the bearer token cannot be sent to another origin.
/// Input is newline-delimited JSON-RPC; one reply line is written per forwarded request.
/// </summary>
public sealed class StdioBridge : IDisposable
{
    public const string DefaultEndpoint = "http://127.0.0.1:19847/mcp";
    public const string TokenVariable = "CLIO_MCP_TOKEN";
    private const int MaximumLineBytes = 1_048_576;
    private const int MaximumResponseBytes = 4_194_304;
    private const int MaximumOutstanding = 16;

    private readonly Uri _endpoint;
    private readonly string _token;
    private readonly HttpClient _http;
    private readonly SemaphoreSlim _slots = new(MaximumOutstanding);
    private readonly object _sessionLock = new();
    private readonly object _outputLock = new();
    private string? _sessionId;
    private string _version = "2025-11-25";
    private Stream _output = Stream.Null;
    private Stream _error = Stream.Null;

    public StdioBridge(string tokenBase64, Uri? endpoint = null, HttpMessageHandler? handler = null)
    {
        _endpoint = endpoint ?? new Uri(DefaultEndpoint);
        // The only acceptable destination is plain HTTP to the IPv4 loopback literal.
        if (_endpoint.Scheme != Uri.UriSchemeHttp || _endpoint.Host != "127.0.0.1" || _endpoint.AbsolutePath != "/mcp")
            throw new ArgumentException("The bridge only talks to http://127.0.0.1:<port>/mcp.", nameof(endpoint));
        Span<byte> token = stackalloc byte[32];
        if (!Convert.TryFromBase64String(tokenBase64, token, out var written) || written != 32)
            throw new ArgumentException("The MCP token must be 32 bytes, base64 encoded.", nameof(tokenBase64));
        _token = tokenBase64;
        _http = new HttpClient(handler ?? new SocketsHttpHandler
        {
            UseProxy = false,
            AllowAutoRedirect = false,
            UseCookies = false,
            ConnectTimeout = TimeSpan.FromSeconds(5),
        })
        {
            Timeout = TimeSpan.FromSeconds(115),
            MaxResponseContentBufferSize = MaximumResponseBytes,
        };
    }

    public async Task RunAsync(Stream input, Stream output, Stream error, CancellationToken ct = default)
    {
        _output = output;
        _error = error;
        var pending = new List<Task>();
        var line = new MemoryStream();
        var buffer = new byte[16_384];
        while (true)
        {
            var count = await input.ReadAsync(buffer, ct);
            if (count == 0) break;
            for (var i = 0; i < count; i++)
            {
                if (buffer[i] != (byte)'\n')
                {
                    line.WriteByte(buffer[i]);
                    if (line.Length > MaximumLineBytes) { Fail(); await DrainAsync(pending); return; }
                    continue;
                }
                var barrier = Forward(line.ToArray(), pending);
                line.SetLength(0);
                if (barrier is not null) await barrier;
            }
        }
        if (line.Length > 0)
        {
            var barrier = Forward(line.ToArray(), pending);
            if (barrier is not null) await barrier;
        }
        await DrainAsync(pending);
    }

    private static async Task DrainAsync(List<Task> pending)
    {
        try { await Task.WhenAll(pending).WaitAsync(TimeSpan.FromSeconds(120)); }
        catch (Exception e) when (e is TimeoutException or OperationCanceledException) { }
    }

    /// <summary>Starts the request. Returns a task to await when ordering matters (initialize handshake).</summary>
    private Task? Forward(byte[] raw, List<Task> pending)
    {
        var length = raw.Length;
        while (length > 0 && raw[length - 1] == (byte)'\r') length--;
        if (length == 0) return null;
        var lineBytes = raw.AsMemory(0, length);

        string method;
        JsonElement? id;
        try
        {
            using var document = JsonDocument.Parse(lineBytes);
            if (document.RootElement.ValueKind != JsonValueKind.Object
                || !document.RootElement.TryGetProperty("method", out var m) || m.ValueKind != JsonValueKind.String)
            { Fail(); return null; }
            method = m.GetString()!;
            id = document.RootElement.TryGetProperty("id", out var i) ? i.Clone() : null;
        }
        catch (JsonException) { Fail(); return null; }

        if (!_slots.Wait(0))
        {
            if (id is { } busy) EmitError(busy, "Too many outstanding requests");
            return null;
        }
        var task = Task.Run(() => SendAsync(lineBytes, method, id));
        lock (pending) { pending.RemoveAll(t => t.IsCompleted); pending.Add(task); }
        // Preserve the initialization barrier while allowing concurrent calls and cancellations afterwards.
        return method is "initialize" or "notifications/initialized" ? task : null;
    }

    private async Task SendAsync(ReadOnlyMemory<byte> body, string method, JsonElement? id)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, _endpoint) { Content = new ReadOnlyMemoryContent(body) };
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
            request.Headers.TryAddWithoutValidation("Accept", "application/json, text/event-stream");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _token);
            if (method != "initialize")
            {
                lock (_sessionLock)
                {
                    if (_sessionId is not null) request.Headers.TryAddWithoutValidation("MCP-Session-Id", _sessionId);
                    request.Headers.TryAddWithoutValidation("MCP-Protocol-Version", _version);
                }
            }
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseContentRead);
            if (response.StatusCode is not (HttpStatusCode.OK or HttpStatusCode.Accepted))
            {
                if (id is { } failed) EmitError(failed, "Clio is unavailable or access was revoked. Open Clio and check MCP Settings.");
                return;
            }
            var data = await response.Content.ReadAsByteArrayAsync();
            if (method == "initialize" && response.Headers.TryGetValues("MCP-Session-Id", out var sessions))
            {
                lock (_sessionLock)
                {
                    _sessionId = sessions.FirstOrDefault();
                    try
                    {
                        using var reply = JsonDocument.Parse(data);
                        if (reply.RootElement.TryGetProperty("result", out var result)
                            && result.TryGetProperty("protocolVersion", out var negotiated)
                            && negotiated.ValueKind == JsonValueKind.String)
                            _version = negotiated.GetString()!;
                    }
                    catch (JsonException) { }
                }
            }
            if (data.Length > 0 && data.Length <= MaximumResponseBytes) EmitCompact(data);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or OperationCanceledException or IOException)
        {
            if (id is { } unavailable) EmitError(unavailable, "Clio is unavailable or access was revoked. Open Clio and check MCP Settings.");
        }
        finally { _slots.Release(); }
    }

    /// <summary>Re-serializes so a reply can never contain a raw line break that would split the stdio framing.</summary>
    private void EmitCompact(byte[] data)
    {
        try
        {
            using var document = JsonDocument.Parse(data);
            using var buffer = new MemoryStream();
            using (var writer = new Utf8JsonWriter(buffer)) document.WriteTo(writer);
            Emit(buffer.ToArray());
        }
        catch (JsonException) { /* A reply that is not JSON is dropped rather than forwarded. */ }
    }

    private void EmitError(JsonElement id, string message)
    {
        using var buffer = new MemoryStream();
        using (var writer = new Utf8JsonWriter(buffer))
        {
            writer.WriteStartObject();
            writer.WriteString("jsonrpc", "2.0");
            writer.WritePropertyName("id");
            id.WriteTo(writer);
            writer.WriteStartObject("error");
            writer.WriteNumber("code", -32000);
            writer.WriteString("message", message);
            writer.WriteEndObject();
            writer.WriteEndObject();
        }
        Emit(buffer.ToArray());
    }

    private void Emit(byte[] json)
    {
        lock (_outputLock)
        {
            try
            {
                _output.Write(json);
                _output.WriteByte((byte)'\n');
                _output.Flush();
            }
            catch (IOException) { }
        }
    }

    private void Fail()
    {
        lock (_outputLock)
        {
            try { _error.Write(Encoding.UTF8.GetBytes("Invalid or oversized MCP input.\n")); _error.Flush(); }
            catch (IOException) { }
        }
    }

    public void Dispose() => _http.Dispose();
}
