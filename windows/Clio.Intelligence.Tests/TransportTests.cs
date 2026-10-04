using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace Clio.Intelligence.Tests;

public class TransportTests
{
    private static readonly JsonElement Vectors = Spec.Load("intelligence-transport.json");

    private static TypeSafeRequest RequestFrom(JsonElement request)
    {
        var state = Spec.Node(request.GetProperty("state"));
        var questions = new Dictionary<string, TypeSafeQuestion>();
        foreach (var pair in request.GetProperty("questions").EnumerateObject())
        {
            var q = pair.Value;
            var instructions = q.GetProperty("instructions").GetString()!;
            questions[pair.Name] = q.GetProperty("type").GetString() switch
            {
                "noul" => TypeSafeQuestion.Noul(instructions, q.TryGetProperty("criteria", out var c)
                    ? new NoulCriteria(c.GetProperty("true").GetString()!, c.GetProperty("false").GetString()!)
                    : null),
                "choice" => TypeSafeQuestion.Choice(instructions, q.GetProperty("criteria").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString()!)),
                _ => TypeSafeQuestion.Score(instructions, [.. q.GetProperty("criteria").EnumerateArray().Select(e => e.GetString()!)]),
            };
        }
        return new TypeSafeRequest(state, questions);
    }

    [Fact]
    public void ConstantsMatchTheVector()
    {
        Assert.Equal(Vectors.GetProperty("endpoint").GetString(), TypeSafeClient.DefaultEndpoint.ToString());
        Check.Same(Vectors.GetProperty("model").GetString(), TypeSafeRequest.DefaultModel);
        Assert.Equal(Vectors.GetProperty("maximumAttempts").GetInt32(), new TypeSafeClient().MaximumAttempts);
        Assert.Equal(Vectors.GetProperty("timeoutSeconds").GetInt32(), new TypeSafeClient().Timeout.TotalSeconds);
        var budget = Vectors.GetProperty("budget");
        Check.Same(budget.GetProperty("charactersPerToken").GetDouble(), TypeSafeBudget.CharactersPerToken);
        Check.Same(budget.GetProperty("combinedTokenLimit").GetInt32(), TypeSafeBudget.CombinedTokenLimit);
        Check.Same(budget.GetProperty("stateTokenLimit").GetInt32(), TypeSafeBudget.StateTokenLimit);
    }

    [Fact]
    public void RequestsEncodeTheShapeTheEndpointDocuments()
    {
        foreach (var v in Vectors.GetProperty("encoding").EnumerateArray())
        {
            var request = RequestFrom(v.GetProperty("request"));
            var actual = JsonNode.Parse(request.ToBytes())!;
            Assert.True(JsonNode.DeepEquals(Spec.Node(v.GetProperty("expected")), actual), v.GetProperty("name").GetString());
        }
    }

    [Fact]
    public void SerializationIsStableRegardlessOfInsertionOrder()
    {
        var first = new JsonObject { ["b"] = 1, ["a"] = new JsonObject { ["z"] = true, ["y"] = "x" } };
        var second = new JsonObject { ["a"] = new JsonObject { ["y"] = "x", ["z"] = true }, ["b"] = 1 };
        Assert.Equal(StableJson.Serialize(first), StableJson.Serialize(second));
        Assert.Equal("""{"a":{"y":"x","z":true},"b":1}""", Encoding.UTF8.GetString(StableJson.Serialize(first)));
    }

    [Fact]
    public void AnswersDecodeForEveryQuestionType()
    {
        var v = Vectors.GetProperty("decoding");
        var response = TypeSafeResponse.Parse(Encoding.UTF8.GetBytes(v.GetProperty("response").GetRawText()));
        var expected = v.GetProperty("expected");
        Assert.Equal(expected.GetProperty("model").GetString(), response.Model);
        foreach (var n in expected.GetProperty("noul").EnumerateObject())
            Assert.Equal(n.Value.GetDouble(), response[n.Name]!.NoulValue);
        foreach (var c in expected.GetProperty("choice").EnumerateObject())
        {
            var choice = response[c.Name]!.ChoiceValue!;
            Assert.Equal(c.Value.GetProperty("choice").GetString(), choice.Choice);
            Assert.Equal(c.Value.GetProperty("probability").GetDouble(), choice.Probability, 4);
            Assert.Equal(c.Value.GetProperty("confidence").GetDouble(), choice.Confidence, 4);
        }
        foreach (var s in expected.GetProperty("score").EnumerateObject())
        {
            var score = response[s.Name]!.ScoreValue!;
            Assert.Equal(s.Value.GetProperty("score").GetDouble(), score.Score, 4);
            Assert.Equal(s.Value.GetProperty("confidence").GetDouble(), score.Confidence, 4);
        }
        Assert.Equal(expected.GetProperty("inputTokens").GetInt32(), response.Usage.InputTokens);
        Assert.Equal(expected.GetProperty("outputTokens").GetInt32(), response.Usage.OutputTokens);
    }

    [Fact]
    public void MalformedBodiesAreRejected()
    {
        foreach (var v in Vectors.GetProperty("decoding").GetProperty("malformed").EnumerateArray())
        {
            var e = Assert.Throws<TypeSafeException>(() => TypeSafeResponse.Parse(Encoding.UTF8.GetBytes(v.GetProperty("body").GetString()!)));
            Assert.True(e.Kind == TypeSafeErrorKind.MalformedResponse, v.GetProperty("name").GetString());
        }
    }

    [Fact]
    public void BudgetMatchesVectors()
    {
        foreach (var v in Vectors.GetProperty("budget").GetProperty("cases").EnumerateArray())
        {
            var state = v.TryGetProperty("stateRepeat", out var rep)
                ? string.Concat(Enumerable.Repeat(rep.GetProperty("unit").GetString()!, rep.GetProperty("count").GetInt32()))
                : v.GetProperty("state").GetString()!;
            var request = TypeSafeRequest.WithState(state, new Dictionary<string, TypeSafeQuestion> { ["q"] = TypeSafeQuestion.Noul("Is it long?") });
            Assert.True(v.GetProperty("expectedOverflow").GetBoolean() == (TypeSafeBudget.Overflow(request) is not null), v.GetProperty("name").GetString());
        }
    }

    [Fact]
    public void StatusesMapOntoTheDocumentedErrors()
    {
        foreach (var v in Vectors.GetProperty("status").EnumerateArray())
        {
            var status = v.GetProperty("status").GetInt32();
            var body = v.TryGetProperty("body", out var b) ? b.GetString()! : "{}";
            var retryAfter = v.TryGetProperty("retryAfter", out var r) ? r.GetString() : null;
            var error = TypeSafeResponseMapper.Error(status, retryAfter, Encoding.UTF8.GetBytes(body));
            var expected = v.GetProperty("expected");
            if (expected.ValueKind == JsonValueKind.Null) { Assert.Null(error); continue; }
            Assert.NotNull(error);
            Assert.Equal(Kind(expected.GetProperty("kind").GetString()!), error.Kind);
            if (expected.TryGetProperty("message", out var m)) Assert.Equal(m.GetString(), error.Message);
            if (expected.TryGetProperty("status", out var s)) Assert.Equal(s.GetInt32(), error.Status);
            if (expected.TryGetProperty("retryAfter", out var ra))
                Assert.Equal(ra.ValueKind == JsonValueKind.Null ? null : TimeSpan.FromSeconds(ra.GetDouble()), error.RetryAfter);
        }
    }

    internal static TypeSafeErrorKind Kind(string vectorName) => vectorName switch
    {
        "unauthorized" => TypeSafeErrorKind.Unauthorized,
        "requestTooLarge" => TypeSafeErrorKind.RequestTooLarge,
        "invalidRequest" => TypeSafeErrorKind.InvalidRequest,
        "rateLimited" => TypeSafeErrorKind.RateLimited,
        "overloaded" => TypeSafeErrorKind.Overloaded,
        "server" => TypeSafeErrorKind.Server,
        "transport" => TypeSafeErrorKind.Transport,
        "malformedResponse" => TypeSafeErrorKind.MalformedResponse,
        "disabled" => TypeSafeErrorKind.Disabled,
        "missingApiKey" => TypeSafeErrorKind.MissingApiKey,
        _ => throw new ArgumentOutOfRangeException(nameof(vectorName), vectorName, null),
    };

    private static TypeSafeException Error(JsonElement spec) => new(
        Kind(spec.GetProperty("kind").GetString()!),
        status: spec.TryGetProperty("status", out var s) ? s.GetInt32() : 0,
        retryAfter: spec.TryGetProperty("retryAfter", out var r) && r.ValueKind == JsonValueKind.Number ? TimeSpan.FromSeconds(r.GetDouble()) : null);

    [Fact]
    public void TransientErrorsMatchVectors()
    {
        foreach (var v in Vectors.GetProperty("transient").EnumerateArray())
            Assert.True(v.GetProperty("expected").GetBoolean() == Error(v).IsTransient, v.GetRawText());
    }

    [Fact]
    public void BackoffHonoursRetryAfterAndOtherwiseGrows()
    {
        foreach (var v in Vectors.GetProperty("backoff").EnumerateArray())
        {
            var actual = TypeSafeClient.Backoff(v.GetProperty("attempt").GetInt32(), Error(v.GetProperty("after")));
            Assert.Equal(v.GetProperty("expectedSeconds").GetDouble(), actual.TotalSeconds, 6);
        }
    }

    [Fact]
    public async Task RetryBehaviourMatchesVectors()
    {
        foreach (var v in Vectors.GetProperty("retry").EnumerateArray())
        {
            var handler = new FakeHandler();
            foreach (var status in v.GetProperty("statuses").EnumerateArray())
            {
                if (status.ValueKind == JsonValueKind.String) handler.Enqueue(int.Parse(status.GetString()!.Split(':')[0]), status.GetString()!.Split(':')[1]);
                else if (status.GetInt32() == 200) handler.Enqueue(200, Samples.ExportResponse);
                else handler.Enqueue(status.GetInt32());
            }
            var name = v.GetProperty("name").GetString();
            var outcome = v.GetProperty("expectedOutcome").GetString()!;
            if (outcome == "success")
                Assert.NotNull(await handler.Client().EvaluateAsync(Samples.Sample(), "key"));
            else
            {
                var e = await Assert.ThrowsAsync<TypeSafeException>(() => handler.Client().EvaluateAsync(Samples.Sample(), "key"));
                Assert.True(Kind(outcome) == e.Kind, name);
            }
            Assert.True(v.GetProperty("expectedRequests").GetInt32() == handler.Requests.Count, name);
        }
    }

    [Fact]
    public async Task SendsBearerAuthorizationAndJsonBodyOverPost()
    {
        var handler = new FakeHandler().Enqueue(200, Samples.ExportResponse);
        await handler.Client().EvaluateAsync(Samples.Sample(), "secret-key");

        var request = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal(TypeSafeClient.DefaultEndpoint, request.RequestUri);
        Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
        Assert.Equal("secret-key", request.Headers.Authorization.Parameter);
        Assert.Equal("application/json", request.Content!.Headers.ContentType!.MediaType);
        Assert.True(request.Headers.CacheControl!.NoStore);
        Assert.Equal("a request", JsonNode.Parse(handler.Bodies[0])!["state"]!.GetValue<string>());
    }

    [Fact]
    public async Task TheKeyNeverAppearsInTheBodyOrInAnyError()
    {
        const string key = "sk-very-secret-value";
        var handler = new FakeHandler().Enqueue(401);
        var e = await Assert.ThrowsAsync<TypeSafeException>(() => handler.Client().EvaluateAsync(Samples.Sample(), key));
        Assert.DoesNotContain(key, handler.Bodies[0]);
        Assert.DoesNotContain(key, e.Message);
        Assert.DoesNotContain(key, e.ToString());

        var failing = new FakeHandler { Throw = new HttpRequestException($"proxy said no to {key}") };
        var transport = await Assert.ThrowsAsync<TypeSafeException>(() => failing.Client(maximumAttempts: 1).EvaluateAsync(Samples.Sample(), key));
        Assert.Equal(TypeSafeErrorKind.Transport, transport.Kind);
        Assert.DoesNotContain(key, transport.Message);
        Assert.DoesNotContain(key, transport.ToString());
        Assert.Null(transport.InnerException);
    }

    [Fact]
    public async Task RedirectsAreNotFollowedByTheDefaultClient()
    {
        using var sockets = TypeSafeClient.CreateDefaultHandler();
        // The default handler must not auto-redirect: a 3xx surfaces as a server error rather than replaying the key.
        Assert.False(sockets.AllowAutoRedirect);
        Assert.False(sockets.UseCookies);

        var handler = new FakeHandler().Enqueue(302, "{}", new() { ["Location"] = "https://evil.example/" });
        var e = await Assert.ThrowsAsync<TypeSafeException>(() => handler.Client(maximumAttempts: 1).EvaluateAsync(Samples.Sample(), "key"));
        Assert.Equal(TypeSafeErrorKind.Server, e.Kind);
        Assert.Single(handler.Requests);
    }

    [Fact]
    public void PlainHttpEndpointsAreRefused() =>
        Assert.Throws<ArgumentException>(() => new TypeSafeClient(endpoint: new Uri("http://api.typesafe.ai/v1/systemone")));

    [Fact]
    public async Task AnOversizedRequestNeverLeavesTheMachine()
    {
        var handler = new FakeHandler().Enqueue(200, Samples.ExportResponse);
        var request = TypeSafeRequest.WithState(string.Concat(Enumerable.Repeat("word ", 40_000)),
            new Dictionary<string, TypeSafeQuestion> { ["q"] = TypeSafeQuestion.Noul("Long?") });
        var e = await Assert.ThrowsAsync<TypeSafeException>(() => handler.Client(1).EvaluateAsync(request, "key"));
        Assert.Equal(TypeSafeErrorKind.RequestTooLarge, e.Kind);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task CancellationIsNotReportedAsAFailure()
    {
        var handler = new FakeHandler { Throw = new OperationCanceledException() };
        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => handler.Client().EvaluateAsync(Samples.Sample(), "key", cts.Token));
    }

    [Fact]
    public async Task ATimeoutIsATransportFailureAndIsRetried()
    {
        var handler = new SlowHandler();
        var client = new TypeSafeClient(new HttpClient(handler, false)) { Timeout = TimeSpan.FromMilliseconds(30), Sleep = (_, _) => Task.CompletedTask };
        var e = await Assert.ThrowsAsync<TypeSafeException>(() => client.EvaluateAsync(Samples.Sample(), "key"));
        Assert.Equal(TypeSafeErrorKind.Transport, e.Kind);
        Assert.Equal(3, handler.Calls);
    }

    private sealed class SlowHandler : HttpMessageHandler
    {
        public int Calls;

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref Calls);
            await Task.Delay(TimeSpan.FromSeconds(30), cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK);
        }
    }
}
