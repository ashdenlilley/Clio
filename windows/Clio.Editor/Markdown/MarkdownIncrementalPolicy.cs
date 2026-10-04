using System.Text.RegularExpressions;

namespace Clio.Editor.Markdown;

/// <summary>
/// Cheap edit validation and conservative structural invalidation (macOS <c>MarkdownIncrementalPolicy</c> and
/// <c>MarkdownInvalidationPlanner</c>). Lines are LF, CR or CRLF, the same model as <see cref="MarkdownSource"/>,
/// so an incremental pass sees exactly the blocks a full pass sees. Offsets are UTF-16 code units.
/// </summary>
internal static partial class MarkdownIncrementalPolicy
{
    private const int AnchorLength = 64;
    // macOS list plus '~': a typed "~~~" opens a fence, which the macOS policy would miss.
    private const string StructuralPunctuation = "`|#>=-+~";

    /// <summary>The edit really turns <paramref name="oldSource"/> into <paramref name="newSource"/> (checked at its edges, not by hashing).</summary>
    public static bool IsContinuous(TextChange edit, string oldSource, string newSource)
    {
        var start = edit.Start;
        var removed = edit.Removed.Length;
        if (start < 0 || start > oldSource.Length || removed > oldSource.Length - start) return false;
        if (oldSource.Length - removed + edit.Inserted.Length != newSource.Length) return false;
        if (!newSource.AsSpan(start, edit.Inserted.Length).SequenceEqual(edit.Inserted)) return false;
        if (!oldSource.AsSpan(start, removed).SequenceEqual(edit.Removed)) return false;

        var prefix = Math.Min(AnchorLength, start);
        if (!oldSource.AsSpan(start - prefix, prefix).SequenceEqual(newSource.AsSpan(start - prefix, prefix))) return false;

        var oldSuffixStart = start + removed;
        var newSuffixStart = start + edit.Inserted.Length;
        var suffix = Math.Min(AnchorLength, oldSource.Length - oldSuffixStart);
        return oldSource.AsSpan(oldSuffixStart, suffix).SequenceEqual(newSource.AsSpan(newSuffixStart, suffix));
    }

    /// <summary>True when the edit can change block structure beyond its own block island.</summary>
    public static bool RequiresFullReparse(TextChange edit, string oldSource, string newSource)
    {
        if (ContainsLineBreak(edit.Removed) || ContainsLineBreak(edit.Inserted)) return true;
        if (ContainsStructuralPunctuation(edit.Removed) || ContainsStructuralPunctuation(edit.Inserted)) return true;
        if (TouchesLeadingWhitespace(edit, oldSource)) return true;
        return Neighborhood(edit.Start, oldSource).Any(IsStructuralLine)
            || Neighborhood(edit.Start, newSource).Any(IsStructuralLine);
    }

    /// <summary>
    /// Indentation decides code versus list continuation versus paragraph, so an edit in a line's leading
    /// whitespace can change its meaning. Deviation from macOS. Typing the first character of an unindented
    /// line is not affected.
    /// </summary>
    private static bool TouchesLeadingWhitespace(TextChange edit, string oldSource)
    {
        if (oldSource.Length == 0) return false;
        var probe = Math.Min(edit.Start, oldSource.Length - 1);
        var lineStart = LineRangeAt(oldSource, probe).Start;
        var lead = 0;
        while (lineStart + lead < oldSource.Length && oldSource[lineStart + lead] is ' ' or '\t') lead++;
        if (edit.Start > lineStart + lead) return false;
        return lead > 0 || edit.Removed.AsSpan().IndexOfAny(' ', '\t') >= 0 || edit.Inserted.AsSpan().IndexOfAny(' ', '\t') >= 0;
    }

    /// <summary>
    /// An island whose first line is indented four columns or more is code on its own but may be a list
    /// continuation in context (and the reverse), so it cannot be parsed in isolation.
    /// </summary>
    public static bool IsIndentedStart(string source, int start)
    {
        if (start >= source.Length) return false;
        var columns = 0;
        for (var i = start; i < source.Length; i++)
        {
            if (source[i] == ' ') columns++;
            else if (source[i] == '\t') columns += 4;
            else break;
            if (columns >= 4) return true;
        }
        return false;
    }

    private static bool ContainsLineBreak(string value) => value.AsSpan().IndexOfAny('\n', '\r') >= 0;

