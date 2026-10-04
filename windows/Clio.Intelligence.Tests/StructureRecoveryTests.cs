using System.Text;
using System.Text.Json;
using Xunit;

namespace Clio.Intelligence.Tests;

public class StructureRecoveryTests
{
    private static readonly JsonElement Vectors = Spec.Load("intelligence-structure-recovery.json");
    private static readonly string Memo = Vectors.GetProperty("memo").GetString()!;

    /// <summary>A vector's text is the memo, the markdown paste, a literal, or lines of a given length.</summary>
    private static string TextOf(JsonElement v)
    {
        if (v.TryGetProperty("text", out var named))
            return named.GetString() switch { "memo" => Memo, "markdownPaste" => Vectors.GetProperty("markdownPaste").GetString()!, var other => other! };
        if (v.TryGetProperty("literal", out var literal)) return literal.GetString()!;
        return string.Join("\n", v.GetProperty("lineLengths").EnumerateArray().Select((n, i) => new string((char)('a' + i), n.GetInt32())));
    }

    private static List<StructureRecovery.Line> LinesOf(JsonElement array) =>
        [.. array.EnumerateArray().Select(l => new StructureRecovery.Line(l.GetProperty("text").GetString()!, l.GetProperty("gap").GetBoolean()))];

    [Fact]
    public void ThresholdsMatchTheVector()
    {
        var t = Vectors.GetProperty("thresholds");
        Check.Same(t.GetProperty("minimumCharacters").GetInt32(), StructureRecovery.MinimumCharacters);
        Check.Same(t.GetProperty("maximumCharacters").GetInt32(), StructureRecovery.MaximumCharacters);
        Check.Same(t.GetProperty("headingMaxCharacters").GetInt32(), StructureRecovery.HeadingMaxCharacters);
        Check.Same(t.GetProperty("joinAfterDangling").GetDouble(), StructureRecovery.JoinAfterDangling);
        Check.Same(t.GetProperty("joinAfterTerminal").GetDouble(), StructureRecovery.JoinAfterTerminal);
        Check.Same(t.GetProperty("stepThreshold").GetDouble(), StructureRecovery.StepThreshold);
    }

    [Fact]
    public void SendGateMatchesVectors()
    {
        foreach (var v in Vectors.GetProperty("shouldAttempt").EnumerateArray())
            Assert.True(v.GetProperty("expected").GetBoolean() == StructureRecovery.ShouldAttempt(TextOf(v)), v.GetProperty("name").GetString());
    }

    [Fact]
    public void MarkerRuleMatchesVectors()
    {
        foreach (var v in Vectors.GetProperty("carriesMarkers").EnumerateArray())
        {
            var lines = v.GetProperty("lines").EnumerateArray().Select(l => l.GetString()!).ToList();
            Assert.True(v.GetProperty("expected").GetBoolean() == StructureRecovery.CarriesMarkdownMarkers(lines), v.GetRawText());
        }
    }

    [Fact]
    public void LinesMatchVectors()
    {
        foreach (var v in Vectors.GetProperty("lines").EnumerateArray())
            Assert.True(LinesOf(v.GetProperty("expected")).SequenceEqual(StructureRecovery.Lines(TextOf(v))), v.GetProperty("name").GetString());
    }

    [Fact]
    public void CrLfCountsAsOneBreakAndOtherUnicodeBreaksSplit()
    {
        var lines = StructureRecovery.Lines("one\r\ntwo\rthree\u2028four\u0085five");
        Assert.Equal(["one", "two", "three", "four", "five"], lines.Select(l => l.Text));
        Assert.All(lines, l => Assert.False(l.PrecededByGap));
    }

