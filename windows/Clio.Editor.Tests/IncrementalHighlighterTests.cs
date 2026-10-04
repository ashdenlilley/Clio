using Clio.Editor.Markdown;
using Xunit;

namespace Clio.Editor.Tests;

public class IncrementalHighlighterTests
{
    private static string Fixture(string name) =>
        File.ReadAllText(Path.Combine(Spec.Root, "ClioTests", "Fixtures", "Markdown", "Conformance", name + ".md"));

    private static string Apply(string source, TextChange edit) =>
        source[..edit.Start] + edit.Inserted + source[(edit.Start + edit.Removed.Length)..];

    private static TextChange Edit(string source, int start, int length, string replacement) =>
        new(start, source.Substring(start, length), replacement);

    private static string Describe(IReadOnlyList<MarkdownSpan> spans) => string.Join("\n", spans.Select(s => s.ToString()));

    private static void AssertMatchesFull(string source, HighlightUpdate update, string context)
    {
        var full = MarkdownHighlighter.Highlight(source);
        Assert.True(full.SequenceEqual(update.Spans), $"{context}\n--- full ---\n{Describe(full)}\n--- incremental ---\n{Describe(update.Spans)}");
    }

    // ---- ports of MarkdownIncrementalTests.swift -------------------------------------------------

    [Fact]
    public void InvalidationExpandsToBlockBoundariesInUtf16()
    {
        const string source = "first\nline\n\nsecond \U0001F469\U0001F3FD‍\U0001F4BB line\nmore\n\nthird\n";
        var emoji = "\U0001F469\U0001F3FD‍\U0001F4BB";
        var start = source.IndexOf(emoji, StringComparison.Ordinal);
        var edit = Edit(source, start, emoji.Length, "Clio");
        var (old, _) = MarkdownIncrementalPolicy.Invalidation(edit, source, Apply(source, edit));
        var oldText = source.Substring(old.Start, old.Length);

        Assert.Contains("second", oldText);
        Assert.Contains("more", oldText);
        Assert.True(old.Length < source.Length);
    }

    [Fact]
    public void IncrementalEditReparsesOnlyTheBlockIslandAndMatchesFullSpans()
    {
        const string source = "# First\n\nAlpha *one*.\nSecond line.\n\nBeta **two**.\n\nEnd [link](https://a.co).\n";
        var engine = new IncrementalHighlighter();
        var initial = engine.Update(source);
        Assert.Equal(source.Length, initial.ParsedLength);

        var edit = Edit(source, source.IndexOf("one", StringComparison.Ordinal), 3, "world");
        var changed = Apply(source, edit);
        var update = engine.Update(changed, edit);

        Assert.True(update.ParsedLength < changed.Length);
        AssertMatchesFull(changed, update, "plain edit");
    }

    [Fact]
    public void StructuralInsertionsAndDeletionsMatchTheFullParseAndInvalidateEverything()
    {
        (string Plain, string Structural)[] pairs =
        [
            ("alpha\nbeta\n", "alpha\n\nbeta\n"),
            ("code\nbody\n", "```\ncode\n```\nbody\n"),
            ("A B\nrule\n1 2\n", "| A | B |\n| --- | --- |\n| 1 | 2 |\n"),
            ("item\nnext\n", "- item\n- next\n"),
            ("Title\nbody\n", "Title\n=====\nbody\n"),
            ("title: Clio\n\nbody\n", "---\ntitle: Clio\n---\n\nbody\n"),
        ];
        foreach (var (plain, structural) in pairs)
            foreach (var (before, after) in new[] { (plain, structural), (structural, plain) })
            {
                var engine = new IncrementalHighlighter();
                engine.Update(before);
                var update = engine.Update(after, IncrementalHighlighter.ContiguousEdit(before, after));
                AssertMatchesFull(after, update, $"{before.Replace("\n", "\\n")} -> {after.Replace("\n", "\\n")}");
                Assert.Equal(0, update.InvalidatedStart);
                Assert.Equal(after.Length, update.InvalidatedLength);
            }
    }

