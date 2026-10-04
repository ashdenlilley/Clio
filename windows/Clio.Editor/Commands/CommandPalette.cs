namespace Clio.Editor.Commands;

public enum CommandSource { Menu, Dock, Palette, InlineSlash, KeyboardShortcut }

/// <summary>
/// Command palette state (macOS <c>EditorWindowSession</c> palette members, commands mode only; workspace
/// search mode arrives with phase 2). No UI: the app binds to <see cref="Changed"/>.
/// </summary>
public sealed class CommandPalette
{
    public bool IsPresented { get; private set; }
    public string Query { get; private set; } = "";
    public CommandSource Source { get; private set; } = CommandSource.Palette;
    public int SelectionIndex { get; private set; }
    public string? ErrorMessage { get; private set; }

    public event Action? Changed;

    /// <summary>Raised on dismissal with the literal text to put back in the document (inline "/" only).</summary>
    public event Action<string>? LiteralRestored;

    public IReadOnlyList<CommandDescriptor> Filtered => CommandDescriptor.Filter(CommandParser.CommandToken(Query));

    public void Present(CommandSource source = CommandSource.Palette, string query = "")
    {
        if (IsPresented) Dismiss();
        Source = source;
        Query = query;
        ErrorMessage = null;
        SelectionIndex = 0;
        IsPresented = true;
        Changed?.Invoke();
    }

    /// <summary>Typing "/" in a document: the palette opens with the slash as its query.</summary>
    public void PresentInlineSlash() => Present(CommandSource.InlineSlash, "/");

    public void Dismiss(bool preserveLiteral = true)
    {
        if (!IsPresented) return;
        var restores = Source == CommandSource.InlineSlash && preserveLiteral;
        IsPresented = false;
        // Restore after state flips so the caller can put focus back before inserting the literal.
        if (restores) LiteralRestored?.Invoke(Query.StartsWith('/') ? Query : "/" + Query);
        ErrorMessage = null;
        Changed?.Invoke();
    }

    public void UpdateQuery(string query)
    {
        // Two literal spaces escape an empty slash command. Whitespace within a real command stays input.
        if (IsPresented && Source == CommandSource.InlineSlash && query is "/  " or "  ")
        {
            Query = "/";
            Dismiss();
            return;
        }
        Query = query;
        ErrorMessage = null;
        SelectionIndex = 0;
        Changed?.Invoke();
    }

    public void Select(int index)
    {
        var count = Filtered.Count;
        SelectionIndex = count == 0 ? 0 : Math.Clamp(index, 0, count - 1);
        Changed?.Invoke();
    }

    public void MoveSelection(int offset) => Select(SelectionIndex + offset);

    public CommandInvocation InvocationFor(CommandId command)
    {
        var token = CommandParser.CommandToken(Query).ToLowerInvariant();
        if (token != command.RawValue()) return new CommandInvocation(command, []);
        var trimmed = Query.Trim();
        return CommandParser.Parse(trimmed.StartsWith('/') ? trimmed : "/" + trimmed);
    }

    /// <summary>Resolve the selected row into an invocation. A parse error is shown in the palette and returns null.</summary>
    public CommandInvocation? PerformSelected()
    {
        var filtered = Filtered;
        if (SelectionIndex < 0 || SelectionIndex >= filtered.Count) return null;
        try
        {
            var invocation = InvocationFor(filtered[SelectionIndex].Command);
            Dismiss(preserveLiteral: false);
            return invocation;
        }
        catch (CommandParseException ex)
        {
            ErrorMessage = ex.Message;
            Changed?.Invoke();
            return null;
        }
    }
}
