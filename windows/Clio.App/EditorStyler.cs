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
    // Palette.swift; the system colours are the macOS dark-appearance values.
    public static readonly Color Foreground = Rgb(0xD4D4D4);
    public static readonly Color Emphasis = Rgb(0xF0F0F0);
    public static readonly Color Muted = Rgb(0x6E6E6E);
    public static readonly Color Marker = Rgb(0x4A4A4A);
    public static readonly Color Dimmed = Rgb(0x3A3A3A);
    public static readonly Color Literal = Rgb(0x30D158);
    public static readonly Color Reference = Rgb(0x0A84FF);
    public static readonly Color Meta = Rgb(0xBF5AF2);

    private static readonly FontWeight Bold = new() { Weight = 700 };

    private static Color Rgb(int value) => Color.FromArgb(255, (byte)(value >> 16), (byte)(value >> 8), (byte)value);

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
