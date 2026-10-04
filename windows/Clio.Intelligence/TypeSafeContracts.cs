using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Clio.Intelligence;

/// <summary>
/// Wire contracts for TypeSafe's System One endpoint (macOS <c>IntelligenceContracts.swift</c>). Clio sends a
/// <c>state</c> and a map of typed questions and gets one typed answer per question back. Nothing here performs I/O,
/// so the intent and structure passes are tested against recorded payloads without a network.
/// </summary>
public static class StableJson
{
    /// <summary>Compact UTF-8 JSON with object keys sorted ordinally, so identical requests are byte-identical.</summary>
    public static byte[] Serialize(JsonNode node)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream)) Write(writer, node);
        return stream.ToArray();
    }

    private static void Write(Utf8JsonWriter writer, JsonNode? node)
    {
        switch (node)
        {
            case null: writer.WriteNullValue(); break;
            case JsonObject obj:
                writer.WriteStartObject();
                foreach (var pair in obj.OrderBy(p => p.Key, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(pair.Key);
                    Write(writer, pair.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonArray array:
                writer.WriteStartArray();
                foreach (var item in array) Write(writer, item);
                writer.WriteEndArray();
                break;
            default: node.WriteTo(writer); break;
        }
    }

    /// <summary>
    /// Character count of the encoded text, used for budgeting a request against the model's context window before
    /// it is sent (macOS <c>JSONValue.characterCount</c>).
    /// </summary>
    public static int CharacterCount(JsonNode? node) => node switch
    {
        null => 8,
        JsonObject obj => obj.Aggregate(2, (total, p) => total + p.Key.Length + CharacterCount(p.Value) + 4),
        JsonArray array => array.Aggregate(2, (total, item) => total + CharacterCount(item) + 1),
        JsonValue value when value.TryGetValue<string>(out var text) => text.Length,
        _ => 8,
    };
}

/// <summary>Clarifies what yes and no mean for a Noul question.</summary>
public sealed record NoulCriteria(string True, string False);

/// <summary>
/// One typed judgment. Noul returns a probability, Choice selects one of a defined set, and Score places the state
/// along ordered levels.
/// </summary>
public abstract record TypeSafeQuestion(JsonNode Instructions)
{
    public abstract string TypeName { get; }

    internal abstract JsonNode? CriteriaNode { get; }

    public abstract int CharacterCount { get; }

    public JsonObject ToJson()
    {
        var obj = new JsonObject { ["type"] = TypeName, ["instructions"] = Instructions.DeepClone() };
        if (CriteriaNode is { } criteria) obj["criteria"] = criteria;
        return obj;
    }

    public static TypeSafeQuestion Noul(string instructions, NoulCriteria? criteria = null) => new NoulQuestion(JsonValue.Create(instructions)!, criteria);

    public static TypeSafeQuestion Choice(string instructions, IReadOnlyDictionary<string, string> criteria) => new ChoiceQuestion(JsonValue.Create(instructions)!, criteria);

    public static TypeSafeQuestion Score(string instructions, IReadOnlyList<string> criteria) => new ScoreQuestion(JsonValue.Create(instructions)!, criteria);
}

public sealed record NoulQuestion(JsonNode Text, NoulCriteria? Criteria) : TypeSafeQuestion(Text)
{
    public override string TypeName => "noul";

    internal override JsonNode? CriteriaNode => Criteria is null ? null : new JsonObject { ["true"] = Criteria.True, ["false"] = Criteria.False };

    public override int CharacterCount => StableJson.CharacterCount(Instructions) + TypeName.Length + (Criteria?.True.Length ?? 0) + (Criteria?.False.Length ?? 0);
}

public sealed record ChoiceQuestion(JsonNode Text, IReadOnlyDictionary<string, string> Criteria) : TypeSafeQuestion(Text)
{
    public override string TypeName => "choice";

    internal override JsonNode? CriteriaNode
    {
        get
        {
            var obj = new JsonObject();
            foreach (var pair in Criteria) obj[pair.Key] = pair.Value;
            return obj;
        }
    }

    public override int CharacterCount => StableJson.CharacterCount(Instructions) + TypeName.Length + Criteria.Sum(p => p.Key.Length + p.Value.Length + 4);
}

public sealed record ScoreQuestion(JsonNode Text, IReadOnlyList<string> Criteria) : TypeSafeQuestion(Text)
{
    public override string TypeName => "score";

    internal override JsonNode? CriteriaNode => new JsonArray([.. Criteria.Select(c => (JsonNode?)JsonValue.Create(c))]);

    public override int CharacterCount => StableJson.CharacterCount(Instructions) + TypeName.Length + Criteria.Sum(c => c.Length + 3);
}

public sealed record TypeSafeRequest(JsonNode State, IReadOnlyDictionary<string, TypeSafeQuestion> Questions, string Model = TypeSafeRequest.DefaultModel)
{
    /// <summary>
    /// The pinned model. An alias moves when TypeSafe ships a release, which would shift answers under tuned thresholds,
    /// so Clio names a version and moves on its own schedule.
    /// </summary>
    public const string DefaultModel = "jev-1.13.0";

    public static TypeSafeRequest WithState(string state, IReadOnlyDictionary<string, TypeSafeQuestion> questions) =>
        new(JsonValue.Create(state)!, questions);

    public JsonObject ToJson()
    {
        var questions = new JsonObject();
        foreach (var pair in Questions) questions[pair.Key] = pair.Value.ToJson();
        return new JsonObject { ["state"] = State.DeepClone(), ["model"] = Model, ["questions"] = questions };
    }

    public byte[] ToBytes() => StableJson.Serialize(ToJson());
}

/// <summary>
/// The published context window for <c>jev-1.13.0</c>: 64k tokens for the state plus every question, and 32k for the
/// state plus the single longest question. Clio budgets in characters with a deliberately pessimistic ratio so the
/// guard trips before the API does.
/// </summary>
public static class TypeSafeBudget
{
    public const double CharactersPerToken = 3.0;
    public const int CombinedTokenLimit = 64_000;
    public const int StateTokenLimit = 32_000;

    public static int CombinedCharacterLimit => (int)(CombinedTokenLimit * CharactersPerToken);
    public static int StateCharacterLimit => (int)(StateTokenLimit * CharactersPerToken);

    /// <summary>Null when the request fits, or the reason it does not.</summary>
    public static string? Overflow(TypeSafeRequest request)
    {
        var state = StableJson.CharacterCount(request.State);
        var questions = request.Questions.Values.ToList();
        var combined = state + questions.Sum(q => q.CharacterCount);
        if (combined > CombinedCharacterLimit) return "This request is too large for one evaluation.";
        var longest = questions.Count == 0 ? 0 : questions.Max(q => q.CharacterCount);
        if (state + longest > StateCharacterLimit) return "This document is too long to evaluate in one request.";
        return null;
    }
}

// ---- answers --------------------------------------------------------------------------------------

public sealed record TypeSafeChoiceAnswer(string Choice, IReadOnlyDictionary<string, double> Probabilities, double Confidence)
{
    /// <summary>The probability of the option that was actually selected.</summary>
    public double Probability => Probabilities.TryGetValue(Choice, out var p) ? p : 0;
}

public sealed record TypeSafeScoreAnswer(double Score, IReadOnlyDictionary<string, string> Legend, IReadOnlyDictionary<string, double> Probabilities, double Confidence);

public abstract record TypeSafeAnswer
{
    public double? NoulValue => (this as NoulAnswer)?.Value;
    public TypeSafeChoiceAnswer? ChoiceValue => (this as ChoiceAnswer)?.Answer;
    public TypeSafeScoreAnswer? ScoreValue => (this as ScoreAnswer)?.Answer;
}

public sealed record NoulAnswer(double Value) : TypeSafeAnswer;
public sealed record ChoiceAnswer(TypeSafeChoiceAnswer Answer) : TypeSafeAnswer;
public sealed record ScoreAnswer(TypeSafeScoreAnswer Answer) : TypeSafeAnswer;

public sealed record TypeSafeUsage(int InputTokens, int OutputTokens);

public sealed record TypeSafeResponse(string Model, IReadOnlyDictionary<string, TypeSafeAnswer> Answers, TypeSafeUsage Usage)
{
    public TypeSafeAnswer? this[string id] => Answers.GetValueOrDefault(id);

    /// <exception cref="TypeSafeException">The body is not a response Clio can read.</exception>
    public static TypeSafeResponse Parse(ReadOnlySpan<byte> body)
    {
        try
        {
            using var document = JsonDocument.Parse(body.ToArray());
            var root = document.RootElement;
            var answers = new Dictionary<string, TypeSafeAnswer>();
            foreach (var pair in root.GetProperty("answers").EnumerateObject())
                answers[pair.Name] = ParseAnswer(pair.Value);
            var usage = root.GetProperty("usage");
            return new TypeSafeResponse(
                root.GetProperty("model").GetString() ?? throw new FormatException(),
                answers,
                new TypeSafeUsage(usage.GetProperty("input_tokens").GetInt32(), usage.GetProperty("output_tokens").GetInt32()));
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        {
            throw new TypeSafeException(TypeSafeErrorKind.MalformedResponse);
        }
    }

    private static TypeSafeAnswer ParseAnswer(JsonElement element)
    {
        switch (element.GetProperty("type").GetString())
        {
            case "noul":
                return new NoulAnswer(element.GetProperty("noul").GetDouble());
            case "choice":
                return new ChoiceAnswer(new TypeSafeChoiceAnswer(
                    element.GetProperty("choice").GetString() ?? throw new FormatException(),
                    Doubles(element.GetProperty("probabilities")),
                    element.GetProperty("confidence").GetDouble()));
            case "score":
                return new ScoreAnswer(new TypeSafeScoreAnswer(
                    element.GetProperty("score").GetDouble(),
                    element.GetProperty("legend").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString() ?? throw new FormatException()),
                    Doubles(element.GetProperty("probabilities")),
                    element.GetProperty("confidence").GetDouble()));
            default:
                throw new FormatException("Unknown answer type");
        }
    }

    private static Dictionary<string, double> Doubles(JsonElement element) =>
        element.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetDouble());
}

// ---- errors ---------------------------------------------------------------------------------------

public enum TypeSafeErrorKind
{
    /// <summary>The feature is switched off in Settings. Clio never reaches the network in this state.</summary>
    Disabled,
    MissingApiKey,
    Unauthorized,
    RequestTooLarge,
    InvalidRequest,
    RateLimited,
    Overloaded,
    Server,
    Transport,
    MalformedResponse,
}

/// <summary>
/// A failure talking to TypeSafe. The message never contains the API key, request text or response body beyond the
/// service's own validation detail on a 422.
/// </summary>
public sealed class TypeSafeException(TypeSafeErrorKind kind, string? reason = null, int status = 0, TimeSpan? retryAfter = null)
    : Exception(Describe(kind, reason, status))
{
    public TypeSafeErrorKind Kind { get; } = kind;
    public int Status { get; } = status;
    public TimeSpan? RetryAfter { get; } = retryAfter;

    /// <summary>The service's own wording for <see cref="TypeSafeErrorKind.RequestTooLarge"/> and <see cref="TypeSafeErrorKind.InvalidRequest"/>.</summary>
    public string? Reason { get; } = reason;

    /// <summary>Whether a retry with backoff is worth attempting.</summary>
    public bool IsTransient => Kind switch
    {
        TypeSafeErrorKind.RateLimited or TypeSafeErrorKind.Overloaded or TypeSafeErrorKind.Transport => true,
        TypeSafeErrorKind.Server => Status >= 500,
        _ => false,
    };

    private static string Describe(TypeSafeErrorKind kind, string? reason, int status) => kind switch
    {
        TypeSafeErrorKind.Disabled => "Assisted commands are off. Turn them on in Settings.",
        TypeSafeErrorKind.MissingApiKey => "Add a TypeSafe API key in Settings to use assisted commands.",
        TypeSafeErrorKind.Unauthorized => "The TypeSafe API key was rejected. Check it in Settings.",
        TypeSafeErrorKind.RequestTooLarge or TypeSafeErrorKind.InvalidRequest => reason ?? "TypeSafe could not take this request.",
        TypeSafeErrorKind.RateLimited => "TypeSafe is rate limiting this key. Try again shortly.",
        TypeSafeErrorKind.Overloaded => "TypeSafe is busy. Try again shortly.",
        TypeSafeErrorKind.Server => $"TypeSafe returned an unexpected response ({status}).",
        TypeSafeErrorKind.Transport => "Clio could not reach TypeSafe. Check your connection.",
        _ => "TypeSafe returned a response Clio could not read.",
    };
}

/// <summary>Maps an HTTP response onto a <see cref="TypeSafeException"/>. Split from the transport so status handling is tested without a server.</summary>
public static class TypeSafeResponseMapper
{
    public static TypeSafeException? Error(int status, string? retryAfter, ReadOnlySpan<byte> body)
    {
        switch (status)
        {
            case >= 200 and < 300: return null;
            case 401 or 403: return new TypeSafeException(TypeSafeErrorKind.Unauthorized);
            case 413: return new TypeSafeException(TypeSafeErrorKind.RequestTooLarge, "This request is too large for one evaluation.");
            case 422: return new TypeSafeException(TypeSafeErrorKind.InvalidRequest, Detail(body) ?? "TypeSafe rejected the request as malformed.");
            case 429:
                TimeSpan? wait = double.TryParse(retryAfter, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) && double.IsFinite(seconds)
                    ? TimeSpan.FromSeconds(seconds)
                    : null;
                return new TypeSafeException(TypeSafeErrorKind.RateLimited, retryAfter: wait);
            case 529: return new TypeSafeException(TypeSafeErrorKind.Overloaded);
            default: return new TypeSafeException(TypeSafeErrorKind.Server, status: status);
        }
    }

    /// <summary>TypeSafe describes a 422 in the body. Surface that text rather than a bare status, because it names the offending field.</summary>
    private static string? Detail(ReadOnlySpan<byte> body)
    {
        try
        {
            using var document = JsonDocument.Parse(body.ToArray());
            if (document.RootElement.ValueKind != JsonValueKind.Object) return null;
            foreach (var key in new[] { "detail", "message", "error" })
                if (document.RootElement.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text)
                    return text;
        }
        catch (JsonException) { }
        return null;
    }
}
