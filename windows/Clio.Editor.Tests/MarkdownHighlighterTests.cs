using System.Text.Json;
using Clio.Editor.Markdown;
using Xunit;

namespace Clio.Editor.Tests;

public class MarkdownHighlighterTests
{
    private static string Fixture(string name) =>
        File.ReadAllText(Path.Combine(Spec.Root, "ClioTests", "Fixtures", "Markdown", "Conformance", name + ".md"));

    private static List<string> Slices(string source, IReadOnlyList<MarkdownSpan> spans, SemanticKind kind, SpanRole role) =>
        [.. spans.Where(s => s.Kind == kind && s.Role == role).Select(s => source.Substring(s.Start, s.Length))];

    private static SemanticKind Kind(string name) => Enum.Parse<SemanticKind>(name, ignoreCase: true);
    private static SpanRole Role(string name) => Enum.Parse<SpanRole>(name, ignoreCase: true);

    [Fact]
    public void MatchesSharedVectors()
    {
        var root = JsonDocument.Parse(File.ReadAllText(Path.Combine(Spec.Root, "spec", "vectors", "markdown-highlight.json"))).RootElement;
        foreach (var v in root.GetProperty("vectors").EnumerateArray())
        {
            var name = v.GetProperty("name").GetString()!;
            var source = Fixture(v.GetProperty("fixture").GetString()!);
            var slices = Slices(source, MarkdownHighlighter.Highlight(source),
                Kind(v.GetProperty("kind").GetString()!), Role(v.GetProperty("role").GetString()!));

            if (v.TryGetProperty("include", out var include))
                foreach (var s in include.EnumerateArray())
                    Assert.True(slices.Contains(s.GetString()!), $"{name}: missing '{s}' in [{string.Join(" | ", slices)}]");
            if (v.TryGetProperty("exclude", out var exclude))
                foreach (var s in exclude.EnumerateArray())
                    Assert.False(slices.Contains(s.GetString()!), $"{name}: unexpected '{s}'");
            if (v.TryGetProperty("atLeast", out var atLeast))
                foreach (var p in atLeast.EnumerateObject())
                    Assert.True(slices.Count(x => x == p.Name) >= p.Value.GetInt32(), $"{name}: '{p.Name}' fewer than {p.Value} in [{string.Join(" | ", slices)}]");
            if (v.TryGetProperty("exactly", out var exactly))
                foreach (var p in exactly.EnumerateObject())
                    Assert.True(slices.Count(x => x == p.Name) == p.Value.GetInt32(), $"{name}: '{p.Name}' not exactly {p.Value} in [{string.Join(" | ", slices)}]");
        }
    }

    [Theory]
    [InlineData("blocks")]
    [InlineData("delimiters")]
    [InlineData("gfm-extensions")]
    [InlineData("links-code-entities")]
    [InlineData("malformed-unicode")]
    public void SpansStayInsideTheSource(string fixture)
    {
        var source = Fixture(fixture);
        foreach (var mode in new[] { HighlightMode.Full, HighlightMode.Reduced })
            foreach (var s in MarkdownHighlighter.Highlight(source, mode))
            {
                Assert.True(s.Start >= 0 && s.Length > 0 && s.End <= source.Length, $"{fixture} {mode}: {s}");
                // Every span must start and end on a scalar boundary of the original text.
                Assert.False(s.Start > 0 && char.IsLowSurrogate(source[s.Start]), $"{fixture}: span starts inside a surrogate pair");
            }
    }

    [Fact]
    public void LfAndCrlfProduceTheSameSlices()
    {
        foreach (var name in new[] { "blocks", "delimiters", "gfm-extensions", "links-code-entities", "malformed-unicode" })
        {
            var crlf = Fixture(name);
            var lf = crlf.Replace("\r\n", "\n");
            var a = MarkdownHighlighter.Highlight(crlf).Select(s => (s.Kind, s.Role, crlf.Substring(s.Start, s.Length).Replace("\r\n", "\n"))).OrderBy(x => x.ToString()).ToList();
            var b = MarkdownHighlighter.Highlight(lf).Select(s => (s.Kind, s.Role, lf.Substring(s.Start, s.Length))).OrderBy(x => x.ToString()).ToList();
            Assert.Equal(b, a);
        }
    }