    [Fact]
    public void StitchAsksOnlyAboutPairsThatABlankLineDidNotAlreadySeparate()
    {
        var v = Vectors.GetProperty("stitch");
        var lines = StructureRecovery.Lines(TextOf(v));
        var request = StructureRecovery.StitchRequest(lines);
        Assert.Equal(v.GetProperty("expectedQuestionIds").EnumerateArray().Select(e => e.GetString()!).Order(), request.Questions.Keys.Order());
        foreach (var q in v.GetProperty("expectedQuestionText").EnumerateObject())
            Assert.Equal(q.Value.GetString(), request.Questions[q.Name].Instructions.GetValue<string>());
        Assert.All(request.Questions.Values, q => Assert.Equal("noul", q.TypeName));
        Assert.Equal(v.GetProperty("expectedState").GetString(), request.State.GetValue<string>());

        var j = v.GetProperty("joinsFromResponse");
        var body = new StringBuilder("{\"model\":\"m\",\"answers\":{");
        body.Append(string.Join(",", j.GetProperty("answers").EnumerateObject().Select(p => $"\"{p.Name}\":{{\"type\":\"noul\",\"noul\":{p.Value.GetDouble():R}}}")));
        body.Append("},\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}");
        var joins = StructureRecovery.Joins(TypeSafeResponse.Parse(Encoding.UTF8.GetBytes(body.ToString())), j.GetProperty("lineCount").GetInt32());
        Assert.Equal(j.GetProperty("expected").EnumerateArray().Select(e => e.GetDouble()), joins);
    }

    [Fact]
    public void TerminalPunctuationMatchesVectors()
    {
        foreach (var v in Vectors.GetProperty("endsTerminally").EnumerateArray())
            Assert.True(v.GetProperty("expected").GetBoolean() == StructureRecovery.EndsTerminally(v.GetProperty("text").GetString()!), v.GetProperty("text").GetString());
    }

    private static List<StructureRecovery.Block> Blocks(JsonElement array) =>
        [.. array.EnumerateArray().Select(b => new StructureRecovery.Block(b.GetProperty("text").GetString()!, [.. b.GetProperty("lineIndices").EnumerateArray().Select(i => i.GetInt32())], b.GetProperty("gap").GetBoolean()))];

    [Fact]
    public void MergeMatchesVectors()
    {
        foreach (var v in Vectors.GetProperty("merge").EnumerateArray())
        {
            var lines = v.TryGetProperty("lines", out var l) ? LinesOf(l) : StructureRecovery.Lines(TextOf(v));
            var joins = v.GetProperty("joins").EnumerateArray().Select(j => j.GetDouble()).ToList();
            var actual = StructureRecovery.Merge(lines, joins);
            var expected = Blocks(v.GetProperty("expected"));
            var name = v.GetProperty("name").GetString();
            Assert.True(expected.Count == actual.Count, $"{name}: {actual.Count} blocks");
            for (var i = 0; i < expected.Count; i++)
            {
                Assert.True(expected[i].Text == actual[i].Text, $"{name}: text {i}");
                Assert.True(expected[i].LineIndices.SequenceEqual(actual[i].LineIndices), $"{name}: indices {i}");
                Assert.True(expected[i].PrecededByGap == actual[i].PrecededByGap, $"{name}: gap {i}");
            }
        }
    }

    [Fact]
    public void ClassifySkipsTheHeadingQuestionForBlocksTooLongToBeOne()
    {
        var v = Vectors.GetProperty("classify");
        var blocks = v.GetProperty("blocks").EnumerateArray().Select(b =>
        {
            var text = b.TryGetProperty("text", out var t) ? t.GetString()!
                : b.TryGetProperty("textRepeat", out var r) ? string.Concat(Enumerable.Repeat(r.GetProperty("unit").GetString()!, r.GetProperty("count").GetInt32()))
                : new string('a', b.GetProperty("textLength").GetInt32());
            return new StructureRecovery.Block(text, [0], b.GetProperty("gap").GetBoolean());
        }).ToList();

        var request = StructureRecovery.ClassifyRequest(blocks);
        Assert.Equal(v.GetProperty("expectedQuestionIds").EnumerateArray().Select(e => e.GetString()!).Order(), request.Questions.Keys.Order());
        foreach (var p in v.GetProperty("questionTypes").EnumerateObject())
            Assert.Equal(p.Value.GetString(), request.Questions[p.Name].TypeName);
        Assert.Equal(v.GetProperty("kindCriteria").EnumerateArray().Select(e => e.GetString()!).Order(), StructureRecovery.KindCriteria.Keys.Order());
        Assert.Equal(v.GetProperty("headingLevelCriteria").EnumerateArray().Select(e => e.GetString()!).Order(), StructureRecovery.HeadingLevelCriteria.Keys.Order());
        Assert.Equal(v.GetProperty("calloutCriteria").EnumerateArray().Select(e => e.GetString()!).Order(), StructureRecovery.CalloutCriteria.Keys.Order());
        Assert.StartsWith("B000| Short title\n\nB001| long long", request.State.GetValue<string>());
    }

