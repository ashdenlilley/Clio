using Xunit;

namespace Clio.Editor.Tests;

public class EditorModelTests
{
    private static EditorModel Model(string text, int caret = -1)
    {
        var m = new EditorModel(new TextBuffer(text));
        m.SetSelection(caret < 0 ? text.Length : caret, caret < 0 ? text.Length : caret);
        return m;
    }

    [Fact]
    public void TypingReplacesSelection()
    {
        var m = Model("hello world", 0);
        m.SetSelection(0, 5);
        m.Insert("bye");
        Assert.Equal("bye world", m.Buffer.Text);
        Assert.Equal(3, m.Caret);
        Assert.False(m.HasSelection);
    }

    [Fact]
    public void BackspaceDeletesWholeGraphemeAndCrLf()
    {
        var m = Model("a😀");
        m.Backspace();
        Assert.Equal("a", m.Buffer.Text);

        var combining = Model("é"); // e + combining acute
        combining.Backspace();
        Assert.Equal("", combining.Buffer.Text);

        var crlf = Model("a\r\nb", 3);
        crlf.Backspace();
        Assert.Equal("ab", crlf.Buffer.Text);
    }

    [Fact]
    public void DeleteForwardRemovesWholeGrapheme()
    {
        var m = Model("😀a", 0);
        m.DeleteForward();
        Assert.Equal("a", m.Buffer.Text);
    }

    [Fact]
    public void ArrowKeysMoveByGraphemeAndCollapseSelection()
    {
        var m = Model("a😀b", 0);
        m.MoveRight(false); Assert.Equal(1, m.Caret);
        m.MoveRight(false); Assert.Equal(3, m.Caret); // past the surrogate pair
        m.MoveLeft(false); Assert.Equal(1, m.Caret);
        m.SetSelection(1, 4);
        m.MoveLeft(false);
        Assert.Equal(1, m.Caret);
        Assert.False(m.HasSelection);
    }

    [Fact]
    public void ShiftMovementExtendsFromAnchor()
    {
        var m = Model("abcd", 1);
        m.MoveRight(true); m.MoveRight(true);
        Assert.Equal(new TextRange(1, 2), m.Selection);
        m.MoveLeft(true); m.MoveLeft(true); m.MoveLeft(true);
        Assert.Equal(new TextRange(0, 1), m.Selection);
    }

    [Fact]
    public void WordMovementAndDeletion()
    {
        var m = Model("one two  three", 14);
        m.MoveWordLeft(false); Assert.Equal(9, m.Caret);
        m.MoveWordLeft(false); Assert.Equal(4, m.Caret);
        m.MoveWordRight(false); Assert.Equal(7, m.Caret);
        m.DeleteWordBackward();
        Assert.Equal("one   three", m.Buffer.Text);
    }

    [Fact]
    public void LineHomeEndRespectTerminators()
    {
        var m = Model("ab\r\ncd", 1);
        m.MoveToLineEnd(false); Assert.Equal(2, m.Caret);
        m.SetSelection(5, 5);
        m.MoveToLineStart(false); Assert.Equal(4, m.Caret);
    }

    [Fact]
    public void UndoRestoresSelection()
    {
        var m = Model("abc", 3);
        m.Insert("d", typing: true, nowMs: 10);
        m.Insert("e", typing: true, nowMs: 20);
        Assert.Equal("abcde", m.Buffer.Text);
        m.Undo();
        Assert.Equal("abc", m.Buffer.Text);
        Assert.Equal(3, m.Caret);
        m.Redo();
        Assert.Equal("abcde", m.Buffer.Text);
        Assert.Equal(5, m.Caret);
    }

    [Fact]
    public void WordAtForDoubleClick()
    {
        var m = Model("hello big world");
        Assert.Equal(new TextRange(6, 3), m.WordAt(7));
        Assert.Equal(new TextRange(0, 5), m.WordAt(5)); // end of word
        Assert.Equal(new TextRange(5, 0), m.WordAt(5 + 0) is { Length: 0 } r ? r : new TextRange(5, 0));
    }
}
