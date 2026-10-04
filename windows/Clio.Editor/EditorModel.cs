using System.Globalization;

namespace Clio.Editor;

/// <summary>
/// Selection and editing commands over a <see cref="TextBuffer"/>. Pure logic: no layout, no UI.
/// Caret movement is by text element (grapheme cluster) so emoji and combining marks move and delete as one.
/// </summary>
public sealed class EditorModel
{
    public TextBuffer Buffer { get; }
    public int Anchor { get; private set; }
    public int Caret { get; private set; }

    public event Action? SelectionChanged;

    public EditorModel(TextBuffer buffer) => Buffer = buffer;

    public TextRange Selection => new(Math.Min(Anchor, Caret), Math.Abs(Caret - Anchor));
    public bool HasSelection => Anchor != Caret;

    public void SetSelection(int anchor, int caret)
    {
        anchor = Math.Clamp(anchor, 0, Buffer.Length);
        caret = Math.Clamp(caret, 0, Buffer.Length);
        if (anchor == Anchor && caret == Caret) return;
        (Anchor, Caret) = (anchor, caret);
        SelectionChanged?.Invoke();
    }

    public void SelectAll() => SetSelection(0, Buffer.Length);

    // ---- editing ---------------------------------------------------------------------------------

    public void Insert(string text, bool typing = false, long nowMs = -1)
    {
        if (text.Length == 0 && !HasSelection) return;
        var sel = Selection;
        var after = sel.Start + text.Length;
        // Only single-character typing without a selection to replace coalesces into one undo step.
        var coalescible = typing && !HasSelection && text.Length > 0 && !text.Contains('\n');
        Buffer.Replace(sel.Start, sel.Length, text, Caret, after, coalescible, nowMs);
        SetSelection(after, after);
    }

    public void Backspace()
    {
        if (HasSelection) { Insert(""); return; }
        if (Caret == 0) return;
        var from = PreviousBoundary(Caret);
        Buffer.Replace(from, Caret - from, "", Caret, from);
        SetSelection(from, from);
    }

    public void DeleteForward()
    {
        if (HasSelection) { Insert(""); return; }
        if (Caret >= Buffer.Length) return;
        var to = NextBoundary(Caret);
        Buffer.Replace(Caret, to - Caret, "", Caret, Caret);
    }

    public void DeleteWordBackward()
    {
        if (HasSelection) { Insert(""); return; }
        var from = PreviousWordStart(Caret);
        if (from == Caret) return;
        Buffer.Replace(from, Caret - from, "", Caret, from);
        SetSelection(from, from);
    }

    public void Undo()
    {
        if (Buffer.Undo() is { } sel) SetSelection(sel, sel);
    }

    public void Redo()
    {
        if (Buffer.Redo() is { } sel) SetSelection(sel, sel);
    }

    // ---- movement --------------------------------------------------------------------------------

    public void MoveLeft(bool extend)
    {
        if (!extend && HasSelection) { var s = Selection.Start; SetSelection(s, s); return; }
        MoveCaret(PreviousBoundary(Caret), extend);
    }

    public void MoveRight(bool extend)
    {
        if (!extend && HasSelection) { var e = Selection.End; SetSelection(e, e); return; }
        MoveCaret(NextBoundary(Caret), extend);
    }

    public void MoveWordLeft(bool extend) => MoveCaret(PreviousWordStart(Caret), extend);

    public void MoveWordRight(bool extend) => MoveCaret(NextWordEnd(Caret), extend);

    public void MoveToLineStart(bool extend) => MoveCaret(Buffer.LineStart(Buffer.LineOf(Caret)), extend);

    public void MoveToLineEnd(bool extend) => MoveCaret(Buffer.LineContentEnd(Buffer.LineOf(Caret)), extend);

    public void MoveToDocumentStart(bool extend) => MoveCaret(0, extend);

    public void MoveToDocumentEnd(bool extend) => MoveCaret(Buffer.Length, extend);

    public void MoveCaret(int offset, bool extend)
    {
        offset = Math.Clamp(offset, 0, Buffer.Length);
        SetSelection(extend ? Anchor : offset, offset);
    }

    // ---- boundaries ------------------------------------------------------------------------------

    /// <summary>Start of the text element ending at <paramref name="offset"/>; \r\n counts as one.</summary>
    public int PreviousBoundary(int offset)
    {
        if (offset <= 0) return 0;
        var text = Buffer.Text;
        var lineStart = Buffer.LineStart(Buffer.LineOf(offset - 1));
        // Walk elements from the start of the line (bounded by line length) to find the one ending at offset.
        var from = lineStart;
        if (offset - lineStart > 4096) from = offset - 64; // pathological line: approximate, then snap to a valid start
        var last = from;
        var i = from;
        while (i < offset)
        {
            last = i;
            i += StringInfo.GetNextTextElementLength(text.AsSpan(i));
        }
        if (offset - 1 >= 0 && text[offset - 1] == '\n' && offset - 2 >= 0 && text[offset - 2] == '\r') return offset - 2;
        return i == offset ? last : Math.Max(0, offset - 1);
    }

    public int NextBoundary(int offset)
    {
        if (offset >= Buffer.Length) return Buffer.Length;
        var text = Buffer.Text;
        if (text[offset] == '\r' && offset + 1 < text.Length && text[offset + 1] == '\n') return offset + 2;
        return Math.Min(Buffer.Length, offset + StringInfo.GetNextTextElementLength(text.AsSpan(offset)));
    }

    public int PreviousWordStart(int offset)
    {
        var t = Buffer.Text;
        var i = offset;
        while (i > 0 && !IsWordChar(t[i - 1])) i--;
        while (i > 0 && IsWordChar(t[i - 1])) i--;
        return i;
    }

    public int NextWordEnd(int offset)
    {
        var t = Buffer.Text;
        var i = offset;
        while (i < t.Length && !IsWordChar(t[i])) i++;
        while (i < t.Length && IsWordChar(t[i])) i++;
        return i;
    }

    /// <summary>Word under or adjacent to <paramref name="offset"/>, for double-click selection.</summary>
    public TextRange WordAt(int offset)
    {
        var t = Buffer.Text;
        offset = Math.Clamp(offset, 0, t.Length);
        if (offset == t.Length || !IsWordChar(t[offset])) { if (offset > 0 && IsWordChar(t[offset - 1])) offset--; else return new TextRange(offset, 0); }
        var s = offset;
        var e = offset;
        while (s > 0 && IsWordChar(t[s - 1])) s--;
        while (e < t.Length && IsWordChar(t[e])) e++;
        return new TextRange(s, e - s);
    }

    private static bool IsWordChar(char c) => char.IsLetterOrDigit(c) || c is '_' or '\'' or '’';
}