    [Fact]
    public void TheMemoClassifiesWithTheDocumentedQuestionCount()
    {
        var merge = Vectors.GetProperty("merge").EnumerateArray().Single(m => m.TryGetProperty("text", out _));
        var blocks = Blocks(merge.GetProperty("expected"));
        Assert.Equal(Vectors.GetProperty("memoClassifyQuestionCount").GetInt32(), StructureRecovery.ClassifyRequest(blocks).Questions.Count);
        Assert.Null(TypeSafeBudget.Overflow(StructureRecovery.ClassifyRequest(blocks)));
        Assert.Null(TypeSafeBudget.Overflow(StructureRecovery.StitchRequest(StructureRecovery.Lines(Memo))));
    }

    [Fact]
    public void JudgmentsMatchVectors()
    {
        foreach (var v in Vectors.GetProperty("judgments").EnumerateArray())
        {
            var body = $"{{\"model\":\"m\",\"answers\":{v.GetProperty("answers").GetRawText()},\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}";
            var actual = StructureRecovery.Judgments(TypeSafeResponse.Parse(Encoding.UTF8.GetBytes(body)), v.GetProperty("blockCount").GetInt32());
            var expected = v.GetProperty("expected").EnumerateArray().ToList();
            Assert.Equal(expected.Count, actual.Count);
            for (var i = 0; i < expected.Count; i++)
            {
                Assert.Equal(expected[i].GetProperty("kind").GetString(), actual[i].Kind.RawValue());
                Assert.Equal(expected[i].GetProperty("confidence").GetDouble(), actual[i].Confidence, 9);
                Assert.Equal(expected[i].GetProperty("headingLevel").GetString(), actual[i].HeadingLevel.RawValue());
                Assert.Equal(expected[i].GetProperty("stepProbability").GetDouble(), actual[i].StepProbability, 9);
                Assert.Equal(expected[i].GetProperty("calloutKind").GetString(), actual[i].CalloutKind);
            }
        }
    }

    [Fact]
    public void ARecoveredPasteAppliesOnlyWhileItStillDescribesWhatIsThere()
    {
        Check.Same(Vectors.GetProperty("staleAfterSeconds").GetDouble(), PasteRecoveryPolicy.StaleAfter.TotalSeconds);
        foreach (var v in Vectors.GetProperty("pasteApply").EnumerateArray())
        {
            var range = new Clio.Editor.TextRange(v.GetProperty("range").GetProperty("start").GetInt32(), v.GetProperty("range").GetProperty("length").GetInt32());
            var actual = PasteRecoveryPolicy.CanApply(v.GetProperty("buffer").GetString()!, range, v.GetProperty("original").GetString()!, TimeSpan.FromSeconds(v.GetProperty("elapsedSeconds").GetDouble()));
            Assert.True(v.GetProperty("expected").GetBoolean() == actual, v.GetProperty("name").GetString());
        }
    }

    [Fact]
    public void RenderMatchesVectorsAndNeverInventsText()
    {
        foreach (var v in Vectors.GetProperty("render").EnumerateArray())
        {
            var blocks = v.GetProperty("blocks").EnumerateArray().Select(b => new StructureRecovery.Block(b.GetString()!, [], true)).ToList();
            var judgments = v.GetProperty("judgments").EnumerateArray().Select(j => new StructureRecovery.Judgment(
                StructureRecovery.ParseKind(j.GetProperty("kind").GetString()!)!.Value,
                0.9,
                j.TryGetProperty("headingLevel", out var h) ? StructureRecovery.ParseLevel(h.GetString()!)!.Value : StructureRecovery.HeadingLevel.Section,
                j.TryGetProperty("step", out var s) ? s.GetDouble() : 0.1,
                j.TryGetProperty("callout", out var c) ? c.GetString()! : "note")).ToList();
            var markdown = StructureRecovery.Render(blocks, judgments);
            var name = v.GetProperty("name").GetString();
            Assert.True(v.GetProperty("expected").GetString() == markdown, $"{name}: {markdown}");
            foreach (var block in blocks) Assert.True(markdown.Contains(block.Text), $"{name}: lost {block.Text}");
        }
    }
}
