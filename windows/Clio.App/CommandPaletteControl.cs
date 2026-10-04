using Clio.Editor.Commands;
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
/// slash or centred (macOS <c>CommandPaletteView</c>). All behaviour lives in the model; this only renders it.
/// </summary>
public sealed class CommandPaletteControl : UserControl
{
    private const double CenteredWidth = 620;
    private const double RowHeight = 35;

    private readonly CommandPalette _palette = new();
    private readonly Border _panel = new();
    private readonly TextBox _query = new();
    private readonly ListView _list = new();
    private readonly TextBlock _message = new();
    private bool _syncing;
    private Windows.Foundation.Rect? _anchor;

    public CommandPalette Palette => _palette;

    /// <summary>Raised when a command row is chosen and its arguments parsed.</summary>
    public event Action<CommandInvocation>? InvocationChosen;

    /// <summary>Raised once the overlay has closed, after any literal was restored, so focus can return to the document.</summary>
    public event Action? Dismissed;

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
                var index = _palette.Filtered.ToList().FindIndex(x => x.Command == d.Command);
                if (index >= 0) _palette.Select(index);
                Perform();
            }
        };
        AutomationProperties.SetName(_list, "Commands");

        _message.FontSize = 11;
        _message.Margin = new Thickness(14);
        _message.TextWrapping = TextWrapping.Wrap;

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

    private void Perform()
    {
        var invocation = _palette.PerformSelected();
        if (invocation is not null) InvocationChosen?.Invoke(invocation);
    }

    private void OnQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        // The IME owns keys while it is composing.
        var handled = true;
        switch (e.Key)
        {
            case VirtualKey.Escape: _palette.Dismiss(); break;
            case VirtualKey.Up: _palette.MoveSelection(-1); break;
            case VirtualKey.Down: _palette.MoveSelection(1); break;
            case VirtualKey.PageUp: _palette.MoveSelection(-8); break;
            case VirtualKey.PageDown: _palette.MoveSelection(8); break;
            case VirtualKey.Enter: Perform(); break;
            default: handled = false; break;
        }
        e.Handled = handled;
    }

    private bool _wasPresented;

    private void Sync()
    {
        var presented = _palette.IsPresented;
        Visibility = presented ? Visibility.Visible : Visibility.Collapsed;

        _syncing = true;
        try
        {
            if (_query.Text != _palette.Query) _query.Text = _palette.Query;
            RebuildRows();
        }
        finally { _syncing = false; }

        var filtered = _palette.Filtered;
        _list.SelectedIndex = filtered.Count == 0 ? -1 : _palette.SelectionIndex;
        if (_list.SelectedItem is not null) _list.ScrollIntoView(_list.SelectedItem);

        _message.Text = _palette.ErrorMessage ?? (filtered.Count == 0 ? "No matching command" : "");
        _message.Visibility = _message.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        _list.Visibility = filtered.Count == 0 ? Visibility.Collapsed : Visibility.Visible;

        if (_wasPresented && !presented) Dismissed?.Invoke();
        _wasPresented = presented;
    }

    private IReadOnlyList<CommandDescriptor>? _shownRows;

    private void RebuildRows()
    {
        var filtered = _palette.Filtered;
        if (_shownRows is not null && _shownRows.SequenceEqual(filtered)) return;
        _shownRows = filtered;
        _list.Items.Clear();
        var theme = EditorTheme.Current;
        foreach (var d in filtered)
        {
            var row = new Grid { Height = RowHeight, ColumnSpacing = 10 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.Children.Add(new FontIcon { Glyph = d.Glyph, FontSize = 14, Foreground = Brush(theme.Muted) });
            var name = new TextBlock
            {
                Text = d.Command.SlashName(), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Foreground = Brush(theme.Emphasis),
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
            AutomationProperties.SetName(item, $"{d.Command.SlashName()} {d.Title}. {d.Detail}");
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
        _shownRows = null;
        if (_palette.IsPresented) Sync();
    }
}
