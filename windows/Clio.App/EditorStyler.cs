using Clio.Editor.Markdown;
using Microsoft.Graphics.Canvas.Text;
using Windows.UI;
using Windows.UI.Text;

namespace Clio.App;

/// <summary>
/// Maps Markdown highlight spans onto <see cref="CanvasTextLayout"/> attributes (macOS
/// <c>MarkdownTextKitHighlighter</c>). Presentation only: the layout text is never replaced.
/// </summary>
internal static class EditorStyler
{
    // Colours come from the current EditorPalette (Palette.swift values, or system colours in high contrast).
    public static Color Foreground => EditorTheme.ToColor(EditorTheme.Current.Foreground);
    public static Color Emphasis => EditorTheme.ToColor(EditorTheme.Current.Emphasis);
    public static Color Muted => EditorTheme.ToColor(EditorTheme.Current.Muted);
    public static Color Marker => EditorTheme.ToColor(EditorTheme.Current.Marker);
    public static Color Dimmed => EditorTheme.ToColor(EditorTheme.Current.Dimmed);
    public static Color Literal => EditorTheme.ToColor(EditorTheme.Current.Literal);
    public static Color Reference => EditorTheme.ToColor(EditorTheme.Current.Reference);
    public static Color Meta => EditorTheme.ToColor(EditorTheme.Current.Meta);

    private static readonly FontWeight Bold = new() { Weight = 700 };

    /// <summary>Spans must be ordered outer-first (<see cref="MarkdownHighlighter"/> guarantees this).</summary>
    public static void Apply(CanvasTextLayout layout, IReadOnlyList<MarkdownSpan> spans, int textLength, float baseSize)
    {
        foreach (var span in spans)
        {
            if (span.Start < 0 || span.Length <= 0 || span.End > textLength) continue;
            Apply(layout, span, baseSize);
        }
    }

    private static void Apply(CanvasTextLayout layout, MarkdownSpan span, float baseSize)
    {
        var (start, length) = (span.Start, span.Length);
        if (span.Role == SpanRole.CodeToken)
        {
            layout.SetColor(start, length, TokenColor(span.Token));
            return;
        }
        switch (span.Role)
        {
            case SpanRole.Marker or SpanRole.BlockRule: layout.SetColor(start, length, Marker); return;
            case SpanRole.Destination: layout.SetColor(start, length, Reference); return;
            case SpanRole.InfoString: layout.SetColor(start, length, Meta); return;
        }

        switch (span.Kind)
        {
            case SemanticKind.Heading:
                layout.SetFontSize(start, length, baseSize * ((span.Level ?? 6) switch { 1 => 1.65f, 2 => 1.4f, 3 => 1.2f, _ => 1f }));
                layout.SetFontWeight(start, length, Bold);
                layout.SetColor(start, length, Emphasis);
                break;
            case SemanticKind.Strong:
                layout.SetFontWeight(start, length, Bold);
                layout.SetColor(start, length, Emphasis);
                break;
            case SemanticKind.Emphasis:
                layout.SetFontStyle(start, length, FontStyle.Italic);
                break;
            case SemanticKind.Strikethrough:
                layout.SetStrikethrough(start, length, true);
                break;
            case SemanticKind.InlineCode or SemanticKind.CodeFence:
                layout.SetColor(start, length, Literal);
                break;
            case SemanticKind.Link or SemanticKind.Autolink:
                layout.SetColor(start, length, Reference);
                // High contrast: colour alone must not identify a link.
                if (EditorTheme.Current.IsHighContrast) layout.SetUnderline(start, length, true);
                break;
            case SemanticKind.FrontMatter or SemanticKind.Footnote or SemanticKind.Table:
                layout.SetColor(start, length, Meta);
                break;
            case SemanticKind.Blockquote:
                layout.SetColor(start, length, Muted);
                break;
        }
    }

    private static Color TokenColor(CodeTokenKind? token) => token switch
    {
        CodeTokenKind.Keyword or CodeTokenKind.Type => Meta,
        CodeTokenKind.String or CodeTokenKind.Number => Literal,
        CodeTokenKind.Comment => Muted,
        CodeTokenKind.Function or CodeTokenKind.Property => Reference,
        _ => Marker,
    };
}
