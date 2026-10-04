using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Clio.Mcp;

/// <summary>
/// Transport-independent policy (macOS <c>MCPAccessPolicy</c>). No listener is started by this file.
/// All authority changes are native-app operations, never MCP tools.
/// </summary>
public sealed record LoopbackPolicy(ushort Port)
{
    /// <summary>
    /// Called on parsed, duplicate-free HTTP headers before JSON decoding. Browser clients are not supported:
    /// an Origin header is always rejected, including loopback origins. Host must be the exact IPv4 literal,
    /// which also defeats DNS rebinding.
    /// </summary>
    public void Validate(string? host, string? origin, long bodyByteCount)
    {
        if (Port == 0 || host != $"127.0.0.1:{Port.ToString(CultureInfo.InvariantCulture)}")
            throw new McpException(McpErrorCode.InvalidHost);
        if (origin is not null) throw new McpException(McpErrorCode.ForbiddenOrigin);
        if (bodyByteCount < 0 || bodyByteCount > McpLimits.MaximumBodyBytes)
            throw new McpException(McpErrorCode.OversizedRequest);
    }
}

/// <summary>Process-local grant. It cannot be supplied as a JSON argument.</summary>
public sealed class McpClientGrant
{
    internal McpClientGrant(Guid id, IReadOnlySet<Guid> workspaceIds, Guid epoch)
    {
        Id = id; WorkspaceIds = workspaceIds; Epoch = epoch;
    }
    public Guid Id { get; }
    public IReadOnlySet<Guid> WorkspaceIds { get; }
    internal Guid Epoch { get; }
}

public sealed class McpAccessController
{
    private sealed record Client(string Name, byte[] Digest, IReadOnlySet<Guid> Workspaces);

    private readonly object _lock = new();
    private readonly Dictionary<Guid, Client> _clients = [];
    private Guid _epoch = Guid.NewGuid();
    private bool _enabled;

    public bool IsEnabled { get { lock (_lock) return _enabled; } }

    public void SetEnabled(bool enabled)
    {
        lock (_lock)
        {
            _enabled = enabled;
            // Pause/resume invalidates outstanding requests, not just new requests.
            _epoch = Guid.NewGuid();
        }
    }

    /// <summary>
    /// The UI must approve the named client and exact workspace set before calling.
    /// Persist the random token in Credential Manager, never in settings or document files.
    /// </summary>
    public Guid AuthorizeClient(string name, byte[] token, IReadOnlySet<Guid> workspaces, Guid? id = null)
    {
        var clientId = id ?? Guid.NewGuid();
        if (token.Length != 32 || workspaces.Count == 0 || string.IsNullOrWhiteSpace(name)
            || Encoding.UTF8.GetByteCount(name) > McpLimits.FilenameUtf8Bytes
            || name.Any(char.IsControl))
            throw new McpException(McpErrorCode.InvalidRequest);
        var digest = SHA256.HashData(token);
        lock (_lock)
        {
            if (_clients.Count >= McpLimits.MaximumClients || _clients.ContainsKey(clientId)
                || _clients.Values.Any(c => CryptographicOperations.FixedTimeEquals(c.Digest, digest)))
                throw new McpException(McpErrorCode.InvalidRequest);
            _clients[clientId] = new Client(name, digest, workspaces.ToHashSet());
        }
        return clientId;
    }

    public McpClientGrant Authenticate(byte[] token)
    {
        lock (_lock)
        {
            if (!_enabled) throw new McpException(McpErrorCode.Disabled);
            if (token.Length != 32) throw new McpException(McpErrorCode.Unauthorized);
            var digest = SHA256.HashData(token);
            KeyValuePair<Guid, Client>? found = null;
            // Compare every digest so timing does not reveal which client matched.
            foreach (var entry in _clients)
                if (CryptographicOperations.FixedTimeEquals(entry.Value.Digest, digest)) found = entry;
            if (found is not { } hit) throw new McpException(McpErrorCode.Unauthorized);
            return new McpClientGrant(hit.Key, hit.Value.Workspaces, _epoch);
        }
    }

