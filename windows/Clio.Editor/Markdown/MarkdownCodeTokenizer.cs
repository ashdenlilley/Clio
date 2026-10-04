namespace Clio.Editor.Markdown;

/// <summary>
/// Port of macOS <c>MarkdownCodeTokenizer</c>: a small lexer that styles lexical tokens only. Malformed or
/// unknown languages stay fully editable source.
/// </summary>
internal static class MarkdownCodeTokenizer
{
    private static readonly string[] Common =
    [
        "as", "async", "await", "break", "case", "catch", "class", "continue",
        "default", "do", "else", "enum", "export", "extends", "false", "finally",
        "for", "from", "func", "function", "guard", "if", "import", "in", "interface",
        "let", "nil", "null", "private", "protocol", "public", "return", "self", "static",
        "struct", "switch", "throw", "throws", "true", "try", "typealias", "var", "while",
    ];

    private static readonly string[] HashLanguages = ["py", "python", "rb", "ruby", "sh", "bash", "zsh", "yaml", "yml"];

    public static void Tokenize(string source, int offset, string? language, List<MarkdownSpan> spans, CancellationToken cancel = default)
    {
        var (hashComments, keywords) = Dialect(language);
        var cursor = 0;
        void Add(CodeTokenKind kind, int start, int end) =>
            spans.Add(new MarkdownSpan(SemanticKind.CodeFence, SpanRole.CodeToken, offset + start, end - start, Token: kind));

        while (cursor < source.Length)
        {
            if (cursor % 4096 == 0) cancel.ThrowIfCancellationRequested();
            var c = source[cursor];
            if (IsSpace(c)) { cursor++; continue; }

            if (hashComments && c == '#')
            {
                var end = LineEnd(source, cursor);
                Add(CodeTokenKind.Comment, cursor, end); cursor = end; continue;
            }
            if (c == '/' && cursor + 1 < source.Length)
            {
                var next = source[cursor + 1];
                if (next == '/')
                {
                    var end = LineEnd(source, cursor);
                    Add(CodeTokenKind.Comment, cursor, end); cursor = end; continue;
                }
                if (next == '*')
                {
                    var end = cursor + 2;
                    while (end + 1 < source.Length && !(source[end] == '*' && source[end + 1] == '/')) end++;
                    end = Math.Min(source.Length, end + (end + 1 < source.Length ? 2 : 0));
                    Add(CodeTokenKind.Comment, cursor, end); cursor = end; continue;
                }
            }

            if (c is '"' or '\'' or '`')
            {
                var quote = c;
                var start = cursor;
                cursor++;
                var escaped = false;
                while (cursor < source.Length)
                {
                    var current = source[cursor++];
                    if (current == '\\' && !escaped) { escaped = true; continue; }
                    if (current == quote && !escaped) break;
                    escaped = false;
                }
                Add(CodeTokenKind.String, start, cursor); continue;
            }

            if (IsDigit(c))
            {
                var start = cursor++;
                while (cursor < source.Length)
                {
                    var current = source[cursor];
                    if (!(IsDigit(current) || current is '.' or '_' || current is >= 'A' and <= 'F' || current is >= 'a' and <= 'f')) break;
                    cursor++;
                }
                Add(CodeTokenKind.Number, start, cursor); continue;
            }

            if (IsIdentifierStart(c))
            {
                var start = cursor++;
                while (cursor < source.Length && IsIdentifierPart(source[cursor])) cursor++;
                var word = source[start..cursor];
                CodeTokenKind kind;
                if (keywords.Contains(word)) kind = CodeTokenKind.Keyword;
                else if (char.IsUpper(word[0])) kind = CodeTokenKind.Type;
                else if (PreviousNonSpace(source, start) == '.') kind = CodeTokenKind.Property;
                else if (NextNonSpace(source, cursor) == '(') kind = CodeTokenKind.Function;
                else continue;
                Add(kind, start, cursor); continue;
            }

            if (c is '(' or ')' or '[' or ']' or '{' or '}' or ',' or ';')
            {
                Add(CodeTokenKind.Punctuation, cursor, cursor + 1); cursor++; continue;
            }
            if ("+-*/%=!<>|&^~?:.".Contains(c))
            {
                Add(CodeTokenKind.OperatorSymbol, cursor, cursor + 1); cursor++; continue;
            }
            cursor++;
        }
    }

    private static (bool Hash, HashSet<string> Keywords) Dialect(string? raw)
    {
        var language = raw?.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToLowerInvariant() ?? "";
        var words = new HashSet<string>(Common);
        switch (language)
        {
            case "py" or "python": words.UnionWith(["def", "elif", "except", "lambda", "none", "pass", "with", "yield"]); break;
            case "rs" or "rust": words.UnionWith(["crate", "impl", "match", "mod", "mut", "pub", "trait", "unsafe"]); break;
            case "js" or "javascript" or "ts" or "typescript": words.UnionWith(["const", "new", "of", "this", "typeof", "undefined"]); break;
            case "swift": words.UnionWith(["actor", "associatedtype", "defer", "extension", "some", "where"]); break;
        }
        return (HashLanguages.Contains(language), words);
    }

    private static int LineEnd(string text, int start)
    {
        var cursor = start;
        while (cursor < text.Length && text[cursor] is not ('\n' or '\r')) cursor++;
        return cursor;
    }

    private static char? PreviousNonSpace(string text, int offset)
    {
        for (var i = offset - 1; i >= 0; i--) if (!IsSpace(text[i])) return text[i];
        return null;
    }

    private static char? NextNonSpace(string text, int offset)
    {
        for (var i = offset; i < text.Length; i++) if (!IsSpace(text[i])) return text[i];
        return null;
    }

    private static bool IsSpace(char c) => c is ' ' or '\t' or '\n' or '\r';
    private static bool IsDigit(char c) => c is >= '0' and <= '9';
    private static bool IsIdentifierStart(char c) => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or '_';
    private static bool IsIdentifierPart(char c) => IsIdentifierStart(c) || IsDigit(c);
}
