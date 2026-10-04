using Clio.Editor.Automation;
using Xunit;

namespace Clio.Editor.Tests;

public class UiaTextMathTests
{
    private sealed class Source(string text, params int[] lineStarts) : IUiaTextSource
    {
        public string Text { get; } = text;
        public IReadOnlyList<int> VisualLineStarts { get; } = lineStarts;
    }

    // Offsets: "Hello " 0-5, "world" 6-10, ", " 11-12, "again" 13-17, "." 18, "\n" 19 | "Second line here\n" 20-36 | "\n" 37 | "Third" 38-42.
    private static readonly Source Doc = new("Hello world, again.\nSecond line here\n\nThird");

    [Theory]
    [InlineData(0, 0, 0, 6)]
    [InlineData(3, 3, 0, 6)]
    [InlineData(6, 6, 6, 11)]
    [InlineData(11, 11, 11, 13)]
    [InlineData(18, 18, 18, 19)]
    [InlineData(19, 19, 19, 20)]
    [InlineData(0, 8, 0, 11)]
    [InlineData(0, 6, 0, 6)]
    public void ExpandToWordIncludesTrailingBlanksAndBreaksAtPunctuation(int start, int end, int expectedStart, int expectedEnd) =>
        Assert.Equal((expectedStart, expectedEnd), UiaTextMath.Expand(Doc, start, end, UiaUnit.Word));

    [Fact]
    public void ExpandToParagraphCoversTheLogicalLineWithItsBreak()
    {
        Assert.Equal((20, 37), UiaTextMath.Expand(Doc, 25, 25, UiaUnit.Paragraph));
        Assert.Equal((0, 37), UiaTextMath.Expand(Doc, 5, 25, UiaUnit.Paragraph));
        Assert.Equal((37, 38), UiaTextMath.Expand(Doc, 37, 37, UiaUnit.Paragraph));
    }

    [Fact]
    public void ExpandAtTheEndOfTheTextSelectsTheLastUnit()
    {
        Assert.Equal((38, 43), UiaTextMath.Expand(Doc, 43, 43, UiaUnit.Paragraph));
        Assert.Equal((38, 43), UiaTextMath.Expand(Doc, 43, 43, UiaUnit.Word));
    }

    [Fact]
    public void ExpandToDocumentAndUnsupportedUnitsCoverEverything()
    {
        foreach (var unit in new[] { UiaUnit.Document, UiaUnit.Page, UiaUnit.Format })
            Assert.Equal((0, 43), UiaTextMath.Expand(Doc, 7, 9, unit));
    }

    [Fact]
    public void CharacterUnitsAreTextElements()
    {
        var emoji = new Source("a\U0001F600b");
        Assert.Equal((1, 3), UiaTextMath.Expand(emoji, 1, 1, UiaUnit.Character));
        Assert.Equal((1, 3), UiaTextMath.Expand(emoji, 2, 2, UiaUnit.Character)); // inside the pair
        Assert.Equal((3, 4), UiaTextMath.Expand(emoji, 3, 3, UiaUnit.Character));

        var combining = new Source("éx");
        Assert.Equal((0, 2), UiaTextMath.Expand(combining, 0, 0, UiaUnit.Character));

        var crlf = new Source("a\r\nb");
        Assert.Equal((1, 3), UiaTextMath.Expand(crlf, 1, 1, UiaUnit.Character));
        Assert.Equal((1, 3), UiaTextMath.Expand(crlf, 2, 2, UiaUnit.Character));
    }

    [Fact]
    public void MoveShiftsByWholeUnitsAndReportsHowFarItWent()
    {
        Assert.Equal((11, 13, 2), UiaTextMath.Move(Doc, 0, 0, UiaUnit.Word, 2));
        Assert.Equal((38, 43, 3), UiaTextMath.Move(Doc, 0, 0, UiaUnit.Paragraph, 5)); // only three paragraphs follow
        Assert.Equal((20, 37, -2), UiaTextMath.Move(Doc, 40, 40, UiaUnit.Paragraph, -2));
        Assert.Equal((0, 20, -1), UiaTextMath.Move(Doc, 25, 25, UiaUnit.Paragraph, -9)); // clamped at the start
    }

    [Fact]
    public void MoveZeroOrByDocumentOnlyNormalises()
    {
        Assert.Equal((0, 6, 0), UiaTextMath.Move(Doc, 3, 3, UiaUnit.Word, 0));
        Assert.Equal((0, 43, 0), UiaTextMath.Move(Doc, 3, 3, UiaUnit.Document, 4));
    }

    [Fact]
    public void MoveFromAnUnnormalisedRangeStartsFromItsFirstUnit()
    {
        // (8,8) is inside "world"; the unit is normalised first, then moved.
        Assert.Equal((11, 13, 1), UiaTextMath.Move(Doc, 8, 8, UiaUnit.Word, 1));
    }

    [Fact]
    public void MoveEndpointByUnit()
    {
        Assert.Equal((0, 6, 1), UiaTextMath.MoveEndpoint(Doc, 0, 0, moveEnd: true, UiaUnit.Word, 1));
        Assert.Equal((0, 13, 3), UiaTextMath.MoveEndpoint(Doc, 0, 0, moveEnd: true, UiaUnit.Word, 3));
        Assert.Equal((0, 6, -1), UiaTextMath.MoveEndpoint(Doc, 0, 11, moveEnd: true, UiaUnit.Word, -1));
        Assert.Equal((6, 11, 1), UiaTextMath.MoveEndpoint(Doc, 0, 11, moveEnd: false, UiaUnit.Word, 1));
    }

