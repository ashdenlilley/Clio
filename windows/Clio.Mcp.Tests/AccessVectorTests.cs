using System.Text;
using System.Text.Json;
using Clio.Mcp;
using Xunit;

namespace Clio.Mcp.Tests;

/// <summary>Port of MCPAccessTests, driven by spec/vectors/mcp-access.json.</summary>
public class AccessVectorTests
{
    private static readonly JsonElement V = Spec.Load("mcp-access.json");

    private static McpErrorCode ErrorOf(Action action) =>
        Assert.Throws<McpException>(action).Code;

    private static McpErrorCode Named(string name) => Enum.Parse<McpErrorCode>(name, ignoreCase: true);

    [Fact]
    public void LoopbackPolicyRejectsForeignHostAndEveryBrowserOrigin()
    {
        var loopback = V.GetProperty("loopback");
        var policy = new LoopbackPolicy((ushort)V.GetProperty("port").GetInt32());
        var valid = loopback.GetProperty("validHost").GetString();
        policy.Validate(valid, null, 10);
        foreach (var host in loopback.GetProperty("rejectedHosts").EnumerateArray())
            Assert.Equal(McpErrorCode.InvalidHost, ErrorOf(() => policy.Validate(host.GetString(), null, 10)));
        Assert.Equal(McpErrorCode.InvalidHost, ErrorOf(() => policy.Validate(null, null, 10)));
        foreach (var origin in loopback.GetProperty("rejectedOrigins").EnumerateArray())
            Assert.Equal(McpErrorCode.ForbiddenOrigin, ErrorOf(() => policy.Validate(valid, origin.GetString(), 10)));
        foreach (var row in loopback.GetProperty("bodyBytes").EnumerateArray())
        {
            var count = row.GetProperty("count").GetInt64();
            if (row.GetProperty("ok").GetBoolean()) policy.Validate(valid, null, count);
            else Assert.Equal(McpErrorCode.OversizedRequest, ErrorOf(() => policy.Validate(valid, null, count)));
        }
        Assert.Equal(McpErrorCode.InvalidHost, ErrorOf(() => new LoopbackPolicy(0).Validate("127.0.0.1:0", null, 1)));
    }

    [Fact]
    public void TextReplacementHonoursUtf16AndComposedCharacterBoundaries()
    {
        var replacement = V.GetProperty("textReplacement");
        var source = replacement.GetProperty("source").GetString()!;
        foreach (var row in replacement.GetProperty("accepted").EnumerateArray())
        {
            var edit = new McpTextReplacement(row.GetProperty("location").GetInt64(), row.GetProperty("length").GetInt64(), row.GetProperty("text").GetString()!);
            Assert.Equal(row.GetProperty("result").GetString(), edit.Applying(source));
        }
        foreach (var row in replacement.GetProperty("rejected").EnumerateArray())
        {
            var edit = new McpTextReplacement(row.GetProperty("location").GetInt64(), row.GetProperty("length").GetInt64(), row.GetProperty("text").GetString()!);
            Assert.Equal(McpErrorCode.InvalidRange, ErrorOf(() => edit.Applying(source)));
        }
        var empty = replacement.GetProperty("emptySource");
        Assert.Equal(empty.GetProperty("result").GetString(),
            new McpTextReplacement(0, 0, empty.GetProperty("text").GetString()!).Applying(""));
        var oversized = Spec.Repeated(replacement.GetProperty("oversizedText"));
        Assert.Throws<McpException>(() => new McpTextReplacement(0, 0, oversized).Applying(""));
    }

    [Fact]
    public void AuthorizationRejectsAmbiguousTokensBlankNamesAndEmptyScope()
    {
        var workspace = new HashSet<Guid> { Guid.NewGuid() };
        var token = Enumerable.Repeat((byte)5, 32).ToArray();
        var access = new McpAccessController();
        Assert.Equal(McpErrorCode.InvalidRequest, ErrorOf(() => access.AuthorizeClient("Client", token, new HashSet<Guid>())));
        Assert.Equal(McpErrorCode.InvalidRequest, ErrorOf(() => access.AuthorizeClient("Client", [], workspace)));
        Assert.Equal(McpErrorCode.InvalidRequest, ErrorOf(() => access.AuthorizeClient("   ", token, workspace)));
        Assert.Equal(McpErrorCode.InvalidRequest, ErrorOf(() => access.AuthorizeClient(new string('n', 129), token, workspace)));
        Assert.Equal(McpErrorCode.InvalidRequest, ErrorOf(() => access.AuthorizeClient("bad\u0007name", token, workspace)));
        access.AuthorizeClient("Client", token, workspace);
        Assert.Equal(McpErrorCode.InvalidRequest,
            ErrorOf(() => access.AuthorizeClient("Other", token, new HashSet<Guid> { Guid.NewGuid() })));
        // The 32 client cap.
        for (byte b = 10; b < 10 + 31; b++) access.AuthorizeClient("c" + b, Enumerable.Repeat(b, 32).ToArray(), workspace);
        Assert.Equal(McpErrorCode.InvalidRequest,
            ErrorOf(() => access.AuthorizeClient("overflow", Enumerable.Repeat((byte)99, 32).ToArray(), workspace)));
    }

