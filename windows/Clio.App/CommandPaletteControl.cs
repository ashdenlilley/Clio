using Clio.Editor.Commands;
using Clio.Intelligence;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Clio.App;

/// <summary>
/// Overlay for <see cref="CommandPalette"/>: query box over a list of commands, anchored under an empty-line
/// slash or centred (macOS <c>CommandPaletteView</c>). The palette model owns the literal behaviour; this renders it and,
/// only where the literal filter finds nothing and assisted commands are on, shows an assisted match in its place.
/// </summary>
public sealed class CommandPaletteControl : UserControl
{
    private const double CenteredWidth = 620;
    private const double RowHeight = 35;

    /// <summary>The writer is still typing. Settle before spending a request (macOS uses the same 350 ms).</summary>
    private static readonly TimeSpan IntentSettle = TimeSpan.FromMilliseconds(350);

    private readonly CommandPalette _palette = new();
    private readonly Border _panel = new();
    private readonly TextBox _query = new();
    private readonly ListView _list = new();
    private readonly TextBlock _message = new();
    private bool _syncing;
    private Windows.Foundation.Rect? _anchor;

    private CommandIntentResult? _intent;
    private string _intentQuery = "";
    private int _intentIndex;
    private bool _resolving;
    private string _scheduledQuery = "";
    private CancellationTokenSource? _intentCts;

    public CommandPalette Palette => _palette;

    /// <summary>Raised when a command row is chosen and its arguments parsed.</summary>
    public event Action<CommandInvocation>? InvocationChosen;

    /// <summary>Raised once the overlay has closed, after any literal was restored, so focus can return to the document.</summary>
    public event Action? Dismissed;

    /// <summary>Whether a request could be made now (feature on, key stored). Checked before anything is built.</summary>
    public Func<bool>? IntentReady { get; set; }

    /// <summary>Matches a typed request to a command, or null. Never throws.</summary>
    public Func<string, CancellationToken, Task<CommandIntentResult?>>? IntentResolver { get; set; }

    public CommandPaletteControl()
    {
        Visibility = Visibility.Collapsed;
        var root = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        root.Tapped += (_, e) => { if (ReferenceEquals(e.OriginalSource, root)) _palette.Dismiss(); };
        root.SizeChanged += (_, _) => Layout();

        _query.BorderThickness = new Thickness(0);
        _query.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _query.PlaceholderText = "Type a command";
        _query.FontSize = 14;
        _query.IsSpellCheckEnabled = false;
        _query.Height = 48;
        _query.Padding = new Thickness(15, 13, 15, 0);
        AutomationProperties.SetName(_query, "Command palette query");
        _query.TextChanged += (_, _) =>
        {
            if (!_syncing) _palette.UpdateQuery(_query.Text);
        };
        _query.PreviewKeyDown += OnQueryKeyDown;

        _list.SelectionMode = ListViewSelectionMode.Single;
        _list.IsItemClickEnabled = true;
        _list.MaxHeight = 360;
        _list.Padding = new Thickness(6);
        _list.ItemClick += (_, e) =>
        {
            if (e.ClickedItem is ListViewItem { Tag: CommandDescriptor d })
            {
                var index = Rows().ToList().FindIndex(x => x.Command == d.Command);
                if (index >= 0) SelectRow(index);
                Perform();
            }
        };
        AutomationProperties.SetName(_list, "Commands");

        _message.FontSize = 11;
        _message.Margin = new Thickness(14);
        _message.TextWrapping = TextWrapping.Wrap;
        AutomationProperties.SetAutomationId(_message, "palette.message");

        var stack = new StackPanel();
        stack.Children.Add(_query);
        stack.Children.Add(new Border { Height = 1, Background = new SolidColorBrush(Microsoft.UI.Colors.Gray), Opacity = 0.35 });
        stack.Children.Add(_list);
        stack.Children.Add(_message);

        _panel.Child = stack;
        _panel.CornerRadius = new CornerRadius(12);
        _panel.BorderThickness = new Thickness(1);
        _panel.HorizontalAlignment = HorizontalAlignment.Left;
        _panel.VerticalAlignment = VerticalAlignment.Top;
        AutomationProperties.SetName(_panel, "Command palette");
        root.Children.Add(_panel);
        Content = root;

        _palette.Changed += Sync;
        EditorTheme.Changed += ApplyTheme;
        ApplyTheme();
    }

