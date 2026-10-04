using System.Text;
using System.Text.RegularExpressions;

namespace Clio.Editor.Markdown;

/// <summary>
/// Result of one highlight pass. <see cref="Spans"/> is always the complete canonical list;
/// <see cref="InvalidatedStart"/>/<see cref="InvalidatedLength"/> is what was re-lexed, so a caller that styles
/// incrementally restyles just that range. <see cref="ParsedLength"/> is how much source the pass lexed.
/// </summary>
public sealed record HighlightUpdate(HighlightMode Mode, int InvalidatedStart, int InvalidatedLength, IReadOnlyList<MarkdownSpan> Spans, int ParsedLength);

/// <summary>
/// Keeps highlighting incremental (macOS <c>IncrementalMarkdownHighlighter</c>) without making the incremental
/// state an integrity boundary: the result always equals <see cref="MarkdownHighlighter.Highlight"/> of the same
/// text. A single contiguous edit inside one block reparses only that block island; anything that could change
/// block structure, any discontinuous or unverifiable edit, and any change of presentation mode reparses everything.
/// Not thread-safe; callers serialise passes. A cancelled pass leaves the committed state untouched.
/// </summary>
public sealed partial class IncrementalHighlighter
{
    private string _source = "";
    private IReadOnlyList<MarkdownSpan> _spans = [];
    private HighlightMode _mode = HighlightMode.Full;
    private long _utf8Bytes;
    private bool _contextHazard;
    private bool _hasReferenceDefinitions;

    /// <summary>The text the committed spans describe.</summary>
    public string Source => _source;

    public void Reset()
    {
        _source = "";
        _spans = [];
        _mode = HighlightMode.Full;
        _utf8Bytes = 0;
        _contextHazard = false;
        _hasReferenceDefinitions = false;
    }

    /// <summary>Highlight <paramref name="newSource"/>, deriving the edit from the committed source.</summary>
    public HighlightUpdate Update(string newSource, CancellationToken cancel = default) =>
        Update(newSource, ContiguousEdit(_source, newSource), cancel);

    /// <summary>The smallest single replacement that turns <paramref name="oldText"/> into <paramref name="newText"/>.</summary>
    public static TextChange ContiguousEdit(string oldText, string newText)
    {
        var limit = Math.Min(oldText.Length, newText.Length);
        var prefix = oldText.AsSpan(0, limit).CommonPrefixLength(newText.AsSpan(0, limit));
        // Never split a surrogate pair: back up so the edit starts on a scalar boundary.
        if (prefix > 0 && char.IsHighSurrogate(oldText[prefix - 1])) prefix--;
        var suffixLimit = limit - prefix;
        var suffix = 0;
        while (suffix < suffixLimit && oldText[oldText.Length - 1 - suffix] == newText[newText.Length - 1 - suffix]) suffix++;
        if (suffix > 0 && char.IsLowSurrogate(oldText[oldText.Length - suffix])) suffix--;
        return new TextChange(prefix, oldText.Substring(prefix, oldText.Length - prefix - suffix), newText.Substring(prefix, newText.Length - prefix - suffix));
    }

    /// <summary>Highlight <paramref name="newSource"/> given the edit that produced it from <see cref="Source"/>; null means unknown.</summary>
    public HighlightUpdate Update(string newSource, TextChange? edit, CancellationToken cancel = default)
    {
        cancel.ThrowIfCancellationRequested();
        if (edit is { Removed.Length: 0, Inserted.Length: 0 } && newSource == _source)
            return new HighlightUpdate(_mode, 0, 0, _spans, 0);

        var continuous = edit is { } e && MarkdownIncrementalPolicy.IsContinuous(e, _source, newSource);
        var newBytes = continuous
            ? _utf8Bytes - Encoding.UTF8.GetByteCount(edit!.Value.Removed) + Encoding.UTF8.GetByteCount(edit.Value.Inserted)
            : Encoding.UTF8.GetByteCount(newSource);
        var newMode = MarkdownHighlighter.ModeFor(newBytes);

        if (newMode == HighlightMode.Unsupported)
        {
            Commit(newSource, newBytes, [], newMode);
            return new HighlightUpdate(newMode, 0, newSource.Length, [], 0);
        }

        if (edit is not { } change || _source.Length == 0 || _contextHazard || _mode != newMode || newMode != HighlightMode.Full || !continuous
            || MarkdownIncrementalPolicy.RequiresFullReparse(change, _source, newSource))
            return FullParse(newSource, newBytes, newMode, cancel);

        return Incremental(newSource, newBytes, change, cancel);
    }

    private HighlightUpdate FullParse(string newSource, long newBytes, HighlightMode mode, CancellationToken cancel)
    {
        var spans = MarkdownHighlighter.Highlight(newSource, mode, cancel);
        var parsed = mode == HighlightMode.Reduced ? Math.Min(newSource.Length, MarkdownHighlighter.ReducedHighlightLimit) : newSource.Length;
        var hazard = mode == HighlightMode.Full && FrontMatterOpensAFence(newSource, spans);
        Commit(newSource, newBytes, spans, mode);
        _contextHazard = hazard;
        _hasReferenceDefinitions = mode == HighlightMode.Full && ReferenceDefinition().IsMatch(newSource);
        return new HighlightUpdate(mode, 0, newSource.Length, spans, parsed);
    }

