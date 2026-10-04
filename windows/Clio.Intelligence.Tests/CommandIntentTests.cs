using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Clio.Editor.Commands;
using Xunit;

namespace Clio.Intelligence.Tests;

public class CommandIntentTests
{
    private static readonly JsonElement Vectors = Spec.Load("intelligence-command-intent.json");

    private static string[] Strings(string property) => [.. Vectors.GetProperty(property).EnumerateArray().Select(e => e.GetString()!)];

    [Fact]
    public void ThresholdsMatchTheVector()
    {
        var t = Vectors.GetProperty("thresholds");
        Check.Same(t.GetProperty("minimumConfidence").GetDouble(), CommandIntentResolver.MinimumConfidence);
        Check.Same(t.GetProperty("minimumCommandProbability").GetDouble(), CommandIntentResolver.MinimumCommandProbability);
        Check.Same(t.GetProperty("minimumAlternativeProbability").GetDouble(), CommandIntentResolver.MinimumAlternativeProbability);
        Check.Same(t.GetProperty("maximumAlternatives").GetInt32(), CommandIntentResolver.MaximumAlternatives);
        Check.Same(t.GetProperty("minimumRequestCharacters").GetInt32(), CommandIntentResolver.MinimumRequestCharacters);
        Check.Same(Vectors.GetProperty("noMatch").GetString(), CommandIntentSpec.NoMatch);
    }

    [Fact]
    public void EveryPaletteCommandIsDescribedExactlyOnce()
    {
        var described = CommandIntentSpec.CommandCriteria.Keys.Where(k => k != CommandIntentSpec.NoMatch).ToHashSet();
        var palette = CommandDescriptor.All.Select(d => d.Command.RawValue()).ToHashSet();
        Assert.Equal(palette, described);
        Assert.Equal(Strings("commandIds").ToHashSet(), described);
        Assert.True(CommandIntentSpec.CommandCriteria.ContainsKey(CommandIntentSpec.NoMatch),
            "Without a no-match option the model must name a command for any input");
    }

    [Fact]
    public void ExportFormatsMatchTheParsersAcceptedFormats()
    {
        Assert.Equal(Strings("exportFormats").ToHashSet(), CommandIntentSpec.ExportFormatCriteria.Keys.ToHashSet());
        Assert.Equal(Strings("exportFormats"), CommandIntentSpec.ExportFormats);
        foreach (var format in CommandIntentSpec.ExportFormats)
        {
            var invocation = CommandParser.Parse($"/export {format}");
            Assert.Equal(CommandId.Export, invocation.Command);
            Assert.Equal([format], invocation.Arguments);
        }
    }

    [Fact]
    public void OnlyWindowStateTravelsNeverTheDocument()
    {
        var c = Vectors.GetProperty("context");
        var input = c.GetProperty("input");
        var context = new CommandIntentContext(
            input.GetProperty("hasOpenDocument").GetBoolean(), input.GetProperty("documentExistsOnDisk").GetBoolean(),
            input.GetProperty("isFocusModeEnabled").GetBoolean(), input.GetProperty("isTypewriterEnabled").GetBoolean(),
            input.GetProperty("isSidebarVisible").GetBoolean());
        var request = CommandIntentResolver.Request(c.GetProperty("request").GetString()!, context);

        var json = request.ToJson();
        Assert.True(JsonNode.DeepEquals(Spec.Node(c.GetProperty("expectedState")), json["state"]));
        Assert.Equal(5, json["state"]!["editor"]!.AsObject().Count);
        Assert.Equal(CommandIntentResolver.Questions().Keys.Order(), c.GetProperty("expectedQuestionTypes").EnumerateObject().Select(p => p.Name).Order());
        foreach (var p in c.GetProperty("expectedQuestionTypes").EnumerateObject())
            Assert.Equal(p.Value.GetString(), request.Questions[p.Name].TypeName);
        Assert.Equal(CommandIntentSpec.CommandCriteria.Count, ((ChoiceQuestion)request.Questions["command"]).Criteria.Count);
        Assert.Equal(CommandDescriptor.All.Count + 1, ((ChoiceQuestion)request.Questions["command"]).Criteria.Count);
        Assert.Equal(TypeSafeRequest.DefaultModel, json["model"]!.GetValue<string>());
        Assert.Null(TypeSafeBudget.Overflow(request));
    }

    [Fact]
    public void ResolutionMatchesVectors()
    {
        foreach (var v in Vectors.GetProperty("resolve").EnumerateArray())
        {
            var name = v.GetProperty("name").GetString();
            var response = TypeSafeResponse.Parse(Encoding.UTF8.GetBytes(v.GetProperty("response").GetRawText()));
            var result = CommandIntentResolver.Resolve(response);
            var expected = v.GetProperty("expected");
            if (expected.ValueKind == JsonValueKind.Null) { Assert.True(result is null, name); continue; }

            Assert.True(result is not null, name);
            Assert.True(expected.GetProperty("command").GetString() == result.Invocation.Command.RawValue(), name);
            Assert.True(expected.GetProperty("arguments").EnumerateArray().Select(a => a.GetString()).SequenceEqual(result.Invocation.Arguments), $"{name}: arguments");
            Assert.True(Math.Abs(expected.GetProperty("confidence").GetDouble() - result.Confidence) < 1e-9, $"{name}: confidence {result.Confidence}");
            Assert.True(Math.Abs(expected.GetProperty("commandProbability").GetDouble() - result.CommandProbability) < 1e-9, $"{name}: probability");
            Assert.True(expected.GetProperty("ranked").EnumerateArray().Select(a => a.GetString()).SequenceEqual(result.Ranked.Select(r => r.RawValue())),
                $"{name}: ranked {string.Join(",", result.Ranked.Select(r => r.RawValue()))}");
        }
    }

    [Fact]
    public void ResolvedInvocationsSurviveTheRealParser()
    {
        var response = TypeSafeResponse.Parse(Encoding.UTF8.GetBytes(Samples.ExportResponse));
        var result = CommandIntentResolver.Resolve(response)!;
        var parsed = CommandParser.Parse($"{result.Invocation.Command.SlashName()} {string.Join(' ', result.Invocation.Arguments)}");
        Assert.Equal(result.Invocation, parsed);
    }
}