    /// <summary>Recheck after EVERY await and directly before observing or mutating a buffer.</summary>
    public void Validate(McpClientGrant grant, Guid workspaceId)
    {
        lock (_lock)
        {
            if (!_enabled) throw new McpException(McpErrorCode.Disabled);
            if (grant.Epoch != _epoch || !_clients.TryGetValue(grant.Id, out var client))
                throw new McpException(McpErrorCode.Unauthorized);
            if (!client.Workspaces.Contains(workspaceId) || !grant.WorkspaceIds.Contains(workspaceId))
                throw new McpException(McpErrorCode.OutsideWorkspace);
        }
    }

    public void Revoke(Guid clientId)
    {
        lock (_lock) _clients.Remove(clientId);
    }

    public void Stop()
    {
        lock (_lock)
        {
            _enabled = false;
            _epoch = Guid.NewGuid();
            _clients.Clear();
        }
    }
}

/// <summary>Per-document revision. The incarnation stops a counter being reused after a document is reopened.</summary>
public sealed record McpRevision(Guid Incarnation, Guid DocumentId, ulong Revision)
{
    public string Encode() => Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(
        new Wire(Incarnation, DocumentId, Revision)));

    public static McpRevision Decode(string text)
    {
        try
        {
            var bytes = Convert.FromBase64String(text);
            if (bytes.Length >= 1024) throw new McpException(McpErrorCode.InvalidRequest);
            var wire = JsonSerializer.Deserialize<Wire>(bytes) ?? throw new McpException(McpErrorCode.InvalidRequest);
            return new McpRevision(wire.Incarnation, wire.DocumentID, wire.Revision);
        }
        catch (Exception e) when (e is FormatException or JsonException)
        {
            throw new McpException(McpErrorCode.InvalidRequest);
        }
    }

    private sealed record Wire(
        [property: System.Text.Json.Serialization.JsonRequired] Guid Incarnation,
        [property: System.Text.Json.Serialization.JsonRequired] Guid DocumentID,
        [property: System.Text.Json.Serialization.JsonRequired] ulong Revision);
}

/// <summary>Hands out one incarnation id per live document object. Hosts call this when building revisions.</summary>
public sealed class McpRevisionTracker
{
    private sealed class Box(Guid id) { public Guid Id { get; } = id; }
    private readonly System.Runtime.CompilerServices.ConditionalWeakTable<object, Box> _incarnations = new();

    public McpRevision For(object document, Guid documentId, ulong revision) =>
        new(_incarnations.GetValue(document, _ => new Box(Guid.NewGuid())).Id, documentId, revision);
}

/// <summary>A UTF-16 range replacement. Produces a candidate only; the editor adapter commits it.</summary>
public sealed record McpTextReplacement(long Location, long Length, string Text)
{
    public string Applying(string source)
    {
        var count = source.Length;
        if (Location < 0 || Length < 0 || Location > count || Length > count - Location
            || Encoding.UTF8.GetByteCount(Text) > McpLimits.MaximumBodyBytes)
            throw new McpException(McpErrorCode.InvalidRange);
        var start = (int)Location;
        var end = start + (int)Length;
        // Reject partial surrogate pairs and partial composed characters.
        var boundaries = new HashSet<int>(StringInfo.ParseCombiningCharacters(source)) { count };
        if (!boundaries.Contains(start) || !boundaries.Contains(end))
            throw new McpException(McpErrorCode.InvalidRange);
        var removedBytes = Encoding.UTF8.GetByteCount(source.AsSpan(start, end - start));
        if ((long)Encoding.UTF8.GetByteCount(source) - removedBytes > McpLimits.MaximumBodyBytes - Encoding.UTF8.GetByteCount(Text))
            throw new McpException(McpErrorCode.OversizedRequest);
        return string.Concat(source.AsSpan(0, start), Text, source.AsSpan(end));
    }
}

