namespace Clio.Editor;

public readonly record struct TextChange(int Start, string Removed, string Inserted);

/// <summary>
/// Document text with a line index and linear undo/redo. Offsets are UTF-16 code units.
/// Consecutive single-character typing at adjacent offsets coalesces into one undo step.
/// </summary>
public sealed class TextBuffer
{
    private string _text;
    private List<int> _lineStarts = [0];
    private readonly List<Step> _undo = [];
    private readonly List<Step> _redo = [];
    private long _lastEditTicks;
    private const long CoalesceWindowMs = 1000;

    private sealed record Step(TextChange Change, int SelectionBefore, int SelectionAfter, bool Coalescible);

    public event Action<TextChange>? Changed;

    public TextBuffer(string text = "")
    {
        _text = text;
        RebuildLines();
    }

    public string Text => _text;
    public int Length => _text.Length;
    public int LineCount => _lineStarts.Count;
    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;

    /// <summary>Replaces the whole document and clears history (used on load).</summary>
    public void Reset(string text)
    {
        _text = text;
        _undo.Clear();
        _redo.Clear();
        RebuildLines();
    }

    public int LineStart(int line) => _lineStarts[line];

    /// <summary>End of the line's content, excluding its terminator.</summary>
    public int LineContentEnd(int line)
    {
        var end = line + 1 < _lineStarts.Count ? _lineStarts[line + 1] : _text.Length;
        while (end > _lineStarts[line] && _text[end - 1] is '\n' or '\r') end--;
        return end;
    }

    public int LineOf(int offset)
    {
        var i = _lineStarts.BinarySearch(Math.Clamp(offset, 0, _text.Length));
        return i >= 0 ? i : ~i - 1;
    }

    public string Slice(int start, int length) => _text.Substring(start, length);

    /// <summary>Applies an edit. <paramref name="selectionBefore"/>/<paramref name="selectionAfter"/> are restored by undo/redo.</summary>
    public TextChange Replace(int start, int length, string inserted, int selectionBefore, int selectionAfter, bool coalescible = false, long nowMs = -1)
    {
        if (start < 0 || length < 0 || start + length > _text.Length) throw new ArgumentOutOfRangeException(nameof(start));
        var change = Apply(start, length, inserted);
        var now = nowMs >= 0 ? nowMs : Environment.TickCount64;
        if (coalescible && _undo.Count > 0 && _undo[^1] is { Coalescible: true } last
            && now - _lastEditTicks <= CoalesceWindowMs
            && last.Change.Removed.Length == 0 && change.Removed.Length == 0
            && last.Change.Start + last.Change.Inserted.Length == change.Start)
        {
            _undo[^1] = last with { Change = new TextChange(last.Change.Start, "", last.Change.Inserted + change.Inserted), SelectionAfter = selectionAfter };
        }
        else
        {
            _undo.Add(new Step(change, selectionBefore, selectionAfter, coalescible));
        }
        _redo.Clear();
        _lastEditTicks = now;
        return change;
    }

    /// <summary>Returns the selection to restore, or null if nothing to undo.</summary>
    public int? Undo()
    {
        if (_undo.Count == 0) return null;
        var step = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        Apply(step.Change.Start, step.Change.Inserted.Length, step.Change.Removed);
        _redo.Add(step);
        _lastEditTicks = 0;
        return step.SelectionBefore;
    }

    public int? Redo()
    {
        if (_redo.Count == 0) return null;
        var step = _redo[^1];
        _redo.RemoveAt(_redo.Count - 1);
        Apply(step.Change.Start, step.Change.Removed.Length, step.Change.Inserted);
        _undo.Add(step with { Coalescible = false });
        _lastEditTicks = 0;
        return step.SelectionAfter;
    }

    private TextChange Apply(int start, int length, string inserted)
    {
        var removed = _text.Substring(start, length);
        _text = string.Concat(_text.AsSpan(0, start), inserted, _text.AsSpan(start + length));
        UpdateLines(start, removed.Length, inserted);
        var change = new TextChange(start, removed, inserted);
        Changed?.Invoke(change);
        return change;
    }

    private void RebuildLines()
    {
        _lineStarts = [0];
        AppendStarts(_text, 0, 0);
    }

    private void AppendStarts(string s, int from, int baseOffset)
    {
        for (var i = from; i < s.Length; i++)
        {
            if (s[i] == '\n' || (s[i] == '\r' && !(i + 1 < s.Length && s[i + 1] == '\n')))
                _lineStarts.Add(baseOffset + i + 1);
        }
    }

    /// <summary>Incremental line-index update: drop starts inside the removed span, shift the rest, add starts from inserted text.</summary>
    private void UpdateLines(int start, int removedLength, string inserted)
    {
        // A \r\n pair can be split or joined at the edit boundary; rebuild when it could be.
        var boundaryTouchesCr = (start > 0 && _text.Length > 0 && start - 1 < _text.Length && (_text[start - 1] == '\r'))
                                || (inserted.Length > 0 && (inserted[0] == '\n' || inserted[^1] == '\r'))
                                || (start + inserted.Length < _text.Length && _text[start + inserted.Length] == '\n');
        if (boundaryTouchesCr || _text.Length < 4096)
        {
            RebuildLines();
            return;
        }
        var first = LineOfStart(start);
        var lastExclusive = LineOfStart(start + removedLength) + 1;
        var delta = inserted.Length - removedLength;
        var tail = new List<int>(_lineStarts.Count - lastExclusive);
        for (var i = lastExclusive; i < _lineStarts.Count; i++) tail.Add(_lineStarts[i] + delta);
        _lineStarts.RemoveRange(first + 1, _lineStarts.Count - first - 1);
        AppendStarts(inserted, 0, start);
        _lineStarts.AddRange(tail);
    }

    /// <summary>Index of the first line start strictly greater than <paramref name="offset"/>, minus nothing: the line containing offset.</summary>
    private int LineOfStart(int offset)
    {
        var i = _lineStarts.BinarySearch(offset);
        return i >= 0 ? i : ~i - 1;
    }
}
