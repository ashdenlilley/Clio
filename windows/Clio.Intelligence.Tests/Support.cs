using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Clio.Intelligence.Tests;

/// <summary>Locates the shared cross-platform spec (repo-root /spec).</summary>
internal static class Spec
{
    public static string Root { get; } = FindRoot();

    private static string FindRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            if (Directory.Exists(Path.Combine(dir.FullName, "spec", "vectors"))) return dir.FullName;
        throw new DirectoryNotFoundException("spec/vectors not found above " + AppContext.BaseDirectory);
    }

    public static JsonElement Load(string name) =>
        JsonDocument.Parse(File.ReadAllText(Path.Combine(Root, "spec", "vectors", name))).RootElement;

    public static JsonNode Node(JsonElement element) => JsonNode.Parse(element.GetRawText())!;
}

internal static class Check
{
    /// <summary>The shared vector value must equal the implementation's constant.</summary>
    public static void Same<T>(T vector, T implementation) =>
        Xunit.Assert.True(EqualityComparer<T>.Default.Equals(vector, implementation), $"vector {vector} but implementation {implementation}");
}

/// <summary>Serves canned responses to the TypeSafe client and records what was sent, so transport behaviour is exercised without a network.</summary>
internal sealed class FakeHandler : HttpMessageHandler
{
    public sealed record Reply(int Status, string Body = "{}", Dictionary<string, string>? Headers = null);

    private readonly Queue<Reply> _replies = new();

    public List<HttpRequestMessage> Requests { get; } = [];
    public List<string> Bodies { get; } = [];
    public Exception? Throw { get; set; }

    public FakeHandler Enqueue(int status = 200, string body = "{}", Dictionary<string, string>? headers = null)
    {
        _replies.Enqueue(new Reply(status, body, headers));
        return this;
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Requests.Add(request);
        Bodies.Add(request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken));
        if (Throw is not null) throw Throw;
        var reply = _replies.Count == 0 ? new Reply(500) : _replies.Dequeue();
        var response = new HttpResponseMessage((HttpStatusCode)reply.Status) { Content = new StringContent(reply.Body, Encoding.UTF8, "application/json") };
        foreach (var header in reply.Headers ?? []) response.Headers.TryAddWithoutValidation(header.Key, header.Value);
        return response;
    }

    public TypeSafeClient Client(int maximumAttempts = 3) =>
        new(new HttpClient(this, disposeHandler: false)) { Sleep = (_, _) => Task.CompletedTask, MaximumAttempts = maximumAttempts };
}

internal static class Samples
{
    /// <summary>The answer shape the assisted command request gets back for "send this to my editor in Word".</summary>
    public const string ExportResponse = """
        {
          "model": "jev-1.13.0",
          "answers": {
            "command": { "type": "choice", "choice": "export", "probabilities": { "export": 0.88, "new": 0.08, "__none__": 0.04 }, "confidence": 0.81 },
            "export_format": { "type": "choice", "choice": "docx", "probabilities": { "docx": 0.91, "pdf": 0.06, "html": 0.02, "txt": 0.01 }, "confidence": 0.89 },
            "export_format_stated": { "type": "noul", "noul": 0.94 }
          },
          "usage": { "input_tokens": 318, "output_tokens": 34 }
        }
        """;

    public static readonly Clio.Intelligence.CommandIntentContext Context = new(true, true, false, false, true);

    public static TypeSafeRequest Sample() => TypeSafeRequest.WithState("a request", new Dictionary<string, TypeSafeQuestion>
    {
        ["command"] = TypeSafeQuestion.Choice("What?", new Dictionary<string, string> { ["export"] = "out", ["__none__"] = "nothing" }),
    });
}
