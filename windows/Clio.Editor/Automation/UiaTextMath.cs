using System.Globalization;

namespace Clio.Editor.Automation;

/// <summary>Mirrors <c>TextUnit</c> in UI Automation. Format and Page are served as Document: the editor has no pages and
/// its styling is presentation of Markdown source, not text formatting.</summary>
public enum UiaUnit { Character, Format, Word, Line, Paragraph, Page, Document }

/// <summary>What the range arithmetic needs from the document: its text, and where visual (wrapped) lines begin.</summary>
public interface IUiaTextSource
{
    string Text { get; }

    /// <summary>Ascending offsets where each visual line starts; the first is 0. Empty means one line per logical line.</summary>
    IReadOnlyList<int> VisualLineStarts { get; }
}

/// <summary>
/// The text-range semantics of UI Automation (<c>ITextRangeProvider</c>) over plain text, with no UI types. A range is
/// <c>[Start, End)</c> in UTF-16 offsets. Unit boundaries: Character is a text element (so emoji, CRLF and combining
/// marks are one step), Word is a run of letters/digits or of punctuation plus its trailing blanks (a line break is its
/// own word), Line is a visual line, Paragraph is a logical line, Document is everything.
/// </summary>
public static class UiaTextMath
{
    /// <summary>ExpandToEnclosingUnit: a range grows to whole units; an empty range becomes the unit holding its position.</summary>
    public static (int Start, int End) Expand(IUiaTextSource source, int start, int end, UiaUnit unit)
    {
        var length = source.Text.Length;
        start = Math.Clamp(start, 0, length);
        end = Math.Clamp(end, start, length);
        if (IsWhole(unit)) return (0, length);
        var newStart = UnitStart(source, unit, start);
        var newEnd = end == start ? UnitEnd(source, unit, start) : UnitEnd(source, unit, end - 1);
        return (newStart, Math.Max(newEnd, newStart));
    }

    /// <summary>
    /// ITextRangeProvider.Move: the range is normalised to whole units, shifted by <paramref name="count"/> units and left
    /// spanning one unit. Returns the number of units actually moved (fewer at the document edges).
    /// </summary>
    public static (int Start, int End, int Moved) Move(IUiaTextSource source, int start, int end, UiaUnit unit, int count)
    {
        var (s, e) = Expand(source, start, end, unit);
        if (count == 0 || IsWhole(unit)) return (s, e, 0);
        var length = source.Text.Length;
        var position = s;
        var moved = 0;
        if (count > 0)
        {
            while (moved < count)
            {
                var next = NextBoundary(source, unit, position);
                if (next >= length) break; // already in the last unit
                position = next;
                moved++;
            }
        }
        else
        {
            while (moved > count && position > 0)
            {
                position = PreviousBoundary(source, unit, position);
                moved--;
            }
        }
        var (ns, ne) = Expand(source, position, position, unit);
        return (ns, ne, moved);
    }

    /// <summary>ITextRangeProvider.MoveEndpointByUnit. Crossing the other endpoint collapses the range there.</summary>
    public static (int Start, int End, int Moved) MoveEndpoint(IUiaTextSource source, int start, int end, bool moveEnd, UiaUnit unit, int count)
    {
        var length = source.Text.Length;
        start = Math.Clamp(start, 0, length);
        end = Math.Clamp(end, start, length);
        var position = moveEnd ? end : start;
        var moved = 0;
        if (IsWhole(unit))
        {
            // A whole-document unit has two boundaries: forward is the end, backward the start.
            var target = count > 0 ? length : count < 0 ? 0 : position;
            moved = target == position ? 0 : count > 0 ? 1 : -1;
            position = target;
        }
        else if (count > 0)
        {
            while (moved < count && position < length)
            {
                position = NextBoundary(source, unit, position);
                moved++;
            }
        }
        else if (count < 0)
        {
            while (moved > count && position > 0)
            {
                position = PreviousBoundary(source, unit, position);
                moved--;
            }
        }

        if (moveEnd)
        {
            end = position;
            if (end < start) start = end;
        }
        else
        {
            start = position;
            if (start > end) end = start;
        }
        return (start, end, moved);
    }

    /// <summary>ITextRangeProvider.CompareEndpoints: negative, zero or positive like <c>CompareTo</c>.</summary>
    public static int CompareEndpoints(int firstStart, int firstEnd, bool firstUsesEnd, int secondStart, int secondEnd, bool secondUsesEnd) =>
        (firstUsesEnd ? firstEnd : firstStart).CompareTo(secondUsesEnd ? secondEnd : secondStart);

    /// <summary>ITextRangeProvider.GetText: the range's text, cut to <paramref name="maxLength"/> when it is not negative.</summary>
    public static string GetText(IUiaTextSource source, int start, int end, int maxLength)
    {
        var text = source.Text;
        start = Math.Clamp(start, 0, text.Length);
        end = Math.Clamp(end, start, text.Length);
        var length = end - start;
        if (maxLength >= 0 && maxLength < length)
        {
            length = maxLength;
            // Never return half a surrogate pair.
            if (length > 0 && char.IsHighSurrogate(text[start + length - 1])) length--;
        }
        return text.Substring(start, length);
    }

    /// <summary>ITextRangeProvider.FindText within the range; returns the match as a range or null.</summary>
    public static (int Start, int End)? Find(IUiaTextSource source, int start, int end, string value, bool backward, bool ignoreCase)
    {
        if (value.Length == 0) return null;
        var text = source.Text;
        start = Math.Clamp(start, 0, text.Length);
        end = Math.Clamp(end, start, text.Length);
        var window = text.AsSpan(start, end - start);
        var comparison = ignoreCase ? StringComparison.CurrentCultureIgnoreCase : StringComparison.CurrentCulture;
        var index = backward ? window.LastIndexOf(value, comparison) : window.IndexOf(value, comparison);
        return index < 0 ? null : (start + index, start + index + value.Length);
    }

