using System.Text.RegularExpressions;

namespace Clio.Editor.Markdown;

/// <summary>
/// Port of macOS <c>MarkdownPresentationLexer</c>: line-based block lexer that emits marker-aware spans.
/// Emphasis, strong and strikethrough spans it produces are filtered out by <see cref="MarkdownHighlighter"/>.
/// </summary>
internal sealed class MarkdownBlockLexer
{
    private readonly MarkdownSource _map;
    private readonly HighlightMode _mode;
    private readonly int? _spanLimit;
    private readonly CancellationToken _cancel;
    private readonly List<MarkdownSpan> _spans = [];
    private int _line;

    private static readonly Regex Footnote = new(@"^ {0,3}\[\^([^\]\r\n]+)\]:[ \t]*(.*)$", RegexOptions.CultureInvariant);
    private static readonly Regex FootnoteStart = new(@"^ {0,3}\[\^[^\]]+\]:", RegexOptions.CultureInvariant);
    private static readonly Regex TableDelimiterCell = new(@"^:?-{3,}:?$", RegexOptions.CultureInvariant);
    private static readonly Regex ListMarker = new(@"^[ \t]*(?:([-+*])|([0-9]{1,9})[.)])(?=[ \t]+|$)", RegexOptions.CultureInvariant);
    private static readonly Regex QuoteMarker = new(@"^ {0,3}>", RegexOptions.CultureInvariant);
    private static readonly Regex AtxLike = new(@"^ {0,3}#{1,6}(?:[ \t]+|$)", RegexOptions.CultureInvariant);
    private static readonly Regex HtmlLine = new(@"^</?[A-Za-z][^>]*>$", RegexOptions.CultureInvariant);

    public MarkdownBlockLexer(string source, HighlightMode mode, int? spanLimit = null, CancellationToken cancel = default)
    {
        _map = new MarkdownSource(source);
        _mode = mode;
        _spanLimit = spanLimit;
        _cancel = cancel;
    }

    private IReadOnlyList<SourceLine> Lines => _map.Lines;

    public List<MarkdownSpan> Parse()
    {
        if (ParseFrontMatter()) _line++;
        while (_line < Lines.Count)
        {
            if (_line % 256 == 0) _cancel.ThrowIfCancellationRequested();
            if (Lines[_line].IsBlank) _line++;
            else if (ParseFence()) { }
            else if (ParseAtxHeading()) { }
            else if (ParseSetextHeading()) { }
            else if (ParseThematicBreak()) { }
            else if (ParseFootnoteDefinition()) { }
            else if (ParseTable()) { }
            else if (ParseList()) { }
            else if (ParseBlockquote()) { }
            else if (ParseRawHtml()) { }
            else ParseParagraph();
        }
        _cancel.ThrowIfCancellationRequested();
        return _spans;
    }

    private bool ParseFrontMatter()
    {
        if (Lines.Count <= 1 || Lines[0].Trimmed != "---") return false;
        int? closing = null;
        for (var i = 1; i < Lines.Count; i++)
            if (Lines[i].Trimmed is "---" or "...") { closing = i; break; }
        if (closing is not { } close) return false;
        Add(SemanticKind.FrontMatter, SpanRole.Marker, Lines[0].ContentStart, Lines[0].ContentLength);
        Add(SemanticKind.FrontMatter, SpanRole.Marker, Lines[close].ContentStart, Lines[close].ContentLength);
        if (close > 1)
            Add(SemanticKind.FrontMatter, SpanRole.Content, Lines[0].FullEnd, Lines[close].FullStart - Lines[0].FullEnd);
        _line = close;
        return true;
    }

    private bool ParseFence()
    {
        var openingLine = Lines[_line];
        if (openingLine.Fence is not { } opening) return false;
        int? closingIndex = null;
        for (var i = _line + 1; i < Lines.Count; i++)
        {
            if (Lines[i].Fence is { } c && c.Character == opening.Character && c.Count >= opening.Count && !c.HasInfo)
            {
                closingIndex = i;
                break;
            }
        }
        var last = closingIndex ?? (Lines.Count - 1);
        var rangeEnd = Lines[last].FullEnd;
        var bodyStart = openingLine.FullEnd;
        var bodyEnd = closingIndex is { } ci ? Lines[ci].FullStart : rangeEnd;
        var language = opening.HasInfo ? _map.Substring(opening.InfoStart, opening.InfoLength).Trim(' ', '\t') : null;

        Add(SemanticKind.CodeFence, SpanRole.Marker, opening.MarkerStart, opening.MarkerLength);
        if (opening.HasInfo) Add(SemanticKind.CodeFence, SpanRole.InfoString, opening.InfoStart, opening.InfoLength);
        if (closingIndex is { } ci2 && Lines[ci2].Fence is { } closing)
            Add(SemanticKind.CodeFence, SpanRole.Marker, closing.MarkerStart, closing.MarkerLength);
        var bodyLength = Math.Max(0, bodyEnd - bodyStart);
        if (bodyLength > 0)
        {
            Add(SemanticKind.CodeFence, SpanRole.Content, bodyStart, bodyLength);
            if (_mode == HighlightMode.Full)
                MarkdownCodeTokenizer.Tokenize(_map.Substring(bodyStart, bodyLength), bodyStart, language, _spans, _cancel);
        }
        _line = last + 1;
        return true;
    }