    [Fact]
    public void DiscontinuousEditFallsBackToAFullParse()
    {
        const string source = "First *one*.\n\nSecond **two**.\n";
        var engine = new IncrementalHighlighter();
        engine.Update(source);
        var lie = Edit(source, source.IndexOf("one", StringComparison.Ordinal), 3, "six");
        var unrelated = source.Replace("two", "ten");

        var update = engine.Update(unrelated, lie);

        Assert.Equal(unrelated.Length, update.InvalidatedLength);
        AssertMatchesFull(unrelated, update, "lying edit");
    }

    [Fact]
    public void InsertionShiftsUnaffectedSpanRanges()
    {
        const string source = "*one*\n\n**two**\n";
        var engine = new IncrementalHighlighter();
        engine.Update(source);
        var edit = new TextChange(0, "", "Prefix\n\n");
        var changed = Apply(source, edit);

        var update = engine.Update(changed, edit);

        var strong = update.Spans.First(s => s.Kind == SemanticKind.Strong && s.Role == SpanRole.Content);
        Assert.Equal("two", changed.Substring(strong.Start, strong.Length));
    }

    // ---- behaviour of this port ------------------------------------------------------------------

    [Fact]
    public void UnchangedTextIsANoOp()
    {
        var engine = new IncrementalHighlighter();
        var first = engine.Update("# Title\n\nbody *x*\n");
        var second = engine.Update("# Title\n\nbody *x*\n");
        Assert.Equal(0, second.ParsedLength);
        Assert.True(first.Spans.SequenceEqual(second.Spans));
    }

    [Fact]
    public void ContiguousEditIsMinimalAndNeverSplitsASurrogatePair()
    {
        Assert.Equal(new TextChange(3, "b", "XY"), IncrementalHighlighter.ContiguousEdit("abcbd", "abcXYd"));
        Assert.Equal(new TextChange(2, "", "zz"), IncrementalHighlighter.ContiguousEdit("abcd", "abzzcd"));
        Assert.Equal(new TextChange(4, "", ""), IncrementalHighlighter.ContiguousEdit("abcd", "abcd"));

        var edit = IncrementalHighlighter.ContiguousEdit("a\U0001F600b", "a\U0001F601b");
        Assert.Equal(1, edit.Start);
        Assert.Equal("\U0001F600", edit.Removed);
        Assert.Equal("\U0001F601", edit.Inserted);
        Assert.Equal("a\U0001F601b", Apply("a\U0001F600b", edit));
    }

    [Fact]
    public void ModeChangeAlwaysReparsesEverything()
    {
        var engine = new IncrementalHighlighter();
        engine.Update("plain *text*\n");
        var big = "plain *text*\n" + new string('x', 11 * 1024 * 1024);
        var update = engine.Update(big);
        Assert.Equal(HighlightMode.Reduced, update.Mode);
        Assert.Equal(big.Length, update.InvalidatedLength);
        Assert.True(update.ParsedLength <= MarkdownHighlighter.ReducedHighlightLimit);

        var back = engine.Update("plain *text*\n");
        Assert.Equal(HighlightMode.Full, back.Mode);
        AssertMatchesFull("plain *text*\n", back, "back to full");
    }

    [Fact]
    public void CancelledPassLeavesTheCommittedStateUntouched()
    {
        var engine = new IncrementalHighlighter();
        engine.Update("# One\n\nbody *x*\n");
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => engine.Update("# Two\n\nbody *y*\n", cts.Token));
        Assert.Equal("# One\n\nbody *x*\n", engine.Source);