    private static bool ContainsStructuralPunctuation(string value) => value.AsSpan().IndexOfAny(StructuralPunctuation) >= 0;

    /// <summary>The line holding <paramref name="offset"/> plus the line before and after it, split into lines.</summary>
    private static List<string> Neighborhood(int offset, string source)
    {
        if (source.Length == 0) return [""];
        var probe = Math.Clamp(Math.Min(offset, source.Length), 0, source.Length - 1);
        var (start, end) = LineRangeAt(source, probe);
        if (start > 0) start = LineRangeAt(source, start - 1).Start;
        if (end < source.Length) end = LineRangeAt(source, end).End;

        var lines = new List<string>();
        var position = start;
        while (position < end)
        {
            var lineEnd = position;
            while (lineEnd < end && !IsLineBreak(source[lineEnd])) lineEnd++;
            lines.Add(source[position..lineEnd]);
            position = lineEnd;
            if (position < end) position += source[position] == '\r' && position + 1 < end && source[position + 1] == '\n' ? 2 : 1;
        }
        if (lines.Count == 0 || IsLineBreak(source[end - 1])) lines.Add("");
        return lines;
    }

    private static bool IsStructuralLine(string line)
    {
        var trimmed = line.AsSpan().TrimStart(" \t");
        if (trimmed.IsEmpty) return false;
        if (trimmed.StartsWith("```", StringComparison.Ordinal) || trimmed.StartsWith("~~~", StringComparison.Ordinal)) return true;
        if (trimmed[0] is '>' or '#') return true;
        if (trimmed.StartsWith("---", StringComparison.Ordinal) || trimmed.StartsWith("===", StringComparison.Ordinal)) return true;
        if (trimmed.StartsWith("[^", StringComparison.Ordinal) && trimmed.Contains("]:", StringComparison.Ordinal)) return true;
        if (trimmed.Contains('|')) return true;
        return ListMarker().IsMatch(trimmed);
    }

    [GeneratedRegex(@"^([-+*]|\d+[.)])\s")]
    private static partial Regex ListMarker();

    // ---- invalidation planner -------------------------------------------------------------------

    /// <summary>The old and new ranges an edit invalidates, each widened to whole blank-line-delimited blocks.</summary>
    public static (TextRange Old, TextRange New) Invalidation(TextChange edit, string oldSource, string newSource)
    {
        var start = Math.Min(edit.Start, oldSource.Length);
        var removed = Math.Min(edit.Removed.Length, Math.Max(0, oldSource.Length - start));
        return (ExpandedBlockRange(start, removed, oldSource), ExpandedBlockRange(start, edit.Inserted.Length, newSource));
    }

    public static TextRange ExpandedBlockRange(int start, int length, string source)
    {
        if (source.Length == 0) return new TextRange(0, 0);
        var lowerProbe = Math.Min(start, source.Length - 1);
        var upperProbe = Math.Min(Math.Max(lowerProbe, start + length - 1), source.Length - 1);
        var lower = LineRangeAt(source, lowerProbe);
        var upper = LineRangeAt(source, upperProbe);

        while (lower.Start > 0)
        {
            var previous = LineRangeAt(source, lower.Start - 1);
            if (IsBlank(source, previous)) break;
            lower = previous;
        }
        while (upper.End < source.Length)
        {
            var next = LineRangeAt(source, upper.End);
            if (IsBlank(source, next)) break;
            upper = next;
        }
        return new TextRange(lower.Start, upper.End - lower.Start);
    }

    private static bool IsBlank(string source, (int Start, int End) line)
    {
        for (var i = line.Start; i < line.End; i++)
            if (source[i] is not (' ' or '\t' or '\n' or '\r')) return false;
        return true;
    }

    private static bool IsLineBreak(char c) => c is '\n' or '\r';

    /// <summary>Range of the line holding <paramref name="index"/>, terminator included; CRLF counts as one terminator.</summary>
    public static (int Start, int End) LineRangeAt(string source, int index)
    {
        var i = index;
        if (source[i] == '\n' && i > 0 && source[i - 1] == '\r') i--;
        var start = i;
        while (start > 0 && !IsLineBreak(source[start - 1])) start--;
        var end = i;
        while (end < source.Length && !IsLineBreak(source[end])) end++;
        if (end < source.Length) end += source[end] == '\r' && end + 1 < source.Length && source[end + 1] == '\n' ? 2 : 1;
        return (start, end);
    }
}
