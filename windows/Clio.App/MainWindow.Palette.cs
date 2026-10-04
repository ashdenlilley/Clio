using Clio.Editor;
using Clio.Editor.Commands;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Clio.App;

/// <summary>Command palette hosting: Ctrl+K, the inline "/" trigger, and what each command does.</summary>
public sealed partial class MainWindow
{
    private TextRange _slashRange;

    private void InitPalette()
    {
        Editor.SlashTyped += OnSlashTyped;
        Editor.PaletteRequested += () => ShowPalette(CommandSource.KeyboardShortcut, null);
        Palette.InvocationChosen += Run;
        Palette.Palette.LiteralRestored += literal => Editor.RestoreLiteral(_slashRange, literal);
        Palette.Dismissed += () => Editor.Focus(FocusState.Programmatic);

        // Ctrl+K from anywhere, including the sidebar. The editor handles its own copy first.
        var accelerator = new KeyboardAccelerator { Key = VirtualKey.K, Modifiers = VirtualKeyModifiers.Control };
        accelerator.Invoked += (_, e) => { ShowPalette(CommandSource.KeyboardShortcut, null); e.Handled = true; };
        ((UIElement)Content).KeyboardAccelerators.Add(accelerator);
    }

    private void OnSlashTyped(SlashRequest request)
    {
        _slashRange = request.Replaced;
        Windows.Foundation.Rect? anchor = null;
        if (request.Anchor is { } local)
        {
            var origin = Editor.TransformToVisual(Palette).TransformPoint(new Windows.Foundation.Point(local.X, local.Y));
            anchor = new Windows.Foundation.Rect(origin.X, origin.Y, local.Width, local.Height);
        }
        ShowPalette(CommandSource.InlineSlash, anchor);
    }

    private void ShowPalette(CommandSource source, Windows.Foundation.Rect? anchor) => Palette.Show(source, "", anchor);

    private void Run(CommandInvocation invocation)
    {
        var refocus = true;
        switch (invocation.Command)
        {
            case CommandId.New: _ = NewDocumentAsync(); refocus = false; break;
            case CommandId.Open: _ = OpenFileAsync(); refocus = false; break;
            case CommandId.Folder: OnOpenFolder(this, null!); refocus = false; break;
            case CommandId.Reveal: RevealCurrent(); break;
            case CommandId.Rename: RunOnActive(RenameAsync); refocus = false; break;
            case CommandId.Delete: RunOnActive(DeleteAsync); refocus = false; break;
            case CommandId.Search: ShowSearch(SearchMode.Content, string.Join(' ', invocation.Arguments)); refocus = false; break;
            case CommandId.Settings: OpenSettings(); refocus = false; break;
            case CommandId.Focus: Status((Editor.FocusMode = !Editor.FocusMode) ? "Focus mode on" : "Focus mode off"); break;
            case CommandId.Typewriter: Status((Editor.TypewriterMode = !Editor.TypewriterMode) ? "Typewriter scrolling on" : "Typewriter scrolling off"); break;
            case CommandId.Sidebar: ToggleSidebar(); break;
            // Export arrives with phase 4.
            default: Status($"{invocation.Command.SlashName()} is not available yet"); break;
        }
        if (refocus) Editor.Focus(FocusState.Programmatic);
    }

    private void RunOnActive(Func<DocumentTab, Task> action)
    {
        if (_active is { } tab) _ = action(tab);
        else Status("Open a document first");
    }

    private void Status(string text) => SaveState.Text = text;

    private static void OpenSettings() => SettingsWindow.Show();

    private void ToggleSidebar()
    {
        var show = Sidebar.Visibility != Visibility.Visible;
        Sidebar.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        SidebarColumn.Width = new GridLength(show ? 240 : 0);
    }

    private void RevealCurrent()
    {
        if (_active?.Session.Path is not { } path) { Status("No file open to reveal"); return; }
        RevealPath(path);
    }
}