    /// <summary>Open centred (Ctrl+K) or under <paramref name="anchor"/> (slash on an empty line, in this control's coordinates).</summary>
    public void Show(CommandSource source, string query, Windows.Foundation.Rect? anchor)
    {
        _anchor = anchor;
        if (source == CommandSource.InlineSlash) _palette.PresentInlineSlash();
        else _palette.Present(source, query);
        Layout();
        _query.Focus(FocusState.Programmatic);
        _query.Select(_query.Text.Length, 0);
    }

    // ---- rows: literal first, an assisted match only where the literal filter is empty -----------

    private bool ShowingIntent =>
        _palette.Filtered.Count == 0 && _intent is not null && _intentQuery == _palette.Query;

    /// <summary>
    /// The visible list. Typing a command name never reaches the network: the literal filter runs first, and the assisted
    /// match fills in only when it comes up empty.
    /// </summary>
    private IReadOnlyList<CommandDescriptor> Rows()
    {
        var literal = _palette.Filtered;
        if (literal.Count > 0 || !ShowingIntent) return literal;
        return [.. _intent!.Ranked.Select(id => CommandDescriptor.All.First(d => d.Command == id))];
    }

    private int SelectedRow => ShowingIntent ? _intentIndex : _palette.SelectionIndex;

    private void SelectRow(int index)
    {
        if (ShowingIntent)
        {
            var count = Rows().Count;
            _intentIndex = count == 0 ? 0 : Math.Clamp(index, 0, count - 1);
            Sync();
        }
        else _palette.Select(index);
    }

    private void MoveRow(int offset)
    {
        if (ShowingIntent) SelectRow(_intentIndex + offset);
        else _palette.MoveSelection(offset);
    }

    /// <summary>The slash name a row shows, carrying any argument an assisted match filled in so "/export docx" reads back before commit.</summary>
    private string RowName(CommandDescriptor d) =>
        ShowingIntent && _intent!.Invocation.Command == d.Command && _intent.Invocation.Arguments.Count > 0
            ? string.Join(' ', [d.Command.SlashName(), .. _intent.Invocation.Arguments])
            : d.Command.SlashName();

    private void Perform()
    {
        if (ShowingIntent)
        {
            var rows = Rows();
            if (_intentIndex < 0 || _intentIndex >= rows.Count) return;
            var command = rows[_intentIndex].Command;
            // An assisted match may have filled an argument from the request, such as the format in "send this to Word".
            var invocation = _intent!.Invocation.Command == command ? _intent.Invocation : new CommandInvocation(command, []);
            _palette.Dismiss(preserveLiteral: false);
            InvocationChosen?.Invoke(invocation);
            return;
        }
        var chosen = _palette.PerformSelected();
        if (chosen is not null) InvocationChosen?.Invoke(chosen);
    }

