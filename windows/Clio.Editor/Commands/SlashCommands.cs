using System.Text;

namespace Clio.Editor.Commands;

/// <summary>Command ids are a cross-platform contract (macOS <c>ClioCommandID</c>); the raw value is the slash name.</summary>
public enum CommandId
{
    New, Open, Search, Rename, Delete, Reveal, Folder, Export, Focus, Typewriter, Sidebar, Settings,
}

public static class CommandIds
{
    public static string RawValue(this CommandId id) => id.ToString().ToLowerInvariant();
    public static string SlashName(this CommandId id) => "/" + id.RawValue();

    public static bool TryParse(string raw, out CommandId id)
    {
        foreach (var candidate in Enum.GetValues<CommandId>())
            if (candidate.RawValue() == raw) { id = candidate; return true; }
        id = default;
        return false;
    }
}

public sealed record CommandInvocation(CommandId Command, IReadOnlyList<string> Arguments)
{
    public bool Equals(CommandInvocation? other) =>
        other is not null && Command == other.Command && Arguments.SequenceEqual(other.Arguments);

    public override int GetHashCode() => HashCode.Combine(Command, Arguments.Count);
}

public enum CommandParseErrorKind
{
    MissingSlash, MissingCommand, UnknownCommand, UnterminatedQuote, DanglingEscape, InvalidExportFormat, TooManyExportArguments,
}

public sealed class CommandParseException(CommandParseErrorKind kind, string? argument = null) : Exception(Describe(kind, argument))
{
    public CommandParseErrorKind Kind { get; } = kind;
    public string? Argument { get; } = argument;

    private static string Describe(CommandParseErrorKind kind, string? argument) => kind switch
    {
        CommandParseErrorKind.MissingSlash => "Commands begin with /.",
        CommandParseErrorKind.MissingCommand => "Type a command after /.",
        CommandParseErrorKind.UnknownCommand => $"Unknown command: /{argument}",
        CommandParseErrorKind.UnterminatedQuote => "Close the quoted argument before running this command.",
        CommandParseErrorKind.DanglingEscape => "An argument cannot end with an escape character.",
        CommandParseErrorKind.InvalidExportFormat => $"Unsupported export format “{argument}”. Use pdf, html, docx or txt.",
        CommandParseErrorKind.TooManyExportArguments => "Export accepts one format: pdf, html, docx or txt.",
        _ => "Invalid command.",
    };
}

/// <summary>Port of macOS <c>ClioCommandParser</c>.</summary>
public static class CommandParser
{
    private static readonly string[] ExportFormats = ["pdf", "html", "docx", "txt"];

    /// <summary>First, possibly partial command token for palette filtering; argument text is excluded.</summary>
    public static string CommandToken(string source)
    {
        var trimmed = source.Trim();
        var start = trimmed.Length > 0 && trimmed[0] == '/' ? 1 : 0;
        var end = start;
        while (end < trimmed.Length && !char.IsWhiteSpace(trimmed[end])) end++;
        return trimmed[start..end];
    }

    public static CommandInvocation Parse(string source)
    {
        var trimmed = source.Trim();
        if (trimmed.Length == 0 || trimmed[0] != '/') throw new CommandParseException(CommandParseErrorKind.MissingSlash);
        var tokens = Tokenize(trimmed[1..]);
        if (tokens.Count == 0 || tokens[0].Length == 0) throw new CommandParseException(CommandParseErrorKind.MissingCommand);
        if (!CommandIds.TryParse(tokens[0].ToLowerInvariant(), out var command))
            throw new CommandParseException(CommandParseErrorKind.UnknownCommand, tokens[0]);

        var arguments = tokens.Skip(1).ToList();
        if (command == CommandId.Export)
        {
            if (arguments.Count > 1) throw new CommandParseException(CommandParseErrorKind.TooManyExportArguments);
            if (arguments.Count == 1 && !ExportFormats.Contains(arguments[0].ToLowerInvariant()))
                throw new CommandParseException(CommandParseErrorKind.InvalidExportFormat, arguments[0]);
        }
        return new CommandInvocation(command, arguments);
    }

    private enum Quote { None, Single, Double }

    private static List<string> Tokenize(string source)
    {
        var tokens = new List<string>();
        var token = new StringBuilder();
        var quote = Quote.None;
        var escaping = false;
        var hasToken = false;

        foreach (var ch in source)
        {
            if (escaping) { token.Append(ch); hasToken = true; escaping = false; continue; }
            if (ch == '\\' && quote != Quote.Single) { escaping = true; hasToken = true; continue; }
            switch (quote, ch)
            {
                case (Quote.Single, '\''):
                case (Quote.Double, '"'):
                    quote = Quote.None;
                    break;
                case (Quote.None, '\''):
                    quote = Quote.Single; hasToken = true;
                    break;
                case (Quote.None, '"'):
                    quote = Quote.Double; hasToken = true;
                    break;
                case (Quote.None, _) when char.IsWhiteSpace(ch):
                    if (hasToken) { tokens.Add(token.ToString()); token.Clear(); hasToken = false; }
                    break;
                default:
                    token.Append(ch); hasToken = true;
                    break;
            }
        }
        if (escaping) throw new CommandParseException(CommandParseErrorKind.DanglingEscape);
        if (quote != Quote.None) throw new CommandParseException(CommandParseErrorKind.UnterminatedQuote);
        if (hasToken) tokens.Add(token.ToString());
        return tokens;
    }
}

/// <summary>
/// Palette row for a command. Ids and order match macOS <c>ClioCommandDescriptor.all</c>; only the
/// platform-specific wording (Explorer, Recycle Bin, folders) differs. Shared filter vectors avoid those words.
/// </summary>
public sealed record CommandDescriptor(CommandId Command, string Title, string Detail, string Glyph)
{
    /// <summary>Glyphs are Segoe Fluent Icons code points.</summary>
    public static IReadOnlyList<CommandDescriptor> All { get; } =
    [
        new(CommandId.New, "New Document", "Open a blank tab", ""),
        new(CommandId.Open, "Open…", "Choose a Markdown or text file", ""),
        new(CommandId.Search, "Search Workspaces", "Search every workspace folder", ""),
        new(CommandId.Rename, "Rename Document", "Rename the current file", ""),
        new(CommandId.Delete, "Move Document to Recycle Bin", "Delete the current file safely", ""),
        new(CommandId.Reveal, "Reveal in File Explorer", "Show the current file", ""),
        new(CommandId.Folder, "Add Workspace Folder…", "Add another searchable folder", ""),
        new(CommandId.Export, "Export…", "Export the current document", ""),
        new(CommandId.Focus, "Toggle Focus Mode", "Dim text away from the caret", ""),
        new(CommandId.Typewriter, "Toggle Typewriter Scrolling", "Keep the caret near its anchor", ""),
        new(CommandId.Sidebar, "Toggle Sidebar", "Show or hide navigation", ""),
        new(CommandId.Settings, "Settings…", "Configure the writing workspace", ""),
    ];

    /// <summary>The palette's substring match over id, title and detail; an empty needle lists everything.</summary>
    public static IReadOnlyList<CommandDescriptor> Filter(string needle)
    {
        if (needle.Length == 0) return All;
        const StringComparison cmp = StringComparison.InvariantCultureIgnoreCase;
        return [.. All.Where(d => d.Command.RawValue().Contains(needle, cmp) || d.Title.Contains(needle, cmp) || d.Detail.Contains(needle, cmp))];
    }
}