    private bool ParseAtxHeading()
    {
        var line = Lines[_line];
        var value = line.Text;
        var cursor = Math.Min(line.Indentation, value.Length);
        if (cursor > 3) return false;
        var markerStart = cursor;
        while (cursor < value.Length && value[cursor] == '#') cursor++;
        var level = cursor - markerStart;
        if (level is < 1 or > 6 || !(cursor == value.Length || IsWs(value[cursor]))) return false;
        Add(SemanticKind.Heading, SpanRole.Marker, line.ContentStart + markerStart, level, level);
        while (cursor < value.Length && IsWs(value[cursor])) cursor++;
        var end = value.Length;
        while (end > cursor && IsWs(value[end - 1])) end--;
        var closingStart = end;
        while (closingStart > cursor && value[closingStart - 1] == '#') closingStart--;
        if (closingStart < end && (closingStart == cursor || IsWs(value[closingStart - 1])))
        {
            Add(SemanticKind.Heading, SpanRole.Marker, line.ContentStart + closingStart, end - closingStart, level);
            end = closingStart;
            while (end > cursor && IsWs(value[end - 1])) end--;
        }
        var contentStart = line.ContentStart + cursor;
        var contentLength = Math.Max(0, end - cursor);
        ParseInline(contentStart, contentLength);
        Add(SemanticKind.Heading, SpanRole.Content, contentStart, contentLength, level);
        _line++;
        return true;
    }

    private bool ParseSetextHeading()
    {
        if (_line + 1 >= Lines.Count || Lines[_line].IsBlank || SetextLevel(Lines[_line + 1]) is not { } level) return false;
        var content = Lines[_line];
        var rule = Lines[_line + 1];
        ParseInline(content.ContentStart, content.ContentLength);
        Add(SemanticKind.Heading, SpanRole.Content, content.ContentStart, content.ContentLength, level);
        Add(SemanticKind.Heading, SpanRole.Marker, rule.ContentStart, rule.ContentLength, level);
        _line += 2;
        return true;
    }

    private static int? SetextLevel(SourceLine line)
    {
        var compact = line.Trimmed;
        if (compact.Length == 0 || line.Indentation > 3) return null;
        if (compact.All(c => c == '=')) return 1;
        if (compact.All(c => c == '-')) return 2;
        return null;
    }

    private bool ParseThematicBreak()
    {
        var line = Lines[_line];
        if (!IsThematic(line) || line.Indentation > 3) return false;
        Add(SemanticKind.ThematicBreak, SpanRole.BlockRule, line.ContentStart, line.ContentLength);
        _line++;
        return true;
    }

    private bool ParseFootnoteDefinition()
    {
        var line = Lines[_line];
        var m = Footnote.Match(line.Text);
        if (!m.Success) return false;
        var body = m.Groups[2];
        var markerLength = Math.Max(0, body.Index);
        var firstBodyStart = line.ContentStart + body.Index;
        var last = _line;
        while (last + 1 < Lines.Count)
        {
            var continuation = Lines[last + 1];
            if (continuation.IsBlank || continuation.Indentation < 4) break;
            last++;
        }
        var bodyLength = Lines[last].ContentEnd - firstBodyStart;
        Add(SemanticKind.Footnote, SpanRole.Marker, line.ContentStart, markerLength);
        Add(SemanticKind.Footnote, SpanRole.Content, firstBodyStart, bodyLength);
        ParseInline(firstBodyStart, bodyLength);
        _line = last + 1;
        return true;
    }

