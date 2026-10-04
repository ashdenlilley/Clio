using Xunit;

namespace Clio.Editor.Tests;

public class TextBufferTests
{
    [Fact]
    public void LineIndexSurvivesRandomEditsOnLargeDocument()
    {
        var rng = new Random(1234);
        var seed = string.Concat(Enumerable.Range(0, 800).Select(i => $"line {i} some text\n"));
        var buffer = new TextBuffer(seed);
        string[] pieces = ["a", "\n", "\r\n", "\r", "xyz\nabc", "", "\n\n", "é😀"];
        for (var n = 0; n < 2000; n++)
        {
            var start = rng.Next(buffer.Length + 1);
            var length = rng.Next(Math.Min(40, buffer.Length - start) + 1);
            buffer.Replace(start, length, pieces[rng.Next(pieces.Length)], 0, 0);
            if (n % 50 == 0) AssertIndexMatchesFresh(buffer);
        }
        AssertIndexMatchesFresh(buffer);
    }

    private static void AssertIndexMatchesFresh(TextBuffer b)
    {
        var fresh = new TextBuffer(b.Text);
        Assert.Equal(fresh.LineCount, b.LineCount);
        for (var i = 0; i < fresh.LineCount; i++) Assert.Equal(fresh.LineStart(i), b.LineStart(i));
    }

    [Fact]
    public void UndoRedoRestoreTextAndSelection()
    {
        var b = new TextBuffer("hello");
        b.Replace(5, 0, " world", 5, 11);
        Assert.Equal("hello world", b.Text);
        Assert.Equal(5, b.Undo());
        Assert.Equal("hello", b.Text);
        Assert.Equal(11, b.Redo());
        Assert.Equal("hello world", b.Text);
        Assert.Null(b.Redo());
    }

    [Fact]
    public void AdjacentTypingCoalescesButPauseAndNonAdjacentDoNot()
    {
        var b = new TextBuffer("");
        b.Replace(0, 0, "a", 0, 1, coalescible: true, nowMs: 100);
        b.Replace(1, 0, "b", 1, 2, coalescible: true, nowMs: 200);
        b.Replace(2, 0, "c", 2, 3, coalescible: true, nowMs: 300);
        b.Replace(3, 0, "d", 3, 4, coalescible: true, nowMs: 5000); // pause
        b.Replace(0, 0, "X", 4, 1, coalescible: true, nowMs: 5100); // not adjacent
        Assert.Equal("Xabcd", b.Text);
        b.Undo(); Assert.Equal("abcd", b.Text);
        b.Undo(); Assert.Equal("abc", b.Text);
        b.Undo(); Assert.Equal("", b.Text);
        Assert.False(b.CanUndo);
    }

    [Fact]
    public void NewEditClearsRedo()
    {
        var b = new TextBuffer("x");
        b.Replace(1, 0, "y", 1, 2);
        b.Undo();
        b.Replace(1, 0, "z", 1, 2);
        Assert.False(b.CanRedo);
    }

    [Theory]
    [InlineData("a\nb\r\nc\rd", new[] { 0, 2, 5, 7 })]
    [InlineData("", new[] { 0 })]
    [InlineData("a\n", new[] { 0, 2 })]
    public void LineStarts(string text, int[] expected)
    {
        var b = new TextBuffer(text);
        Assert.Equal(expected, Enumerable.Range(0, b.LineCount).Select(b.LineStart));
    }

    [Fact]
    public void LineOfAndContentEnd()
    {
        var b = new TextBuffer("ab\r\ncd\nef");
        Assert.Equal(0, b.LineOf(0));
        Assert.Equal(1, b.LineOf(4));
        Assert.Equal(2, b.LineOf(9));
        Assert.Equal(2, b.LineContentEnd(0));
        Assert.Equal(6, b.LineContentEnd(1));
        Assert.Equal(9 + 0 + 0, b.LineContentEnd(2) - 0);
    }
}
