using System.Globalization;
using System.Text.RegularExpressions;

namespace Clio.Editor;

public readonly record struct TextRange(int Start, int Length)
{
    public int End => Start + Length;
    public static TextRange Union(TextRange first, TextRange last) => new(first.Start, last.End - first.Start);
}

/// <summary>
/// Port of macOS <c>FocusDimmer.focusRange</c>. Returns the "unit of thought" holding the selection,
/// or <c>null</c> when focus mode must be suppressed: the selection crosses units, or the caret is on a
/// blank line (otherwise the whole screen would dim). Offsets are UTF-16 code units, like NSString.
/// Contract: spec/vectors/focus-ranges.json.
/// </summary>
public static partial class FocusUnit
{
    /// <summary>Bounds synchronous discovery when a pathological document has no nearby boundary.</summary>
    public const int MaximumSynchronousScanLength = 64 * 1024;

    public static TextRange? FocusRange(string source, TextRange selection)
    {
        if (source.Length == 0) return new TextRange(0, 0);
        var start = Math.Min(selection.Start, source.Length);
        var end = selection.Length == 0
            ? start
            : Math.Min(Math.Max(start, selection.End - 1), source.Length);
        var first = UnitRange(start, source);
        var last = UnitRange(end, source);
        if (first != last) return null;
        return Line.At(first.Start, source).IsBlank ? null : first;
    }

    private static TextRange UnitRange(int offset, string source)
    {
        if (FencedBlock(offset, source) is { } fenced) return fenced;

        var current = Line.At(offset, source);
        if (current.IsBlank || current.IsHeading || current.IsThematicBreak || current.FenceMarker is not null)
            return current.Range;
        if (current.IsListItem)
            return Contiguous(current, source, l => !l.IsBlank && (l.IsListItem || l.IsIndentedContinuation));
        if (current.IsBlockquote)
            return Contiguous(current, source, l => l.IsBlockquote);
        return Contiguous(current, source, l =>
            !l.IsBlank && !l.IsListItem && !l.IsBlockquote && !l.IsHeading && !l.IsThematicBreak && l.FenceMarker is null);
    }

    private static TextRange? FencedBlock(int offset, string source)
    {
        var target = Line.At(offset, source);
        var scanStart = Math.Max(0, target.Range.Start - MaximumSynchronousScanLength);
        var cursor = scanStart == 0 ? 0 : Line.At(scanStart, source).Range.Start;
        (Line Line, Fence Marker)? opening = null;

        while (cursor <= target.Range.Start && cursor < source.Length)
        {
            var line = Line.At(cursor, source);
            if (line.FenceMarker is { } marker)
            {
                if (opening is { } active && marker.Character == active.Marker.Character
                    && marker.Count >= active.Marker.Count && !marker.HasInfoString)
                {
                    if (target.Range.Start <= line.Range.Start) return TextRange.Union(active.Line.Range, line.Range);
                    opening = null;
                }
                else if (opening is null)
                {
                    opening = (line, marker);
                }
            }
            var next = line.Range.End;
            if (next <= cursor) break;
            cursor = next;
        }

        if (opening is not { } open || target.Range.Start < open.Line.Range.Start) return null;
        var scanEnd = Math.Min(source.Length, target.Range.Start + MaximumSynchronousScanLength);
        cursor = Math.Max(target.Range.End, open.Line.Range.End);
        while (cursor < scanEnd)
        {
            var line = Line.At(cursor, source);
            if (line.FenceMarker is { } marker && marker.Character == open.Marker.Character
                && marker.Count >= open.Marker.Count && !marker.HasInfoString)
                return TextRange.Union(open.Line.Range, line.Range);
            var next = line.Range.End;
            if (next <= cursor) break;
            cursor = next;
        }
        var boundedEnd = Math.Min(source.Length, Math.Max(target.Range.End, scanEnd));
        return new TextRange(open.Line.Range.Start, boundedEnd - open.Line.Range.Start);
    }

    private static TextRange Contiguous(Line current, string source, Func<Line, bool> includes)
    {
        var lowerBound = Math.Max(0, current.Range.Start - MaximumSynchronousScanLength);
        var upperBound = Math.Min(source.Length, current.Range.End + MaximumSynchronousScanLength);
        var lower = current.Range.Start;
        var upper = current.Range.End;
        while (lower > lowerBound)
        {
            var previous = Line.At(lower - 1, source);
            if (!includes(previous)) break;
            lower = previous.Range.Start;
        }
        while (upper < upperBound)
        {
            var next = Line.At(upper, source);
            if (!includes(next)) break;
            var nextUpper = next.Range.End;
            if (nextUpper <= upper) break;
            upper = nextUpper;
        }
        return new TextRange(lower, upper - lower);
    }

    internal readonly record struct Fence(char Character, int Count, bool HasInfoString);

    internal readonly partial record struct Line(TextRange Range, string Content)
    {
        /// <summary>Line containing <paramref name="offset"/>, terminator included in <see cref="Range"/>.</summary>
        public static Line At(int offset, string source)
        {
            if (source.Length == 0) return new Line(new TextRange(0, 0), "");
            if (offset >= source.Length) return new Line(new TextRange(source.Length, 0), "");
            var i = Math.Min(Math.Max(0, offset), source.Length - 1);
            // The \n of a \r\n pair belongs to the same terminator as its \r.
            if (source[i] == '\n' && i > 0 && source[i - 1] == '\r') i--;
            var start = i;
            while (start > 0 && source[start - 1] is not ('\n' or '\r')) start--;
            var contentEnd = i;
            while (contentEnd < source.Length && source[contentEnd] is not ('\n' or '\r')) contentEnd++;
            var end = contentEnd;
            if (end < source.Length)
            {
                end += source[end] == '\r' && end + 1 < source.Length && source[end + 1] == '\n' ? 2 : 1;
            }
            return new Line(new TextRange(start, end - start), source[start..contentEnd]);
        }

        private string Trimmed => Content.Trim(' ', '\t');
        public bool IsBlank => Content.All(IsHorizontalSpace);
        public bool IsListItem => ListRegex().IsMatch(Content);
        public bool IsIndentedContinuation => !IsBlank && (Content.StartsWith("  ", StringComparison.Ordinal) || Content.StartsWith('\t'));
        public bool IsBlockquote => BlockquoteRegex().IsMatch(Content);
        public bool IsHeading => HeadingRegex().IsMatch(Content);

        public bool IsThematicBreak
        {
            get
            {
                var compact = Trimmed.Replace(" ", "");
                return compact.Length >= 3 && compact[0] is '-' or '*' or '_' && compact.All(c => c == compact[0]);
            }
        }

        public Fence? FenceMarker
        {
            get
            {
                var indent = Content.Length - Content.TrimStart(' ').Length;
                if (indent > 3 || indent >= Content.Length) return null;
                var first = Content[indent];
                if (first is not ('`' or '~')) return null;
                var count = 0;
                while (indent + count < Content.Length && Content[indent + count] == first) count++;
                if (count < 3) return null;
                var hasInfo = Content[(indent + count)..].Any(c => !char.IsWhiteSpace(c));
                return new Fence(first, count, hasInfo);
            }
        }

        private static bool IsHorizontalSpace(char c) =>
            c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

        [GeneratedRegex(@"^\s*(?:[-+*]|\d+[.)])\s+")] private static partial Regex ListRegex();
        [GeneratedRegex(@"^\s{0,3}>")] private static partial Regex BlockquoteRegex();
        [GeneratedRegex(@"^\s{0,3}#{1,6}(?:\s|$)")] private static partial Regex HeadingRegex();
    }
}