    private void OnQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // The IME owns keys while it is composing.
        var handled = true;
        switch (e.Key)
        {
            case VirtualKey.Escape: _palette.Dismiss(); break;
            case VirtualKey.Up: MoveRow(-1); break;
            case VirtualKey.Down: MoveRow(1); break;
            case VirtualKey.PageUp: MoveRow(-8); break;
            case VirtualKey.PageDown: MoveRow(8); break;
            case VirtualKey.Enter: Perform(); break;
            default: handled = false; break;
        }
        e.Handled = handled;
    }

    // ---- assisted match -------------------------------------------------------------------------

    /// <summary>The text to send, or null when the request is too short or empty. Same rule as macOS.</summary>
    private static string? IntentRequest(string query)
    {
        var request = CommandParser.CommandToken(query).Length == 0 ? query.Trim() : query.TrimStart('/');
        return request.Length >= CommandIntentResolver.MinimumRequestCharacters ? request : null;
    }

    private void ClearIntent()
    {
        _intentCts?.Cancel();
        _intentCts = null;
        _intent = null;
        _intentQuery = "";
        _intentIndex = 0;
        _resolving = false;
    }

    /// <summary>
    /// Asks for an assisted match, but only where the palette has nothing of its own to show. The order of these guards is
    /// the privacy contract: the literal filter runs first, and a request is built only once it has come up empty and the
    /// feature is switched on with a key in place.
    /// </summary>
    private void ScheduleIntent()
    {
        ClearIntent();
        if (!_palette.IsPresented || _palette.Filtered.Count > 0) return;
        if (IntentReady?.Invoke() != true || IntentResolver is null) return;
        if (IntentRequest(_palette.Query) is not { } request) return;

        var query = _palette.Query;
        var cts = _intentCts = new CancellationTokenSource();
        _resolving = true;
        _ = ResolveAsync(query, request, cts);
    }

    private async Task ResolveAsync(string query, string request, CancellationTokenSource cts)
    {
        CommandIntentResult? result = null;
        try
        {
            await Task.Delay(IntentSettle, cts.Token);
            result = await IntentResolver!(request, cts.Token);
        }
        catch (OperationCanceledException) { return; }
        if (cts.IsCancellationRequested || _palette.Query != query) return;
        _resolving = false;
        _intent = result;
        _intentQuery = query;
        _intentIndex = 0;
        Sync();
    }

    // ---- rendering ------------------------------------------------------------------------------

    private bool _wasPresented;
    private string? _shownKey;

    private void Sync()
    {
        var presented = _palette.IsPresented;
        Visibility = presented ? Visibility.Visible : Visibility.Collapsed;

        if (!presented) { ClearIntent(); _scheduledQuery = ""; }
        else if (_palette.Query != _scheduledQuery || !_wasPresented)
        {
            _scheduledQuery = _palette.Query;
            ScheduleIntent();
        }

        _syncing = true;
        try
        {
            if (_query.Text != _palette.Query) _query.Text = _palette.Query;
            RebuildRows();
        }
        finally { _syncing = false; }

        var rows = Rows();
        _list.SelectedIndex = rows.Count == 0 ? -1 : SelectedRow;
        if (_list.SelectedItem is not null) _list.ScrollIntoView(_list.SelectedItem);

        _message.Text = _palette.ErrorMessage
            ?? (rows.Count == 0 ? (_resolving ? "Looking for a match…" : "No matching command")
                : ShowingIntent ? "Assisted match: nothing in the palette matched what you typed" : "");
        _message.Visibility = _message.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        _list.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;

        if (_wasPresented && !presented) Dismissed?.Invoke();
        _wasPresented = presented;
    }

    private void RebuildRows()
    {
        var rows = Rows();
        var key = string.Join('|', rows.Select(RowName));
        if (_shownKey == key) return;
        _shownKey = key;
        _list.Items.Clear();
        var theme = EditorTheme.Current;
        foreach (var d in rows)
        {
            var row = new Grid { Height = RowHeight, ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(new FontIcon { Glyph = d.Glyph, FontSize = 14, Foreground = Brush(theme.Muted) });
            var name = new TextBlock
            {
                Text = RowName(d), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Foreground = Brush(theme.Emphasis),
                FontWeight = FontWeights.SemiBold,
            };
            Grid.SetColumn(name, 1);
            row.Children.Add(name);
            var title = new TextBlock
            {
                Text = d.Title, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Foreground = Brush(theme.Muted),
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            Grid.SetColumn(title, 2);
            row.Children.Add(title);

            var item = new ListViewItem { Content = row, Tag = d, Padding = new Thickness(10, 0, 10, 0) };
            AutomationProperties.SetName(item, $"{RowName(d)} {d.Title}. {d.Detail}");
            _list.Items.Add(item);
        }
    }

    private void Layout()
    {
        if (Content is not Grid root || root.ActualWidth <= 0) return;
        if (_anchor is { } anchor)
        {
            var frame = PalettePlacement.FrameBelow(anchor.X, anchor.Y, anchor.Height, root.ActualWidth, root.ActualHeight);
            _panel.Width = frame.Width;
            _panel.Margin = new Thickness(frame.X, frame.Y, 0, 0);
        }
        else
        {
            var width = Math.Min(CenteredWidth, Math.Max(1, root.ActualWidth - 32));
            _panel.Width = width;
            _panel.Margin = new Thickness(Math.Max(16, (root.ActualWidth - width) / 2), Math.Max(16, root.ActualHeight * 0.14), 0, 0);
        }
        _list.MaxHeight = Math.Max(120, Math.Min(360, root.ActualHeight - _panel.Margin.Top - 120));
    }

    private static SolidColorBrush Brush(Clio.Editor.Rgb c) => new(EditorTheme.ToColor(c));

    private void ApplyTheme()
    {
        var theme = EditorTheme.Current;
        _panel.Background = Brush(theme.Panel);
        _panel.BorderBrush = Brush(theme.PanelBorder);
        _query.Foreground = Brush(theme.Emphasis);
        _message.Foreground = Brush(theme.Muted);
        _shownKey = null;
        if (_palette.IsPresented) Sync();
    }
}
