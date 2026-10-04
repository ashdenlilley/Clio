using System.Globalization;
using System.Text.RegularExpressions;

namespace Clio.Editor.Markdown;

/// <summary>
/// Port of macOS <c>MarkdownMarkerLexer</c>: inline source-marker lexer. It records spans only; the inline
/// semantic model is not needed for presentation. CommonMark emphasis flanking is decided by
/// <see cref="MarkdownDelimiters"/>, so the delimiter spans produced here are discarded by the highlighter
/// (the lexer still recurses into them so links and code inside emphasis are styled).
/// </summary>
internal sealed class MarkdownMarkerLexer(string source, int start, int length, List<MarkdownSpan> spans)
{
    private readonly int _start = Math.Clamp(start, 0, source.Length);
    private readonly int _end = Math.Clamp(start, 0, source.Length) + Math.Clamp(length, 0, source.Length - Math.Clamp(start, 0, source.Length));
    private int _cursor = Math.Clamp(start, 0, source.Length);

    private static readonly Regex NonLinkAngle = new(@"^/?[A-Za-z][^>]*$", RegexOptions.CultureInvariant);
    private static readonly Regex BareEmail = new(
        @"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+",
        RegexOptions.CultureInvariant);
    private static readonly Regex FullEmail = new(@"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$", RegexOptions.CultureInvariant);
    private static readonly Regex LinkTarget = new(@"^(?:<([^>]*)>|(\S+?))(?:[ \t]+[""'](.*)[""'])?$", RegexOptions.CultureInvariant);

    public void Parse()
    {
        while (_cursor < _end)
        {
            var c = source[_cursor];
            if (c == '\\' && _cursor + 1 < _end) { _cursor += 2; continue; }
            if (c is '\n' or '\r')
            {
                _cursor += c == '\r' && _cursor + 1 < _end && source[_cursor + 1] == '\n' ? 2 : 1;
                continue;
            }
            if (c == '`' && ParseCode()) continue;
            if (c == '!' && _cursor + 1 < _end && source[_cursor + 1] == '[' && ParseLink(isImage: true)) continue;
            if (c == '[')
            {
                if (ParseFootnote()) continue;
                if (ParseLink(isImage: false)) continue;
            }
            if (c == '<' && ParseAngle()) continue;
            if (c == '~' && HasMarker("~~", _cursor) && ParseDelimited("~~", SemanticKind.Strikethrough)) continue;
            if (c is '*' or '_')
            {
                var single = c.ToString();
                if (HasMarker(single + single, _cursor) && ParseDelimited(single + single, SemanticKind.Strong)) continue;
                if (ParseDelimited(single, SemanticKind.Emphasis)) continue;
            }
            if (StartsUrl(_cursor) && ParseBareUrl()) continue;
            if (IsEmailStart(_cursor) && ParseBareEmail()) continue;
            _cursor++;
        }
    }

    private bool ParseCode()
    {
        var count = 0;
        while (_cursor + count < _end && source[_cursor + count] == '`') count++;
        var marker = new string('`', count);
        var searchStart = _cursor + count;
        var closing = IndexOf(marker, searchStart);
        if (closing < 0) return false;
        Add(SemanticKind.InlineCode, SpanRole.Marker, _cursor, count);
        Add(SemanticKind.InlineCode, SpanRole.Content, _cursor + count, closing - (_cursor + count));
        Add(SemanticKind.InlineCode, SpanRole.Marker, closing, count);
        _cursor = closing + count;
        return true;
    }

    private bool ParseDelimited(string marker, SemanticKind kind)
    {
        var searchStart = _cursor + marker.Length;
        if (searchStart >= _end) return false;
        var closing = ClosingMarker(marker, searchStart);
        if (closing is null || closing <= searchStart) return false;
        // Intraword underscores are ordinary source.
        if (marker[0] == '_' && _cursor > _start && IsWord(source[_cursor - 1]) && IsWord(source[searchStart])) return false;

        var content = (Start: searchStart, Length: closing.Value - searchStart);
        Add(kind, SpanRole.Marker, _cursor, marker.Length);
        Add(kind, SpanRole.Content, content.Start, content.Length);
        new MarkdownMarkerLexer(source, content.Start, content.Length, spans).Parse();
        Add(kind, SpanRole.Marker, closing.Value, marker.Length);
        _cursor = closing.Value + marker.Length;
        return true;
    }

    private bool ParseFootnote()
    {
        if (!HasMarker("[^", _cursor)) return false;
        var closing = IndexOf("]", _cursor + 2);
        if (closing < 0 || closing <= _cursor + 2) return false;
        Add(SemanticKind.Footnote, SpanRole.Marker, _cursor, 2);
        Add(SemanticKind.Footnote, SpanRole.Content, _cursor + 2, closing - _cursor - 2);
        Add(SemanticKind.Footnote, SpanRole.Marker, closing, 1);
        _cursor = closing + 1;
        return true;
    }

    private bool ParseLink(bool isImage)
    {
        var opening = _cursor + (isImage ? 1 : 0);
        if (source[opening] != '[') return false;
        var bracket = Matching('[', ']', opening);
        if (bracket is null || bracket + 1 >= _end || source[bracket.Value + 1] != '(') return false;
        var paren = Matching('(', ')', bracket.Value + 1);
        if (paren is null) return false;

        var labelStart = opening + 1;
        var labelLength = bracket.Value - opening - 1;
        var targetStart = bracket.Value + 2;
        var target = source.Substring(targetStart, paren.Value - targetStart);
        var (destStart, destLength) = DestinationRange(target);

        Add(SemanticKind.Link, SpanRole.Marker, _cursor, isImage ? 2 : 1);
        Add(SemanticKind.Link, SpanRole.Content, labelStart, labelLength);
        Add(SemanticKind.Link, SpanRole.Marker, bracket.Value, 2);
        Add(SemanticKind.Link, SpanRole.Destination, targetStart + destStart, destLength);
        Add(SemanticKind.Link, SpanRole.Marker, paren.Value, 1);
        new MarkdownMarkerLexer(source, labelStart, labelLength, spans).Parse();
        _cursor = paren.Value + 1;
        return true;
    }