    [Fact]
    public void DefaultDisabledRevocationAndPauseInvalidateOutstandingGrants()
    {
        var workspace = Guid.NewGuid();
        var token = Enumerable.Repeat((byte)0x31, 32).ToArray();
        var access = new McpAccessController();
        var id = access.AuthorizeClient("Test client", token, new HashSet<Guid> { workspace });
        Assert.Equal(McpErrorCode.Disabled, ErrorOf(() => access.Authenticate(token)));
        access.SetEnabled(true);
        var grant = access.Authenticate(token);
        access.Validate(grant, workspace);
        Assert.Equal(McpErrorCode.OutsideWorkspace, ErrorOf(() => access.Validate(grant, Guid.NewGuid())));
        Assert.Equal(McpErrorCode.Unauthorized, ErrorOf(() => access.Authenticate(Enumerable.Repeat((byte)0x32, 32).ToArray())));
        Assert.Equal(McpErrorCode.Unauthorized, ErrorOf(() => access.Authenticate(new byte[31])));
        access.SetEnabled(false);
        access.SetEnabled(true);
        Assert.Equal(McpErrorCode.Unauthorized, ErrorOf(() => access.Validate(grant, workspace)));
        var resumed = access.Authenticate(token);
        access.Revoke(id);
        Assert.Equal(McpErrorCode.Unauthorized, ErrorOf(() => access.Validate(resumed, workspace)));
        Assert.Equal(McpErrorCode.Unauthorized, ErrorOf(() => access.Authenticate(token)));
    }

    [Fact]
    public void StopInvalidatesGrantsAndForgetsClients()
    {
        var workspace = Guid.NewGuid();
        var token = Enumerable.Repeat((byte)5, 32).ToArray();
        var access = new McpAccessController();
        access.AuthorizeClient("Client", token, new HashSet<Guid> { workspace });
        access.SetEnabled(true);
        var grant = access.Authenticate(token);
        access.Stop();
        access.SetEnabled(true);
        Assert.Equal(McpErrorCode.Unauthorized, ErrorOf(() => access.Validate(grant, workspace)));
        Assert.Equal(McpErrorCode.Unauthorized, ErrorOf(() => access.Authenticate(token)));
    }

    [Fact]
    public void RetryLedgerReplaysResultsAndNeverEvictsMutations()
    {
        var ledger = new McpMutationLedger(V.GetProperty("ledger").GetProperty("capacity").GetInt32());
        var clients = new Dictionary<string, Guid>();
        var requests = new Dictionary<string, Guid>();
        Guid Client(string name) => clients.TryGetValue(name, out var g) ? g : clients[name] = Guid.NewGuid();
        Guid Request(string name) => requests.TryGetValue(name, out var g) ? g : requests[name] = Guid.NewGuid();
        foreach (var step in V.GetProperty("ledger").GetProperty("steps").EnumerateArray())
        {
            var expect = step.GetProperty("expect").GetString()!;
            var client = Client(step.GetProperty("client").GetString()!);
            var request = Request(step.GetProperty("request").GetString()!);
            if (step.GetProperty("op").GetString() == "reserve")
            {
                var arguments = Encoding.UTF8.GetBytes(step.GetProperty("arguments").GetString()!);
                if (expect is "execute" or "pending" or "completed" || expect.StartsWith("completed:", StringComparison.Ordinal))
                {
                    var reservation = ledger.Reserve(client, request, arguments);
                    if (expect.StartsWith("completed:", StringComparison.Ordinal))
                    {
                        Assert.Equal(McpMutationLedger.Kind.Completed, reservation.Kind);
                        Assert.Equal(expect["completed:".Length..], Encoding.UTF8.GetString(reservation.Result!));
                    }
                    else Assert.Equal(Enum.Parse<McpMutationLedger.Kind>(expect, true), reservation.Kind);
                }
                else Assert.Equal(Named(expect), ErrorOf(() => ledger.Reserve(client, request, arguments)));
            }
            else
            {
                var result = Encoding.UTF8.GetBytes(step.GetProperty("result").GetString()!);
                if (expect == "ok") ledger.Complete(client, request, result);
                else Assert.Equal(Named(expect), ErrorOf(() => ledger.Complete(client, request, result)));
            }
        }
    }

