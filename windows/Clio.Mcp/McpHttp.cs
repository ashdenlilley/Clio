using System.Globalization;
using System.Text;

namespace Clio.Mcp;

public sealed record McpHttpRequest(string Method, IReadOnlyDictionary<string, string> Headers, byte[] Body)
{
    private static readonly byte[] HeadTerminator = "\r\n\r\n"u8.ToArray();
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    /// <summary>
    /// Deliberately supports a single, length-delimited request per connection. Rejects ambiguous framing
    /// rather than guessing, including duplicate headers. Returns null when more bytes are needed.
    /// </summary>
    public static McpHttpRequest? Decode(ReadOnlySpan<byte> data, ushort port)
    {
        if (data.Length > McpLimits.MaximumBodyBytes + McpLimits.MaximumHeadBytes)
            throw new McpException(McpErrorCode.OversizedRequest);
        var separator = data.IndexOf(HeadTerminator);
        if (separator < 0)
        {
            if (data.Length > McpLimits.MaximumHeadBytes) throw new McpException(McpErrorCode.OversizedRequest);
            return null;
        }
        if (separator > McpLimits.MaximumHeadBytes) throw new McpException(McpErrorCode.InvalidRequest);
        string head;
        try { head = StrictUtf8.GetString(data[..separator]); }
        catch (DecoderFallbackException) { throw new McpException(McpErrorCode.InvalidRequest); }

        var lines = head.Split("\r\n");
        var first = lines[0].Split(' ');
        if (first.Length != 3 || first[1] != "/mcp" || first[2] != "HTTP/1.1"
            || first[0] is not ("POST" or "GET" or "DELETE"))
            throw new McpException(McpErrorCode.InvalidRequest);

        var headers = new Dictionary<string, string>();
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon < 0) throw new McpException(McpErrorCode.InvalidRequest);
            var name = line[..colon].ToLowerInvariant();
            if (name.Length == 0 || !name.All(c => c is >= 'a' and <= 'z' or '-') || headers.ContainsKey(name))
                throw new McpException(McpErrorCode.InvalidRequest);
            var value = line[(colon + 1)..].Trim(' ', '\t');
            if (value.Any(c => c < 32 || c == 127)) throw new McpException(McpErrorCode.InvalidRequest);
            headers[name] = value;
        }
        if (headers.ContainsKey("transfer-encoding") || headers.ContainsKey("expect")
            || !headers.TryGetValue("host", out var host))
            throw new McpException(McpErrorCode.InvalidRequest);

        var rawLength = headers.GetValueOrDefault("content-length") ?? (first[0] == "POST" ? "" : "0");
        if (rawLength.Length == 0 || !rawLength.All(c => c is >= '0' and <= '9')
            || !int.TryParse(rawLength, NumberStyles.None, CultureInfo.InvariantCulture, out var length))
        {
            // A digits-only value too large for int is oversized, not malformed.
            if (rawLength.Length > 0 && rawLength.All(c => c is >= '0' and <= '9'))
                throw new McpException(McpErrorCode.OversizedRequest);
            throw new McpException(McpErrorCode.InvalidRequest);
        }
        new LoopbackPolicy(port).Validate(host, headers.GetValueOrDefault("origin"), length);

        var body = data[(separator + HeadTerminator.Length)..];
        if (body.Length > length) throw new McpException(McpErrorCode.InvalidRequest);
        if (body.Length < length) return null;

        if (first[0] == "POST")
        {
            var type = headers.GetValueOrDefault("content-type")?.Split(';')[0].Trim();
            var accept = headers.GetValueOrDefault("accept");
            if (!string.Equals(type, "application/json", StringComparison.OrdinalIgnoreCase)
                || accept is null
                || !accept.Contains("application/json", StringComparison.OrdinalIgnoreCase)
                || !accept.Contains("text/event-stream", StringComparison.OrdinalIgnoreCase))
                throw new McpException(McpErrorCode.InvalidRequest);
        }
        else if (length != 0) throw new McpException(McpErrorCode.InvalidRequest);
        return new McpHttpRequest(first[0], headers, body.ToArray());
    }

    public static int StatusFor(McpException error) => error.Code switch
    {
        McpErrorCode.ForbiddenOrigin or McpErrorCode.InvalidHost => 403,
        McpErrorCode.OversizedRequest => 413,
        _ => 400,
    };
}

public sealed record McpHttpResponse(int Status, IReadOnlyDictionary<string, string>? Headers = null, byte[]? Body = null)
{
    public byte[] BodyBytes => Body ?? [];

    public byte[] Encode()
    {
        var reason = Status switch
        {
            200 => "OK", 202 => "Accepted", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
            404 => "Not Found", 405 => "Method Not Allowed", 413 => "Content Too Large", 503 => "Service Unavailable",
            _ => "Error",
        };
        var head = new StringBuilder()
            .Append("HTTP/1.1 ").Append(Status).Append(' ').Append(reason).Append("\r\n")
            .Append("Connection: close\r\nCache-Control: no-store\r\nContent-Type: application/json\r\n")
            .Append("Content-Length: ").Append(BodyBytes.Length).Append("\r\n");
        foreach (var (name, value) in (Headers ?? new Dictionary<string, string>()).OrderBy(h => h.Key, StringComparer.Ordinal))
        {
            // Header values come from the router, but never let one smuggle a line break.
            if (name.Any(c => c is '\r' or '\n' or ':') || value.Any(c => c is '\r' or '\n')) continue;
            head.Append(name).Append(": ").Append(value).Append("\r\n");
        }
        head.Append("\r\n");
        return [.. Encoding.ASCII.GetBytes(head.ToString()), .. BodyBytes];
    }
}