        var update = engine.Update("# One\n\nbody *xz*\n");
        AssertMatchesFull("# One\n\nbody *xz*\n", update, "after cancelled pass");
    }

    // ---- context the island cannot see (deviations from the macOS policy) ----------------------

    private static HighlightUpdate EditAndUpdate(string source, string find, string replacement, out string changed)
    {
        var engine = new IncrementalHighlighter();
        engine.Update(source);
        var edit = Edit(source, source.IndexOf(find, StringComparison.Ordinal), find.Length, replacement);
        changed = Apply(source, edit);
        return engine.Update(changed, edit);
    }

    [Fact]
    public void EditInsideAFenceBodyThatSpansBlankLinesReparsesEverything()
    {
        var update = EditAndUpdate("```\ncode a\n\ncode b\n```\n\ntext *x*\n", "code b", "code *c*", out var changed);
        AssertMatchesFull(changed, update, "fence body");
        Assert.Equal(changed.Length, update.InvalidatedLength);
    }

    [Fact]
    public void EditInAnUnclosedFenceDoesNotLeaveTheTrailingBlankLinesBehind()
    {
        var update = EditAndUpdate("```swift\nlet a = 1\nlet b = 2\n\n", "let b", "let bb", out var changed);
        AssertMatchesFull(changed, update, "unclosed fence");
    }

    [Fact]
    public void EditInAnIndentedListContinuationReparsesEverything()
    {
        var update = EditAndUpdate("- item\n\n    continued *text* here\n\nafter\n", "continued", "carried on", out var changed);
        AssertMatchesFull(changed, update, "indented continuation");
        Assert.Equal(changed.Length, update.InvalidatedLength);
    }

    [Fact]
    public void IndentingALineReparsesEverything()
    {
        var update = EditAndUpdate("- item\n\nplain ~~old~~ text\n", "plain", "    plain", out var changed);
        AssertMatchesFull(changed, update, "indent added");
        Assert.Equal(changed.Length, update.InvalidatedLength);
    }

    [Fact]
    public void EditNextToABracketInADocumentWithReferenceDefinitionsReparsesEverything()
    {
        var update = EditAndUpdate("See [a][x] and *emph*.\n\n[x]: https://a.co\n", "emph", "emphasis", out var changed);
        AssertMatchesFull(changed, update, "reference link");
        Assert.Equal(changed.Length, update.InvalidatedLength);
    }

    [Fact]
    public void ABracketFreeEditInADocumentWithReferenceDefinitionsStaysIncremental()
    {
        var update = EditAndUpdate("Plain *emph*.\n\n[x]: https://a.co\n", "emph", "emphasis", out var changed);
        AssertMatchesFull(changed, update, "bracket-free paragraph");
        Assert.True(update.ParsedLength < changed.Length);
    }

    [Fact]
    public void FrontMatterThatOpensAFenceKeepsTheDocumentOnFullParses()
    {
        var source = "---\n```: x\n---\n\nVisit and ~~old~~ text.\n";
        var engine = new IncrementalHighlighter();
        engine.Update(source);
        var edit = Edit(source, source.IndexOf("Visit", StringComparison.Ordinal), 5, "Come");
        var changed = Apply(source, edit);
        var update = engine.Update(changed, edit);
        AssertMatchesFull(changed, update, "front matter fence hazard");
        Assert.Equal(changed.Length, update.InvalidatedLength);
    }

    [Fact]
    public void TypingTheFirstCharacterOfAnUnindentedLineStaysIncremental()
    {
        var update = EditAndUpdate("First.\n\nSecond line\n", "Second", "XSecond", out var changed);
        AssertMatchesFull(changed, update, "first character at column 0");
        Assert.True(update.ParsedLength < changed.Length);
    }
    // ---- equivalence with the full parse ---------------------------------------------------------

    private static readonly string[] Snippets =
    [
        "a", "word", " ", "  ", "*", "**", "_", "~~", "`", "```", "\n", "\n\n", "#", "# ", "> ", "- ", "1. ", "| ", "---", "===",
        "[", "]", "](https://a.co)", "[x]: https://a.co", "[^1]", "[^1]: note", "<b>", "&amp;", "\\", "é", "\U0001F600", "\r\n", "\t",
    ];

    [Theory]
    [InlineData("blocks", 1, false)]
    [InlineData("delimiters", 2, false)]
    [InlineData("gfm-extensions", 3, false)]
    [InlineData("links-code-entities", 4, false)]
    [InlineData("malformed-unicode", 5, false)]
    [InlineData("blocks", 6, true)]
    [InlineData("delimiters", 7, true)]
    [InlineData("gfm-extensions", 8, true)]
    [InlineData("links-code-entities", 9, true)]
    [InlineData("malformed-unicode", 10, true)]
    public void RandomEditSequencesMatchTheFullParseAtEveryStep(string fixture, int seed, bool crlf) =>
        RunRandomEdits(fixture, seed, crlf, steps: 600, requireIncremental: true);

    /// <summary>Opt-in sweep: set CLIO_STRESS=1 to run many seeds with long edit sequences.</summary>
    [Fact]
    public void StressSweepMatchesTheFullParse()
    {
        if (Environment.GetEnvironmentVariable("CLIO_STRESS") != "1") return;
        foreach (var fixture in new[] { "blocks", "delimiters", "gfm-extensions", "links-code-entities", "malformed-unicode" })
            for (var seed = 100; seed < 120; seed++)
                RunRandomEdits(fixture, seed, crlf: seed % 2 == 0, steps: 4000, requireIncremental: false);
    }

    /// <summary>
    /// The editor buffer is LF (CRLF is a save-time concern), so LF is the realistic case; CRLF text is also
    /// covered, but edits never split a CR from its LF because a lone CR is not something the app produces.
    /// </summary>
    private static void RunRandomEdits(string fixture, int seed, bool crlf, int steps, bool requireIncremental)
    {
        string Shape(string text) => crlf ? text.Replace("\r\n", "\n").Replace("\n", "\r\n") : text.Replace("\r\n", "\n");
        var snippets = Snippets.Select(Shape).ToArray();
        var random = new Random(seed);
        var original = Shape(Fixture(fixture));
        var source = original;
        var engine = new IncrementalHighlighter();
        engine.Update(source);
        var incrementalSteps = 0;

        for (var step = 0; step < steps; step++)
        {
            var start = random.Next(source.Length + 1);
            if (start > 0 && start < source.Length && (char.IsLowSurrogate(source[start]) || (source[start - 1] == '\r' && source[start] == '\n'))) start--;
            var removed = random.Next(4) == 0 ? 0 : Math.Min(random.Next(1, 9), source.Length - start);
            var end = Math.Min(start + removed, source.Length);
            while (end < source.Length && end > start && (char.IsLowSurrogate(source[end]) || (source[end - 1] == '\r' && source[end] == '\n'))) end++;
            removed = end - start;
            var inserted = random.Next(5) == 0 ? "" : snippets[random.Next(snippets.Length)];
            var edit = Edit(source, start, removed, inserted);
            var next = Apply(source, edit);

            // Alternate between the explicit edit and the diff-derived edit: both must agree with a full parse.
            var update = step % 2 == 0 ? engine.Update(next, edit) : engine.Update(next);
            AssertMatchesFull(next, update,
                $"{fixture} crlf={crlf} seed {seed} step {step}: replace [{start},{removed}] with '{Escape(inserted)}'\nBEFORE: {Escape(source)}\nAFTER: {Escape(next)}");
            if (update.ParsedLength < next.Length) incrementalSteps++;
            source = next;

            // Documents drift; restart from the fixture now and then so they stay realistic and small.
            if (source.Length > 4 * original.Length || source.Length < 20)
            {
                source = original;
                engine.Update(source);
            }
        }

        // The test must actually exercise the island path, not fall back every time.
        if (requireIncremental) Assert.True(incrementalSteps > steps / 20, $"{fixture}: only {incrementalSteps} of {steps} steps were incremental");
    }
    private static string Escape(string text) =>
        text.Length > 400 ? Escape(text[..400]) + "..." : text.Replace("\n", "\\n").Replace("\r", "\\r");
    [Fact]
    public void TypingARunOfCharactersStaysIncrementalAndExact()
    {
        var source = "# Title\n\nFirst paragraph.\n\nSecond paragraph with *emphasis* and a [link](https://a.co).\n\nThird.\n";
        var engine = new IncrementalHighlighter();
        engine.Update(source);
        var at = source.IndexOf("Second", StringComparison.Ordinal) + "Second paragraph".Length;
        var incremental = 0;
        foreach (var ch in " typed in the middle")
        {
            var edit = new TextChange(at, "", ch.ToString());
            source = Apply(source, edit);
            at++;
            var update = engine.Update(source, edit);
            AssertMatchesFull(source, update, $"typed '{ch}'");
            if (update.ParsedLength < source.Length) incremental++;
        }
        Assert.Equal(" typed in the middle".Length, incremental);
    }
}