    [Fact]
    public void MovingAnEndpointPastTheOtherCollapsesTheRange()
    {
        Assert.Equal((18, 18, 3), UiaTextMath.MoveEndpoint(Doc, 6, 11, moveEnd: false, UiaUnit.Word, 3));
        // Only two boundaries lie before offset 11 ("world" at 6, "Hello " at 0), so the third step is not taken.
        Assert.Equal((0, 0, -2), UiaTextMath.MoveEndpoint(Doc, 6, 11, moveEnd: true, UiaUnit.Word, -3));
    }

    [Fact]
    public void MoveEndpointStopsAtTheDocumentEdgesAndCountsOnlyRealSteps()
    {
        var (_, end, moved) = UiaTextMath.MoveEndpoint(Doc, 0, 0, moveEnd: true, UiaUnit.Paragraph, 99);
        Assert.Equal(43, end);
        Assert.Equal(4, moved);
        Assert.Equal((0, 0, 0), UiaTextMath.MoveEndpoint(Doc, 0, 0, moveEnd: false, UiaUnit.Word, -4));
    }

    [Fact]
    public void DocumentUnitHasOnlyItsTwoEdges()
    {
        Assert.Equal((0, 43, 1), UiaTextMath.MoveEndpoint(Doc, 0, 5, moveEnd: true, UiaUnit.Document, 1));
        Assert.Equal((0, 5, -1), UiaTextMath.MoveEndpoint(Doc, 3, 5, moveEnd: false, UiaUnit.Document, -1));
    }

    [Fact]
    public void LinesFollowTheVisualWrapWhenKnown()
    {
        var wrapped = new Source("aaaa bbbb cccc dddd", 0, 10);
        Assert.Equal((0, 10), UiaTextMath.Expand(wrapped, 3, 3, UiaUnit.Line));
        Assert.Equal((10, 19), UiaTextMath.Expand(wrapped, 12, 12, UiaUnit.Line));
        Assert.Equal((10, 19, 1), UiaTextMath.Move(wrapped, 0, 0, UiaUnit.Line, 3));
        Assert.Equal((0, 10), UiaTextMath.Expand(wrapped, 0, 10, UiaUnit.Line));
    }

    [Fact]
    public void LinesFallBackToLogicalLinesWithoutLayout()
    {
        Assert.Equal((20, 37), UiaTextMath.Expand(Doc, 22, 22, UiaUnit.Line));
    }

    [Fact]
    public void EmptyDocumentIsSafe()
    {
        var empty = new Source("");
        Assert.Equal((0, 0), UiaTextMath.Expand(empty, 0, 0, UiaUnit.Word));
        Assert.Equal((0, 0, 0), UiaTextMath.Move(empty, 0, 0, UiaUnit.Paragraph, 3));
        Assert.Equal((0, 0, 0), UiaTextMath.MoveEndpoint(empty, 0, 0, moveEnd: true, UiaUnit.Character, 3));
    }

    [Fact]
    public void LeadingIndentationIsAWordOfItsOwn()
    {
        var indented = new Source("    code here");
        Assert.Equal((0, 4), UiaTextMath.Expand(indented, 1, 1, UiaUnit.Word));
        Assert.Equal((4, 9), UiaTextMath.Expand(indented, 4, 4, UiaUnit.Word));
    }

    [Fact]
    public void CompareEndpointsOrdersByTheChosenEnds()
    {
        Assert.True(UiaTextMath.CompareEndpoints(0, 5, false, 3, 9, false) < 0);
        Assert.True(UiaTextMath.CompareEndpoints(0, 5, true, 3, 9, false) > 0);
        Assert.Equal(0, UiaTextMath.CompareEndpoints(0, 5, true, 5, 9, false));
    }

    [Fact]
    public void GetTextClampsAndNeverSplitsASurrogatePair()
    {
        var s = new Source("ab\U0001F600cd");
        Assert.Equal("ab\U0001F600", UiaTextMath.GetText(s, 0, 4, -1));
        Assert.Equal("ab", UiaTextMath.GetText(s, 0, 4, 3));
        Assert.Equal("ab\U0001F600c", UiaTextMath.GetText(s, 0, 99, 5));
        Assert.Equal("", UiaTextMath.GetText(s, 7, 9, -1));
    }

    [Fact]
    public void FindTextForwardAndBackwardWithinTheRange()
    {
        var s = new Source("one two one two");
        Assert.Equal((0, 3), UiaTextMath.Find(s, 0, 15, "one", backward: false, ignoreCase: false));
        Assert.Equal((8, 11), UiaTextMath.Find(s, 0, 15, "one", backward: true, ignoreCase: false));
        Assert.Equal((8, 11), UiaTextMath.Find(s, 4, 15, "ONE", backward: false, ignoreCase: true));
        Assert.Null(UiaTextMath.Find(s, 0, 15, "ONE", backward: false, ignoreCase: false));
        Assert.Null(UiaTextMath.Find(s, 0, 15, "", backward: false, ignoreCase: false));
    }
}