    [Fact]
    public void DeletionNeedsOneShotNativeApprovalBoundToRevisionAndClient()
    {
        double now = 0;
        var approvals = new McpDeletionApprovals(() => now);
        var documentId = Guid.NewGuid();
        var incarnation = Guid.NewGuid();
        var clients = new Dictionary<string, Guid>();
        var named = new Dictionary<string, Guid>();
        Guid Client(string name) => clients.TryGetValue(name, out var g) ? g : clients[name] = Guid.NewGuid();
        McpRevision Revision(long n) => new(incarnation, documentId, (ulong)n);
        foreach (var step in V.GetProperty("deletionApprovals").GetProperty("steps").EnumerateArray())
        {
            now = step.TryGetProperty("at", out var at) ? at.GetDouble() : now;
            var expect = step.GetProperty("expect").GetString()!;
            if (step.GetProperty("op").GetString() == "record")
            {
                named[step.GetProperty("name").GetString()!] = approvals.RecordNativeConfirmation(
                    Client(step.GetProperty("client").GetString()!), Revision(step.GetProperty("revision").GetInt64()));
                continue;
            }
            var name = step.GetProperty("approval").GetString()!;
            var id = named.TryGetValue(name, out var known) ? known : Guid.NewGuid();
            var client = step.TryGetProperty("client", out var c) ? Client(c.GetString()!) : Guid.NewGuid();
            var revision = Revision(step.TryGetProperty("revision", out var r) ? r.GetInt64() : 0);
            if (expect == "ok") approvals.Consume(id, client, revision);
            else Assert.Equal(Named(expect), ErrorOf(() => approvals.Consume(id, client, revision)));
        }
    }

    [Fact]
    public void ApprovalTableIsBounded()
    {
        var approvals = new McpDeletionApprovals(() => 0);
        var revision = new McpRevision(Guid.NewGuid(), Guid.NewGuid(), 1);
        for (var i = 0; i < 32; i++) approvals.RecordNativeConfirmation(Guid.NewGuid(), revision);
        Assert.Equal(McpErrorCode.InvalidRequest, ErrorOf(() => approvals.RecordNativeConfirmation(Guid.NewGuid(), revision)));
    }

    [Fact]
    public void RevisionTokensRoundTripAndRejectGarbage()
    {
        var revision = new McpRevision(Guid.NewGuid(), Guid.NewGuid(), 42);
        Assert.Equal(revision, McpRevision.Decode(revision.Encode()));
        foreach (var bad in new[] { "", "not base64!", Convert.ToBase64String("{}"u8.ToArray()), Convert.ToBase64String(new byte[2000]) })
            Assert.Equal(McpErrorCode.InvalidRequest, ErrorOf(() => McpRevision.Decode(bad)));
        var tracker = new McpRevisionTracker();
        var document = new object();
        var id = Guid.NewGuid();
        var first = tracker.For(document, id, 1);
        Assert.Equal(first.Incarnation, tracker.For(document, id, 2).Incarnation);
        Assert.NotEqual(first.Incarnation, tracker.For(new object(), id, 1).Incarnation);
    }

    [Fact]
    public void PagerNeverSplitsSurrogatePairs()
    {
        const string text = "A\U0001F642BC";
        var first = McpDocumentPager.Slice(text, 0, 2);
        Assert.Equal("A", first.Text);
        Assert.Equal(1, first.NextOffset);
        var second = McpDocumentPager.Slice(text, 1, 16_384);
        Assert.Equal(text, first.Text + second.Text);
        Assert.Null(second.NextOffset);
        Assert.Equal(McpErrorCode.InvalidRange, ErrorOf(() => McpDocumentPager.Slice(text, 2, 10)));
        Assert.Equal(McpErrorCode.InvalidRange, ErrorOf(() => McpDocumentPager.Slice("\U0001F642", 0, 1)));
        Assert.Equal(McpErrorCode.InvalidRange, ErrorOf(() => McpDocumentPager.Slice(text, 0, 16_385)));
        Assert.Equal(McpErrorCode.InvalidRange, ErrorOf(() => McpDocumentPager.Slice(text, 99, 1)));
    }
}
