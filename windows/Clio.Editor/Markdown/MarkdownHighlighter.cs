namespace Clio.Editor.Markdown;

/// <summary>
/// Source-preserving Markdown highlighter (macOS <c>SourcePreservingMarkdownParser</c> presentation spans).
/// Pure logic: it returns styled ranges and never alters the text. Offsets are UTF-16 code units.
/// </summary>
public static class MarkdownHighlighter
{
    public const int ReducedHighlightLimit = 1_048_576;

    /// <summary>Chooses the presentation depth from the UTF-8 size (macOS <c>DocumentSizeMode</c>).</summary>
    public static HighlightMode ModeFor(long utf8ByteCount) =>
        utf8ByteCount <= FullByteLimit ? HighlightMode.Full
        : utf8ByteCount <= SafeLargeFileByteLimit ? HighlightMode.Reduced
        : HighlightMode.Unsupported;

    // PerformanceContract.fullMarkdownByteLimit / safeLargeFileByteLimit on macOS.
    internal const long FullByteLimit = 10L * 1024 * 1024;
    internal const long SafeLargeFileByteLimit = 50L * 1024 * 1024;

    public static IReadOnlyList<MarkdownSpan> Highlight(string source, HighlightMode mode = HighlightMode.Full, CancellationToken cancel = default)
    {
        if (mode == HighlightMode.Unsupported || source.Length == 0) return [];

        List<MarkdownSpan> spans;
        if (mode == HighlightMode.Reduced)
        {
            // Bounded prefix cut on a line boundary; no inline, table or code-token work.
            var cap = Math.Min(source.Length, ReducedHighlightLimit);
            if (cap < source.Length && char.IsLowSurrogate(source[cap])) cap--;
            var prefixEnd = cap;
            if (prefixEnd > 0)
            {
                var i = source.IndexOfAny(['\n', '\r'], prefixEnd - 1);
                prefixEnd = i < 0 ? source.Length : Math.Min(source.Length, i + (source[i] == '\r' && i + 1 < source.Length && source[i + 1] == '\n' ? 2 : 1));
            }
            spans = new MarkdownBlockLexer(source[..prefixEnd], HighlightMode.Reduced, ReducedHighlightLimit, cancel).Parse();
            return Normalize(spans.Where(s => !IsDelimiter(s.Kind)));
        }

        spans = new MarkdownBlockLexer(source, HighlightMode.Full, null, cancel).Parse();
        var combined = spans.Where(s => !IsDelimiter(s.Kind)).ToList();
        MarkdownDelimiters.Collect(source, combined, cancel);
        return Normalize(combined);
    }

    private static bool IsDelimiter(SemanticKind kind) =>
        kind is SemanticKind.Emphasis or SemanticKind.Strong or SemanticKind.Strikethrough;

    /// <summary>Deduplicate and order: earlier first, longer (outer) first, then role name.</summary>
    private static List<MarkdownSpan> Normalize(IEnumerable<MarkdownSpan> spans) =>
        [.. spans.Distinct().OrderBy(s => s.Start).ThenByDescending(s => s.Length).ThenBy(s => s.Role.ToString(), StringComparer.Ordinal)];
}