    [Fact]
    public void HeadingMarkersAndLevels()
    {
        const string src = "# One\n\n## Two ##\n\nThree\n=====\n";
        var spans = MarkdownHighlighter.Highlight(src);
        Assert.Equal([1, 2, 1], spans.Where(s => s is { Kind: SemanticKind.Heading, Role: SpanRole.Content }).OrderBy(s => s.Start).Select(s => s.Level!.Value));
        Assert.Contains("##", Slices(src, spans, SemanticKind.Heading, SpanRole.Marker));
        Assert.Contains("=====", Slices(src, spans, SemanticKind.Heading, SpanRole.Marker));
    }

    [Fact]
    public void FencesTokenizeCodeAndKeepInfoString()
    {
        const string src = "```swift\nlet x = 42 // note\n```\n";
        var spans = MarkdownHighlighter.Highlight(src);
        Assert.Equal(["swift"], Slices(src, spans, SemanticKind.CodeFence, SpanRole.InfoString));
        Assert.Equal(["```", "```"], Slices(src, spans, SemanticKind.CodeFence, SpanRole.Marker));
        var tokens = spans.Where(s => s.Role == SpanRole.CodeToken).ToDictionary(s => src.Substring(s.Start, s.Length), s => s.Token);
        Assert.Equal(CodeTokenKind.Keyword, tokens["let"]);
        Assert.Equal(CodeTokenKind.Number, tokens["42"]);
        Assert.Equal(CodeTokenKind.Comment, tokens["// note"]);
    }

    [Fact]
    public void UnclosedFenceRunsToTheEndOfTheDocument()
    {
        const string src = "```\ncode\nmore";
        var spans = MarkdownHighlighter.Highlight(src);
        Assert.Equal(["code\nmore"], Slices(src, spans, SemanticKind.CodeFence, SpanRole.Content));
    }

    [Fact]
    public void TripleDelimitersNestEmphasisAroundStrong()
    {
        const string src = "***both***";
        var spans = MarkdownHighlighter.Highlight(src);
        Assert.Equal(["*", "*"], Slices(src, spans, SemanticKind.Emphasis, SpanRole.Marker));
        Assert.Equal(["**", "**"], Slices(src, spans, SemanticKind.Strong, SpanRole.Marker));
        Assert.Equal(["both"], Slices(src, spans, SemanticKind.Strong, SpanRole.Content));
    }

    [Fact]
    public void ReducedModeSkipsInlineAndCodeTokens()
    {
        const string src = "# Title\n\n**bold** and `code`\n\n```swift\nlet x = 1\n```\n";
        var spans = MarkdownHighlighter.Highlight(src, HighlightMode.Reduced);
        Assert.Contains(spans, s => s.Kind == SemanticKind.Heading);
        Assert.DoesNotContain(spans, s => s.Kind is SemanticKind.Strong or SemanticKind.InlineCode);
        Assert.DoesNotContain(spans, s => s.Role == SpanRole.CodeToken);
    }

    [Fact]
    public void UnsupportedModeAndEmptySourceYieldNothing()
    {
        Assert.Empty(MarkdownHighlighter.Highlight("# x", HighlightMode.Unsupported));
        Assert.Empty(MarkdownHighlighter.Highlight(""));
    }

    [Theory]
    [InlineData(0, HighlightMode.Full)]
    [InlineData(10L * 1024 * 1024, HighlightMode.Full)]
    [InlineData(10L * 1024 * 1024 + 1, HighlightMode.Reduced)]
    [InlineData(50L * 1024 * 1024, HighlightMode.Reduced)]
    [InlineData(50L * 1024 * 1024 + 1, HighlightMode.Unsupported)]
    public void SizeModeBoundaries(long bytes, HighlightMode expected) =>
        Assert.Equal(expected, MarkdownHighlighter.ModeFor(bytes));
}
