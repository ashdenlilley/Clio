using Clio.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Clio.App;

public enum SearchMode { QuickOpen, Content }

/// <summary>
/// Search overlay (macOS quick open and workspace search). Filename quick open and full-text search stream
/// progressive batches from <see cref="SearchIndex"/>; a newer keystroke cancels the previous query.
/// Content results are capped at <see cref="SearchQuery.MaximumResults"/>.
/// </summary>
public sealed class SearchPanelControl : UserControl
{
    private const double PanelWidth = 680;
    private const int ResultLimit = SearchQuery.MaximumResults;

    private readonly Border _panel = new();
    private readonly TextBox _query = new();
    private readonly ListView _list = new();
    private readonly TextBlock _message = new();
    private CancellationTokenSource? _cts;
    private SearchMode _mode;
    private bool _syncing;

    /// <summary>A result was chosen: the full path, and the match range in the document if the search found one.</summary>
    public event Action<string, TextSpan?>? ResultChosen;

    /// <summary>The overlay closed; focus should return to the document.</summary>
    public event Action? Dismissed;

    public bool IsPresented => Visibility == Visibility.Visible;

    public SearchPanelControl()
    {
        Visibility = Visibility.Collapsed;
        var root = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        root.Tapped += (_, e) => { if (ReferenceEquals(e.OriginalSource, root)) Close(); };
        root.SizeChanged += (_, _) => Layout();

        _query.BorderThickness = new Thickness(0);
        _query.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _query.FontSize = 14;
        _query.IsSpellCheckEnabled = false;
        _query.Height = 48;
        _query.Padding = new Thickness(15, 13, 15, 0);
        AutomationProperties.SetName(_query, "Search query");
        _query.TextChanged += (_, _) => { if (!_syncing) _ = RunAsync(); };
        _query.PreviewKeyDown += OnQueryKeyDown;

        _list.SelectionMode = ListViewSelectionMode.Single;
        _list.IsItemClickEnabled = true;
        _list.Padding = new Thickness(6);
        _list.ItemClick += (_, e) => { if (e.ClickedItem is ListViewItem item) Choose(item); };
        AutomationProperties.SetName(_list, "Search results");

        _message.FontSize = 11;
        _message.Margin = new Thickness(14, 8, 14, 12);
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
        AutomationProperties.SetName(_panel, "Search");
        root.Children.Add(_panel);
        Content = root;

        EditorTheme.Changed += ApplyTheme;
        ApplyTheme();
    }

    public void Show(SearchMode mode, string query = "")
    {
        _mode = mode;
        _query.PlaceholderText = mode == SearchMode.QuickOpen ? "Open a document by name" : "Search text in all folders";
        _syncing = true;
        _query.Text = query;
        _syncing = false;
        _list.Items.Clear();
        Visibility = Visibility.Visible;
        _message.Text = AppServices.Instance.Workspaces.Count == 0 ? "Open a folder to search it." : "";
        Layout();
        _query.Focus(FocusState.Programmatic);
        _query.Select(_query.Text.Length, 0);
        if (query.Length > 0) _ = RunAsync();
    }

    private void Close()
    {
        if (!IsPresented) return;
        _cts?.Cancel();
        Visibility = Visibility.Collapsed;
        Dismissed?.Invoke();
    }

    private async Task RunAsync()
    {
        _cts?.Cancel();
        var text = _query.Text.Trim();
        if (text.Length == 0 || SearchQueryText.Terms(text).Count == 0)
        {
            _list.Items.Clear();
            _message.Text = "";
            return;
        }
        var cts = _cts = new CancellationTokenSource();
        var token = cts.Token;
        try
        {
            await Task.Delay(100, token); // debounce: only the last keystroke of a burst queries
            var query = new SearchQuery(text, limit: ResultLimit);
            var index = AppServices.Instance.Search;
            var batches = _mode == SearchMode.QuickOpen ? index.QuickOpenAsync(query, token) : index.SearchAsync(query, token);
            await foreach (var batch in batches.WithCancellation(token))
            {
                Render(batch);
                if (token.IsCancellationRequested) return;
            }
        }
        catch (OperationCanceledException) { }
        catch (SearchIndexException e) { _message.Text = e.Message; }
        catch (ObjectDisposedException) { }
    }