    private bool ParseAngle()
    {
        var close = IndexOf(">", _cursor + 1);
        if (close < 0) return false;
        var bodyStart = _cursor + 1;
        var body = source.Substring(bodyStart, close - bodyStart);
        var isLink = body.StartsWith("http://", StringComparison.Ordinal) || body.StartsWith("https://", StringComparison.Ordinal) || IsEmail(body);
        if (!isLink)
        {
            if (!NonLinkAngle.IsMatch(body)) return false;
            Add(SemanticKind.Paragraph, SpanRole.Marker, _cursor, close + 1 - _cursor);
            _cursor = close + 1;
            return true;
        }
        Add(SemanticKind.Autolink, SpanRole.Marker, _cursor, 1);
        Add(SemanticKind.Autolink, SpanRole.Destination, bodyStart, close - bodyStart);
        Add(SemanticKind.Autolink, SpanRole.Marker, close, 1);
        _cursor = close + 1;
        return true;
    }

    private bool ParseBareUrl()
    {
        var urlEnd = _cursor;
        while (urlEnd < _end && !char.IsWhiteSpace(source[urlEnd]) && source[urlEnd] is not ('<' or '>')) urlEnd++;
        while (urlEnd > _cursor && source[urlEnd - 1] is '.' or ',' or ':' or ';' or '!' or '?') urlEnd--;
        if (urlEnd <= _cursor) return false;
        Add(SemanticKind.Autolink, SpanRole.Destination, _cursor, urlEnd - _cursor);
        _cursor = urlEnd;
        return true;
    }

    private bool ParseBareEmail()
    {
        // Anchored with ^, so match against a slice that starts at the cursor.
        var match = BareEmail.Match(source.Substring(_cursor, _end - _cursor));
        if (!match.Success) return false;
        Add(SemanticKind.Autolink, SpanRole.Destination, _cursor + match.Index, match.Length);
        _cursor += match.Index + match.Length;
        return true;
    }

    private bool StartsUrl(int at) => HasMarker("https://", at) || HasMarker("http://", at) || HasMarker("www.", at);

    private bool IsEmailStart(int at)
    {
        if (!(at == _start || !IsWord(source[at - 1]))) return false;
        if (!IsWord(source[at])) return false;
        var end = Math.Min(_end, at + 320);
        var foundAt = false;
        var foundDot = false;
        for (var i = at; i < end; i++)
        {
            var c = source[i];
            if (char.IsWhiteSpace(c)) break;
            if (c == '@') foundAt = true;
            if (c == '.' && foundAt) foundDot = true;
        }
        return foundAt && foundDot;
    }

    private static bool IsEmail(string value) => FullEmail.IsMatch(value);

    /// <summary>Destination range inside a link target, relative to the target string.</summary>
    private static (int Start, int Length) DestinationRange(string target)
    {
        var lower = 0;
        var upper = target.Length;
        while (lower < upper && char.IsWhiteSpace(target[lower])) lower++;
        while (upper > lower && char.IsWhiteSpace(target[upper - 1])) upper--;
        var trimmed = target[lower..upper];
        var m = LinkTarget.Match(trimmed);
        if (!m.Success) return (lower, upper - lower);
        var group = m.Groups[1].Success ? m.Groups[1] : m.Groups[2];
        return (lower + group.Index, group.Length);
    }

    private int? Matching(char open, char close, int opening)
    {
        var depth = 0;
        var escaped = false;
        for (var i = opening; i < _end; i++)
        {
            var c = source[i];
            if (c == '\\' && !escaped) { escaped = true; continue; }
            if (!escaped)
            {
                if (c == open) depth++;
                if (c == close && --depth == 0) return i;
            }
            escaped = false;
        }
        return null;
    }

    private int IndexOf(string value, int from)
    {
        if (from >= _end) return -1;
        return source.IndexOf(value, from, _end - from, StringComparison.Ordinal);
    }

    private bool HasMarker(string marker, int at) =>
        at + marker.Length <= _end && string.CompareOrdinal(source, at, marker, 0, marker.Length) == 0;

    private int? ClosingMarker(string marker, int searchStart)
    {
        var from = searchStart;
        while (from < _end)
        {
            var found = source.IndexOf(marker, from, _end - from, StringComparison.Ordinal);
            if (found < 0) return null;
            var slashes = 0;
            var cursor = found;
            while (cursor > _start && source[cursor - 1] == '\\') { slashes++; cursor--; }
            if (slashes % 2 == 0) return found;
            from = found + marker.Length;
        }
        return null;
    }

    private void Add(SemanticKind kind, SpanRole role, int at, int len)
    {
        if (len > 0) spans.Add(new MarkdownSpan(kind, role, at, len));
    }

    internal static bool IsWord(char c) =>
        c == '_' || (!char.IsSurrogate(c) && (char.IsLetterOrDigit(c) || IsMark(c)));

    private static bool IsMark(char c) => CharUnicodeInfo.GetUnicodeCategory(c) is
        UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark;
}