/// <summary>
/// Per-client retry ledger. Never evicts a successful mutation within a live session: at capacity it
/// fails closed. Otherwise an old retry could be silently reapplied.
/// </summary>
public sealed class McpMutationLedger(int capacity = 256)
{
    public enum Kind { Execute, Pending, Completed }
    public sealed record Reservation(Kind Kind, byte[]? Result = null);

    private sealed class Entry(byte[] digest) { public byte[] Digest { get; } = digest; public byte[]? Result { get; set; } }
    private const int ReservedResultBytes = 16_384;
    private const int MaximumResultBytes = 4 * 1_048_576;

    private readonly object _lock = new();
    private readonly Dictionary<(Guid Client, Guid Request), Entry> _entries = [];
    private readonly int _capacity = Math.Max(1, capacity);
    private int _resultBytes;

    public Reservation Reserve(Guid client, Guid request, byte[] canonicalArguments)
    {
        if (canonicalArguments.Length > McpLimits.MaximumBodyBytes) throw new McpException(McpErrorCode.OversizedRequest);
        var digest = SHA256.HashData(canonicalArguments);
        lock (_lock)
        {
            if (_entries.TryGetValue((client, request), out var entry))
            {
                if (!CryptographicOperations.FixedTimeEquals(entry.Digest, digest))
                    throw new McpException(McpErrorCode.RetryConflict);
                return entry.Result is { } result ? new Reservation(Kind.Completed, result) : new Reservation(Kind.Pending);
            }
            if (_entries.Count >= _capacity || _resultBytes > MaximumResultBytes - ReservedResultBytes)
                throw new McpException(McpErrorCode.RetryCapacity);
            _entries[(client, request)] = new Entry(digest);
            // Reserve bounded result space before any side effect can occur.
            _resultBytes += ReservedResultBytes;
            return new Reservation(Kind.Execute);
        }
    }

    /// <summary>Complete with success OR terminal failure; never remove after a possibly committed side effect.</summary>
    public void Complete(Guid client, Guid request, byte[] result)
    {
        lock (_lock)
        {
            if (!_entries.TryGetValue((client, request), out var entry) || entry.Result is not null)
                throw new McpException(McpErrorCode.InvalidRequest);
            if (result.Length > ReservedResultBytes) throw new McpException(McpErrorCode.OversizedRequest);
            entry.Result = result;
        }
    }
}

/// <summary>
/// Native-only one-shot deletion approval. A model cannot mint an approval by embedding instructions in a
/// document or submitting a tool argument: only the app's confirmation callback records one.
/// </summary>
public sealed class McpDeletionApprovals(Func<double>? now = null)
{
    private sealed record Approval(Guid Client, McpRevision Revision, double Expires);

    private readonly object _lock = new();
    private readonly Dictionary<Guid, Approval> _approvals = [];
    private readonly Func<double> _now = now ?? (() => System.Diagnostics.Stopwatch.GetTimestamp() / (double)System.Diagnostics.Stopwatch.Frequency);

    public Guid RecordNativeConfirmation(Guid client, McpRevision revision)
    {
        lock (_lock)
        {
            var time = _now();
            foreach (var key in _approvals.Where(a => a.Value.Expires <= time).Select(a => a.Key).ToList()) _approvals.Remove(key);
            if (_approvals.Count >= 32) throw new McpException(McpErrorCode.InvalidRequest);
            var id = Guid.NewGuid();
            _approvals[id] = new Approval(client, revision, time + McpLimits.ApprovalLifetime.TotalSeconds);
            return id;
        }
    }

    public void Consume(Guid id, Guid client, McpRevision revision)
    {
        lock (_lock)
        {
            if (!_approvals.Remove(id, out var approval)) throw new McpException(McpErrorCode.ApprovalRequired);
            if (approval.Expires <= _now()) throw new McpException(McpErrorCode.ExpiredApproval);
            if (approval.Client != client) throw new McpException(McpErrorCode.Unauthorized);
            if (approval.Revision != revision) throw new McpException(McpErrorCode.StaleRevision);
        }
    }
}
