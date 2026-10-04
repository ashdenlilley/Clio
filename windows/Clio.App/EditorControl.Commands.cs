using Clio.Editor;
using Clio.Editor.Commands;
using Microsoft.UI.Xaml;

namespace Clio.App;

/// <summary>A "/" typed in the document. <see cref="Anchor"/> is set only on an empty line, in this control's coordinates.</summary>
public readonly record struct SlashRequest(TextRange Replaced, Windows.Foundation.Rect? Anchor);

/// <summary>Slash command trigger and Ctrl+K hooks (macOS <c>EditorCoordinator.textView(_:shouldChangeTextIn:)</c>).</summary>
public sealed partial class EditorControl
{
    /// <summary>When off, "/" is always a literal slash (macOS "Slash command palette" setting).</summary>
    public bool SlashEnabled { get; set; } = true;

    /// <summary>Raised instead of inserting a typed "/". The handler owns the palette and later calls <see cref="RestoreLiteral"/> if cancelled.</summary>
    public event Action<SlashRequest>? SlashTyped;

    /// <summary>Ctrl+K.</summary>
    public event Action? PaletteRequested;

    /// <summary>Returns true when the "/" was routed to the palette and must not be inserted.</summary>
    private bool TryRaiseSlash(string typed, bool fromComposition)
    {
        if (fromComposition || !SlashEnabled || SlashTyped is null || typed != "/") return false;
        var sel = Model.Selection;
        if (!SlashTrigger.IsInlineSlashTrigger(Model.Buffer.Text, sel.Start, sel.Length, typed)) return false;

        Windows.Foundation.Rect? anchor = null;
        if (SlashTrigger.IsEmptySlashLine(Model.Buffer.Text, sel.Start, sel.Length))
        {
            var caret = CaretRect(DisplayCaret);
            anchor = new Windows.Foundation.Rect(Left + caret.X, DocPadding - _scroll + caret.Y, 1, LineHeight);
        }
        SlashTyped.Invoke(new SlashRequest(sel, anchor));
        return true;
    }

    private void RaisePaletteRequested() => PaletteRequested?.Invoke();

    /// <summary>Put cancelled palette text back where the "/" was typed, with the caret after it.</summary>
    public void RestoreLiteral(TextRange replaced, string literal)
    {
        var length = Model.Buffer.Length;
        var start = Math.Clamp(replaced.Start, 0, length);
        var end = Math.Clamp(replaced.End, start, length);
        Model.SetSelection(start, end);
        Model.Insert(literal);
    }
}
