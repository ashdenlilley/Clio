namespace Clio.Editor.Markdown;

internal readonly record struct Fence(char Character, int Count, int MarkerStart, int MarkerLength, int InfoStart, int InfoLength)
{
    public bool HasInfo => InfoLength > 0;
}

/// <summary>One source line. Ranges are absolute UTF-16 offsets; content excludes the terminator.</summary>
internal sealed class SourceLine(int fullStart, int fullLength, int contentStart, string text)
{
    public int FullStart { get; } = fullStart;
    public int FullLength { get; } = fullLength;
    public int FullEnd => FullStart + FullLength;
    public int ContentStart { get; } = contentStart;
    public int ContentLength => Text.Length;
    public int ContentEnd => ContentStart + Text.Length;
    public string Text { get; } = text;

    public string Trimmed => Text.Trim(' ', '\t');
    public bool IsBlank => Trimmed.Length == 0;

    public int Indentation
    {
        get
        {
            var count = 0;
            foreach (var c in Text) { if (c != ' ') break; count++; }
            return count;
        }
    }

    public Fence? Fence
    {
        get
        {
            var indent = Math.Min(Indentation, Text.Length);
            if (indent > 3 || Text.Length - indent < 3) return null;
            var ch = Text[indent];
            if (ch is not ('`' or '~')) return null;
            var count = 0;
            while (indent + count < Text.Length && Text[indent + count] == ch) count++;
            if (count < 3) return null;
            var infoStart = indent + count;
            while (infoStart < Text.Length && Text[infoStart] is ' ' or '\t') infoStart++;
            var hasInfo = infoStart < Text.Length;
            return new Fence(ch, count, ContentStart + indent, count,
                hasInfo ? ContentStart + infoStart : 0, hasInfo ? Text.Length - infoStart : 0);
        }
    }
}

/// <summary>
/// Line index over the source (port of macOS <c>MarkdownSource</c>). Terminators are LF, CR and CRLF; the
/// Foundation line-separator extras (U+0085, U+2028, U+2029) are deliberately not line breaks here, matching
/// the editor's own line model.
/// </summary>
internal sealed class MarkdownSource
{
    public string Text { get; }
    public int Length => Text.Length;
    public IReadOnlyList<SourceLine> Lines { get; }

    public MarkdownSource(string text)
    {
        Text = text;
        var lines = new List<SourceLine>();
        if (text.Length == 0)
        {
            lines.Add(new SourceLine(0, 0, 0, ""));
            Lines = lines;
            return;
        }
        var location = 0;
        while (location < text.Length)
        {
            var end = location;
            while (end < text.Length && text[end] is not ('\n' or '\r')) end++;
            var next = end;
            if (next < text.Length) next += text[next] == '\r' && next + 1 < text.Length && text[next + 1] == '\n' ? 2 : 1;
            lines.Add(new SourceLine(location, next - location, location, text[location..end]));
            location = next;
        }
        Lines = lines;
    }

    public string Substring(int start, int length)
    {
        var s = Math.Clamp(start, 0, Length);
        var l = Math.Clamp(length, 0, Length - s);
        return Text.Substring(s, l);
    }
}