    private bool ParseTable()
    {
        if (_mode != HighlightMode.Full || _line + 1 >= Lines.Count) return false;
        var header = Lines[_line];
        var delimiter = Lines[_line + 1];
        if (!header.Text.Contains('|')) return false;
        var alignments = TableAlignmentCount(delimiter.Text);
        if (alignments == 0) return false;
        var headerCells = TableCells(header);
        if (headerCells.Count != alignments) return false;
        var rows = new List<List<(int Start, int Length)>>();
        var cursor = _line + 2;
        while (cursor < Lines.Count && !Lines[cursor].IsBlank && Lines[cursor].Text.Contains('|'))
        {
            var cells = TableCells(Lines[cursor]);
            if (cells.Count == 0) break;
            rows.Add(cells);
            cursor++;
        }
        foreach (var (start, length) in headerCells.Concat(rows.SelectMany(r => r)))
        {
            Add(SemanticKind.Table, SpanRole.Content, start, length);
            ParseInline(start, length);
        }
        foreach (var pipe in PipeOffsets(header)) Add(SemanticKind.Table, SpanRole.Marker, pipe, 1);
        foreach (var pipe in PipeOffsets(delimiter)) Add(SemanticKind.Table, SpanRole.Marker, pipe, 1);
        Add(SemanticKind.Table, SpanRole.BlockRule, delimiter.ContentStart, delimiter.ContentLength);
        for (var row = _line + 2; row < cursor; row++)
            foreach (var pipe in PipeOffsets(Lines[row])) Add(SemanticKind.Table, SpanRole.Marker, pipe, 1);
        _line = cursor;
        return true;
    }

    private static int TableAlignmentCount(string source)
    {
        var cells = SplitTableCells(source);
        if (cells.Count == 0) return 0;
        foreach (var raw in cells)
            if (!TableDelimiterCell.IsMatch(raw.Trim(' ', '\t'))) return 0;
        return cells.Count;
    }

    private static List<string> SplitTableCells(string source)
    {
        var cells = new List<string>();
        var current = new System.Text.StringBuilder();
        var escaped = false;
        var codeTicks = 0;
        foreach (var c in source)
        {
            if (c == '\\' && !escaped) { escaped = true; current.Append(c); continue; }
            if (c == '`' && !escaped) codeTicks = codeTicks == 0 ? 1 : 0;
            if (c == '|' && !escaped && codeTicks == 0) { cells.Add(current.ToString()); current.Clear(); }
            else current.Append(c);
            escaped = false;
        }
        cells.Add(current.ToString());
        if (cells[0].Trim(' ', '\t').Length == 0) cells.RemoveAt(0);
        if (cells.Count > 0 && cells[^1].Trim(' ', '\t').Length == 0) cells.RemoveAt(cells.Count - 1);
        return cells;
    }

    private static List<(int Start, int Length)> TableCells(SourceLine line)
    {
        var value = line.Text;
        var pipes = LocalPipes(value);
        var boundaries = new List<int> { -1 };
        boundaries.AddRange(pipes);
        boundaries.Add(value.Length);
        if (pipes.Count > 0 && pipes[0] == 0) boundaries.RemoveAt(0);
        if (pipes.Count > 0 && pipes[^1] == value.Length - 1) boundaries.RemoveAt(boundaries.Count - 1);
        var ranges = new List<(int, int)>();
        for (var i = 0; i + 1 < boundaries.Count; i++)
        {
            var start = boundaries[i] + 1;
            var end = boundaries[i + 1];
            while (start < end && IsWs(value[start])) start++;
            while (end > start && IsWs(value[end - 1])) end--;
            ranges.Add((line.ContentStart + start, end - start));
        }
        return ranges;
    }

    private static IEnumerable<int> PipeOffsets(SourceLine line) => LocalPipes(line.Text).Select(p => line.ContentStart + p);

    private static List<int> LocalPipes(string value)
    {
        var offsets = new List<int>();
        var escaped = false;
        var inCode = false;
        for (var i = 0; i < value.Length; i++)
        {
            var c = value[i];
            if (c == '\\' && !escaped) { escaped = true; continue; }
            if (c == '`' && !escaped) inCode = !inCode;
            if (c == '|' && !escaped && !inCode) offsets.Add(i);
            escaped = false;
        }
        return offsets;
    }

