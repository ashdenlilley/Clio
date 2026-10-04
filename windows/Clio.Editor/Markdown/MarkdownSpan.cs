namespace Clio.Editor.Markdown;

/// <summary>Mirrors macOS <c>MarkdownSemanticKind</c>.</summary>
public enum SemanticKind
{
    Heading, Paragraph, Emphasis, Strong, Strikethrough, UnorderedList, OrderedList, Task, Blockquote,
    InlineCode, CodeFence, Link, Autolink, Table, ThematicBreak, FrontMatter, Footnote, Marker,
}

/// <summary>Mirrors macOS <c>MarkdownSpanRole</c>; <see cref="CodeToken"/> carries the token kind.</summary>
public enum SpanRole { Marker, Content, Destination, InfoString, BlockRule, CodeToken }

/// <summary>Mirrors macOS <c>CodeTokenKind</c>.</summary>
public enum CodeTokenKind { Keyword, Type, String, Number, Comment, Function, Property, OperatorSymbol, Punctuation }

/// <summary>Presentation depth chosen from the document-size contract. The source is never transformed.</summary>
public enum HighlightMode { Full, Reduced, Unsupported }

/// <summary>A styled range of the untouched source. Offsets and lengths are UTF-16 code units.</summary>
public readonly record struct MarkdownSpan(
    SemanticKind Kind, SpanRole Role, int Start, int Length, int? Level = null, CodeTokenKind? Token = null)
{
    public int End => Start + Length;
}