    private void Render(SearchBatch batch)
    {
        var theme = EditorTheme.Current;
        _list.Items.Clear();
        foreach (var result in batch.Results)
        {
            var host = AppServices.Instance.Workspaces.FirstOrDefault(w => w.Id == result.WorkspaceId);
            if (host is null) continue;
            var panel = new StackPanel { Spacing = 2, Margin = new Thickness(0, 6, 0, 6) };
            panel.Children.Add(new TextBlock
            {
                Text = result.RelativePath, FontSize = 12, FontWeight = FontWeights.SemiBold,
                Foreground = new SolidColorBrush(EditorTheme.ToColor(theme.Emphasis)), TextTrimming = TextTrimming.CharacterEllipsis,
            });
            if (!string.IsNullOrWhiteSpace(result.Excerpt))
                panel.Children.Add(new TextBlock
                {
                    Text = result.Excerpt.Trim(), FontSize = 11, MaxLines = 2, TextWrapping = TextWrapping.Wrap,
                    Foreground = new SolidColorBrush(EditorTheme.ToColor(theme.Muted)),
                });
            var path = Path.Combine(host.Root, result.RelativePath.Replace('/', Path.DirectorySeparatorChar));
            var item = new ListViewItem { Content = panel, Tag = (path, result.DocumentMatchRange), Padding = new Thickness(10, 0, 10, 0) };
            AutomationProperties.SetName(item, result.RelativePath);
            _list.Items.Add(item);
        }
        if (_list.SelectedIndex < 0 && _list.Items.Count > 0) _list.SelectedIndex = 0;
        _message.Text = _list.Items.Count == 0 && batch.IsFinal ? "No matches"
            : batch.IsFinal && _list.Items.Count >= ResultLimit ? $"Showing the first {ResultLimit} matches. Refine the search to narrow them."
            : "";
        _list.Visibility = _list.Items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        _message.Visibility = _message.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Choose(ListViewItem item)
    {
        if (item.Tag is not ValueTuple<string, TextSpan?> chosen) return;
        Close();
        ResultChosen?.Invoke(chosen.Item1, chosen.Item2);
    }

    private void OnQueryKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var handled = true;
        switch (e.Key)
        {
            case VirtualKey.Escape: Close(); break;
            case VirtualKey.Up: Move(-1); break;
            case VirtualKey.Down: Move(1); break;
            case VirtualKey.Enter: if (_list.SelectedItem is ListViewItem item) Choose(item); break;
            default: handled = false; break;
        }
        e.Handled = handled;
    }

    private void Move(int delta)
    {
        if (_list.Items.Count == 0) return;
        _list.SelectedIndex = Math.Clamp(_list.SelectedIndex + delta, 0, _list.Items.Count - 1);
        if (_list.SelectedItem is not null) _list.ScrollIntoView(_list.SelectedItem);
    }

    private void Layout()
    {
        if (Content is not Grid root || root.ActualWidth <= 0) return;
        var width = Math.Min(PanelWidth, Math.Max(1, root.ActualWidth - 32));
        _panel.Width = width;
        _panel.Margin = new Thickness(Math.Max(16, (root.ActualWidth - width) / 2), Math.Max(16, root.ActualHeight * 0.12), 0, 0);
        _list.MaxHeight = Math.Max(120, Math.Min(420, root.ActualHeight - _panel.Margin.Top - 120));
    }

    private void ApplyTheme()
    {
        var theme = EditorTheme.Current;
        _panel.Background = new SolidColorBrush(EditorTheme.ToColor(theme.Panel));
        _panel.BorderBrush = new SolidColorBrush(EditorTheme.ToColor(theme.PanelBorder));
        _query.Foreground = new SolidColorBrush(EditorTheme.ToColor(theme.Emphasis));
        _message.Foreground = new SolidColorBrush(EditorTheme.ToColor(theme.Muted));
    }
}