    private bool ParseList()
    {
        if (ListPrefix(Lines[_line]) is not { } first) return false;
        var ordered = first.Ordered;
        var cursor = _line;
        var items = 0;
        var kind = ordered ? SemanticKind.OrderedList : SemanticKind.UnorderedList;
        while (cursor < Lines.Count && ListPrefix(Lines[cursor]) is { } prefix && prefix.Ordered == ordered)
        {
            var line = Lines[cursor];
            Add(kind, SpanRole.Marker, prefix.Start, prefix.Length);
            var bodyStart = prefix.Start + prefix.Length;
            var lineEnd = line.ContentEnd;
            while (bodyStart < lineEnd && IsWs(_map.Text[bodyStart])) bodyStart++;
            if (lineEnd - bodyStart >= 3)
            {
                var candidate = _map.Text.Substring(bodyStart, 3).ToLowerInvariant();
                if (candidate is "[ ]" or "[x]")
                {
                    Add(SemanticKind.Task, SpanRole.Marker, bodyStart, 3);
                    bodyStart += 3;
                    while (bodyStart < lineEnd && IsWs(_map.Text[bodyStart])) bodyStart++;
                }
            }
            var bodyLength = Math.Max(0, lineEnd - bodyStart);
            ParseInline(bodyStart, bodyLength);
            Add(kind, SpanRole.Content, bodyStart, bodyLength);
            items++;
            cursor++;
        }
        if (items == 0) return false;
        _line = cursor;
        return true;
    }

    private static (int Start, int Length, bool Ordered)? ListPrefix(SourceLine line)
    {
        var m = ListMarker.Match(line.Text);
        if (!m.Success) return null;
        return (line.ContentStart + m.Index, m.Length, m.Groups[2].Success);
    }

    private bool ParseBlockquote()
    {
        if (QuotePrefix(Lines[_line]) is null) return false;
        var cursor = _line;
        while (cursor < Lines.Count && QuotePrefix(Lines[cursor]) is { } prefix)
        {
            var line = Lines[cursor];
            Add(SemanticKind.Blockquote, SpanRole.Marker, prefix.Start, prefix.Length);
            var contentStart = prefix.Start + prefix.Length;
            var end = line.ContentEnd;
            if (contentStart < end && IsWs(_map.Text[contentStart])) contentStart++;
            var length = Math.Max(0, end - contentStart);
            Add(SemanticKind.Blockquote, SpanRole.Content, contentStart, length);
            ParseInline(contentStart, length);
            cursor++;
        }
        _line = cursor;
        return true;
    }

    private static (int Start, int Length)? QuotePrefix(SourceLine line)
    {
        if (line.Indentation > 3) return null;
        var m = QuoteMarker.Match(line.Text);
        return m.Success ? (line.ContentStart + m.Index, m.Length) : null;
    }

    private bool ParseRawHtml()
    {
        var line = Lines[_line];
        var trimmed = line.Trimmed;
        if (_mode != HighlightMode.Full || !trimmed.StartsWith('<') || !trimmed.EndsWith('>') || !HtmlLine.IsMatch(trimmed)) return false;
        Add(SemanticKind.Paragraph, SpanRole.Content, line.ContentStart, line.ContentLength);
        _line++;
        return true;
    }

    private void ParseParagraph()
    {
        var start = _line;
        var cursor = _line + 1;
        while (cursor < Lines.Count && !Lines[cursor].IsBlank)
        {
            var l = Lines[cursor];
            if (l.Fence is not null || AtxLike.IsMatch(l.Text) || ListPrefix(l) is not null
                || QuotePrefix(l) is not null || FootnoteStart.IsMatch(l.Text) || IsThematic(l)) break;
            cursor++;
        }
        var end = cursor - 1;
        var contentStart = Lines[start].ContentStart;
        var length = Lines[end].ContentEnd - contentStart;
        ParseInline(contentStart, length);
        Add(SemanticKind.Paragraph, SpanRole.Content, contentStart, length);
        _line = cursor;
    }

    private static bool IsThematic(SourceLine line)
    {
        var compact = line.Text.Where(c => c is not (' ' or '\t')).ToArray();
        if (compact.Length < 3 || compact[0] is not ('*' or '-' or '_')) return false;
        return compact.All(c => c == compact[0]);
    }

    private void ParseInline(int start, int length)
    {
        if (_mode != HighlightMode.Full) return;
        new MarkdownMarkerLexer(_map.Text, start, length, _spans).Parse();
    }

    private void Add(SemanticKind kind, SpanRole role, int start, int length, int? level = null)
    {
        if (length <= 0) return;
        if (_spanLimit is { } limit)
        {
            if (start >= limit) return;
            length = Math.Min(length, limit - start);
            if (length <= 0) return;
        }
        _spans.Add(new MarkdownSpan(kind, role, start, length, level));
    }

    private static bool IsWs(char c) => c is ' ' or '\t';
}
