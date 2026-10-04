using Markdig;
using Markdig.Extensions.EmphasisExtras;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;

namespace Clio.Editor.Markdown;

/// <summary>
/// CommonMark/GFM emphasis, strong and strikethrough spans from Markdig. Plays the role swift-markdown plays
/// on macOS (<c>SwiftMarkdownSemanticParser.addDelimiterSpans</c>): delimiter flanking and nesting follow the
/// spec, and ranges are mapped back onto the untouched source.
/// </summary>
internal static class MarkdownDelimiters
{
    private static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .UsePreciseSourceLocation()
        .UseEmphasisExtras(EmphasisExtraOptions.Strikethrough)
        .UsePipeTables()
        .Build();

    public static void Collect(string source, List<MarkdownSpan> spans, CancellationToken cancel = default)
    {
        cancel.ThrowIfCancellationRequested();
        var document = Markdig.Markdown.Parse(source, Pipeline);
        cancel.ThrowIfCancellationRequested();
        foreach (var node in document.Descendants<EmphasisInline>())
        {
            var kind = node.DelimiterChar == '~' ? SemanticKind.Strikethrough
                : node.DelimiterCount >= 2 ? SemanticKind.Strong : SemanticKind.Emphasis;
            AddSpans(source, node, kind, spans);
        }
    }

    private static void AddSpans(string source, EmphasisInline node, SemanticKind kind, List<MarkdownSpan> spans)
    {
        var width = kind == SemanticKind.Emphasis ? 1 : 2;
        var start = node.Span.Start;
        var length = node.Span.Length;
        if (start < 0 || length <= 0 || start + length > source.Length) return;

        // Same-range ancestors are delimiters that wrap this node (for example *** is one emphasis around one
        // strong): inset by their widths so each node owns its own delimiter characters.
        var inset = 0;
        for (var parent = node.Parent; parent is EmphasisInline outer && outer.Span.Start == start && outer.Span.Length == length; parent = outer.Parent)
            inset += outer.DelimiterChar == '~' || outer.DelimiterCount >= 2 ? 2 : 1;

        var total = inset + width;
        if (length < total * 2) return;
        var opening = (Start: start + inset, Length: width);
        var closing = (Start: start + length - inset - width, Length: width);
        if (!Valid(source, opening.Start, width, kind) || !Valid(source, closing.Start, width, kind)) return;
        spans.Add(new MarkdownSpan(kind, SpanRole.Marker, opening.Start, width));
        spans.Add(new MarkdownSpan(kind, SpanRole.Marker, closing.Start, width));
        spans.Add(new MarkdownSpan(kind, SpanRole.Content, start + total, length - total * 2));
    }

    private static bool Valid(string source, int at, int width, SemanticKind kind)
    {
        var s = source.AsSpan(at, width);
        return kind switch
        {
            SemanticKind.Emphasis => s is "*" or "_",
            SemanticKind.Strong => s is "**" or "__",
            SemanticKind.Strikethrough => s is "~~",
            _ => false,
        };
    }
}