    // ---- unit boundaries ------------------------------------------------------------------------

    private static bool IsWhole(UiaUnit unit) => unit is UiaUnit.Document or UiaUnit.Page or UiaUnit.Format;

    /// <summary>Largest unit boundary at or before <paramref name="position"/>; at the end of the text, the start of the last unit.</summary>
    public static int UnitStart(IUiaTextSource source, UiaUnit unit, int position)
    {
        var text = source.Text;
        position = Math.Clamp(position, 0, text.Length);
        if (IsWhole(unit) || text.Length == 0) return 0;
        if (unit == UiaUnit.Character) return CharacterStart(text, position);
        if (position == text.Length) position--;
        return unit switch
        {
            UiaUnit.Word => WordToken(text, position).Start,
            UiaUnit.Line => LineStart(source, position),
            _ => ParagraphStart(text, position),
        };
    }

    /// <summary>End of the unit that holds the character at <paramref name="position"/>.</summary>
    public static int UnitEnd(IUiaTextSource source, UiaUnit unit, int position)
    {
        var length = source.Text.Length;
        if (IsWhole(unit) || position >= length) return length;
        return NextBoundary(source, unit, UnitStart(source, unit, position));
    }

    /// <summary>Smallest unit boundary strictly after <paramref name="position"/>, or the end of the text.</summary>
    public static int NextBoundary(IUiaTextSource source, UiaUnit unit, int position)
    {
        var text = source.Text;
        if (position >= text.Length || IsWhole(unit)) return text.Length;
        return unit switch
        {
            UiaUnit.Character => CharacterEnd(text, position),
            UiaUnit.Word => WordToken(text, position).End,
            UiaUnit.Line => NextLineStart(source, position),
            _ => ParagraphEnd(text, position),
        };
    }

    /// <summary>Largest unit boundary strictly before <paramref name="position"/>, or 0.</summary>
    public static int PreviousBoundary(IUiaTextSource source, UiaUnit unit, int position)
    {
        if (position <= 0 || IsWhole(unit)) return 0;
        var text = source.Text;
        position = Math.Min(position, text.Length);
        return unit switch
        {
            UiaUnit.Character => CharacterStart(text, position - 1),
            UiaUnit.Word => WordToken(text, position - 1).Start,
            UiaUnit.Line => LineStart(source, position - 1),
            _ => ParagraphStart(text, position - 1),
        };
    }

    // Character: text elements, so a surrogate pair, a CRLF or a base plus combining marks is one step.
    private static int CharacterStart(string text, int position)
    {
        if (position >= text.Length) return text.Length;
        // Elements never span a line break other than CRLF, so start walking from the line start.
        var i = position;
        while (i > 0 && text[i - 1] != '\n') i--;
        while (i < position)
        {
            var length = StringInfo.GetNextTextElementLength(text.AsSpan(i));
            if (i + length > position) return i;
            i += length;
        }
        return i;
    }

    private static int CharacterEnd(string text, int position)
    {
        var start = CharacterStart(text, position);
        return Math.Min(text.Length, start + Math.Max(1, StringInfo.GetNextTextElementLength(text.AsSpan(start))));
    }

    // Word: a run of letters/digits/underscore, or a run of other symbols, plus the blanks after it. Blanks that start
    // a line (indentation) are a word of their own; a line break (CRLF counted once) is a word of its own.
    private static (int Start, int End) WordToken(string text, int position)
    {
        var i = ParagraphStart(text, position);
        while (i < text.Length)
        {
            var start = i;
            if (IsBreak(text[i]))
                i += text[i] == '\r' && i + 1 < text.Length && text[i + 1] == '\n' ? 2 : 1;
            else
            {
                if (!IsBlank(text[i]))
                {
                    var kind = Kind(text[i]);
                    while (i < text.Length && !IsBlank(text[i]) && !IsBreak(text[i]) && Kind(text[i]) == kind) i++;
                }
                while (i < text.Length && IsBlank(text[i])) i++;
            }
            if (position < i) return (start, i);
        }
        return (text.Length, text.Length);
    }

    private static bool IsBlank(char c) => c is ' ' or '\t' or ' ';

    private static bool IsBreak(char c) => c is '\n' or '\r';

    private static int Kind(char c) => char.IsLetterOrDigit(c) || c == '_' ? 0 : 1;

    // Paragraph: logical lines.
    private static int ParagraphStart(string text, int position)
    {
        var i = Math.Min(position, text.Length);
        while (i > 0 && text[i - 1] is not ('\n' or '\r')) i--;
        return i;
    }

    private static int ParagraphEnd(string text, int position)
    {
        var i = position;
        while (i < text.Length && text[i] is not ('\n' or '\r')) i++;
        if (i < text.Length) i += text[i] == '\r' && i + 1 < text.Length && text[i + 1] == '\n' ? 2 : 1;
        return i;
    }

    // Line: visual lines when known, logical lines otherwise.
    private static int LineStart(IUiaTextSource source, int position)
    {
        var starts = source.VisualLineStarts;
        if (starts.Count == 0) return ParagraphStart(source.Text, position);
        var low = 0;
        var high = starts.Count - 1;
        while (low < high)
        {
            var mid = (low + high + 1) / 2;
            if (starts[mid] <= position) low = mid; else high = mid - 1;
        }
        return starts[low];
    }

    private static int NextLineStart(IUiaTextSource source, int position)
    {
        var starts = source.VisualLineStarts;
        if (starts.Count == 0) return ParagraphEnd(source.Text, position);
        foreach (var start in starts)
            if (start > position) return start;
        return source.Text.Length;
    }
}