    /// <summary>
    /// Emphasis, strong and strikethrough come from a whole-document Markdig pass, and Markdig does not always
    /// agree with the block lexer about front matter. A fence marker inside front matter makes Markdig treat the
    /// rest of the document as code, which no island can see, so such a document is always reparsed in full.
    /// </summary>
    private static bool FrontMatterOpensAFence(string source, IReadOnlyList<MarkdownSpan> spans)
    {
        foreach (var span in spans)
        {
            if (span.Kind != SemanticKind.FrontMatter) continue;
            var text = source.AsSpan(span.Start, span.Length);
            foreach (var line in text.EnumerateLines())
            {
                var trimmed = line.TrimStart(' ');
                if (line.Length - trimmed.Length <= 3 && (trimmed.StartsWith("```", StringComparison.Ordinal) || trimmed.StartsWith("~~~", StringComparison.Ordinal)))
                    return true;
            }
        }
        return false;
    }

    /// <summary>
    /// Constructs that can span blank lines (a fence's body, front matter, a footnote definition) are not
    /// block islands: an island inside or beside one is parsed without its context, and an unclosed fence runs
    /// past the island. Deviation from macOS, whose policy only inspects the lines next to the edit.
    /// </summary>
    private bool TouchesMultiBlockConstruct(TextRange island)
    {
        foreach (var span in _spans)
            if (span.Kind is SemanticKind.CodeFence or SemanticKind.FrontMatter or SemanticKind.Footnote
                && span.Start <= island.End && span.End >= island.Start)
                return true;
        return false;
    }

    /// <summary>
    /// Link and footnote definitions (<c>[x]: url</c>) are document-wide: they decide how brackets pair up in
    /// every other paragraph, and with it where emphasis starts and stops. An island that holds a definition,
    /// or a bracket in a document that has any, cannot be parsed alone.
    /// </summary>
    private bool AffectsReferenceResolution(string source, TextRange island)
    {
        var text = source.AsSpan(island.Start, island.Length);
        return (_hasReferenceDefinitions && text.Contains('[')) || ReferenceDefinition().IsMatch(text);
    }

    [GeneratedRegex(@"^ {0,3}\[[^\]\r\n]+\]:", RegexOptions.Multiline)]
    private static partial Regex ReferenceDefinition();

    private HighlightUpdate Incremental(string newSource, long newBytes, TextChange edit, CancellationToken cancel)
    {
        var (oldRange, newRange) = MarkdownIncrementalPolicy.Invalidation(edit, _source, newSource);
        if (TouchesMultiBlockConstruct(oldRange) || TouchesMultiBlockConstruct(newRange)
            || MarkdownIncrementalPolicy.IsIndentedStart(_source, oldRange.Start) || MarkdownIncrementalPolicy.IsIndentedStart(newSource, newRange.Start))
            return FullParse(newSource, newBytes, HighlightMode.Full, cancel);
        if (AffectsReferenceResolution(_source, oldRange) | AffectsReferenceResolution(newSource, newRange))
            return FullParse(newSource, newBytes, HighlightMode.Full, cancel);
        var delta = edit.Inserted.Length - edit.Removed.Length;
        var mappedOld = Clamp(new TextRange(Math.Min(oldRange.Start, newSource.Length), Math.Max(0, oldRange.Length + delta)), newSource.Length);
        var fragment = Clamp(Union(newRange, mappedOld), newSource.Length);

        var fragmentSpans = MarkdownHighlighter.Highlight(newSource.Substring(fragment.Start, fragment.Length), HighlightMode.Full, cancel);

        var result = new List<MarkdownSpan>(_spans.Count + fragmentSpans.Count);
        var index = 0;
        foreach (var span in _spans)
        {
            if ((++index & 4095) == 0) cancel.ThrowIfCancellationRequested();
            if (span.End <= oldRange.Start) result.Add(span);
        }
        foreach (var span in fragmentSpans) result.Add(span with { Start = fragment.Start + span.Start });
        foreach (var span in _spans)
        {
            if (span.Start >= oldRange.End) result.Add(span with { Start = Math.Max(0, span.Start + delta) });
        }

        // Prefix, island and shifted suffix are each canonical and disjoint, so this is normally a no-op check.
        var spans = IsCanonical(result) ? result : MarkdownHighlighter.Normalize(result);
        Commit(newSource, newBytes, spans, HighlightMode.Full);
        return new HighlightUpdate(HighlightMode.Full, fragment.Start, fragment.Length, spans, fragment.Length);
    }

    private void Commit(string source, long bytes, IReadOnlyList<MarkdownSpan> spans, HighlightMode mode)
    {
        _source = source;
        _utf8Bytes = bytes;
        _spans = spans;
        _mode = mode;
    }

    private static bool IsCanonical(List<MarkdownSpan> spans)
    {
        for (var i = 1; i < spans.Count; i++)
        {
            var a = spans[i - 1];
            var b = spans[i];
            if (b.Start < a.Start) return false;
            if (b.Start == a.Start && (b.Length > a.Length || (b.Length == a.Length && string.CompareOrdinal(b.Role.ToString(), a.Role.ToString()) < 0))) return false;
            if (b == a) return false;
        }
        return true;
    }

    private static TextRange Union(TextRange a, TextRange b)
    {
        var start = Math.Min(a.Start, b.Start);
        return new TextRange(start, Math.Max(a.End, b.End) - start);
    }

    private static TextRange Clamp(TextRange range, int length)
    {
        var start = Math.Clamp(range.Start, 0, length);
        return new TextRange(start, Math.Clamp(range.Length, 0, length - start));
    }
}
