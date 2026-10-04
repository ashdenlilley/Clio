using Clio.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace Clio.App;

/// <summary>
/// One editor window: a set of open documents (the sidebar's OPEN DOCUMENTS list is the tab strip, as on macOS),
/// the workspace tree, and the editor showing the active document. Files, conflicts and search live in partials.
/// </summary>
public sealed partial class MainWindow : Microsoft.UI.Xaml.Window
{
    private readonly List<DocumentTab> _tabs = [];
    private readonly Dialogs _dialogs;
    private readonly DispatcherTimer _statusTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private DocumentTab? _active;
    private readonly Clio.Editor.EditorModel _scratch = new(new Clio.Editor.TextBuffer());
    private readonly PasteStructureController _paste = new();
    private bool _applying;
    private bool _closing;

    public IReadOnlyList<DocumentTab> Tabs => _tabs;

    public MainWindow()
    {
        EditorTheme.Start();
        InitializeComponent();
        _dialogs = new Dialogs(() => Root.XamlRoot);
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        WindowSizer.ResizeDips(this, 1100, 760);

        Editor.TextChanged += OnEditorTextChanged;
        Editor.PlainTextPasted += (text, range) => _paste.Recover(text, range, Editor, AppServices.Instance.Intelligence);
        _paste.StateChanged += RefreshStatus;
        _statusTimer.Tick += (_, _) => RefreshStatus();
        _statusTimer.Start();
        Closed += OnClosed;
        Activated += OnFirstActivated;

        var services = AppServices.Instance;
        services.WorkspacesChanged += RebuildTree;
        services.WorkspaceEventsObserved += OnWorkspaceEvents;

        InitPalette();
        InitShortcuts();
        InitSearch();
        RebuildTree();
        RefreshSidebarTabs();
        RefreshAll();
    }

    private Dialogs Dialog => _dialogs;

    /// <summary>
    /// A document opened while the window was still being created asks for focus before the window can take it, so
    /// the first keystrokes would go nowhere. Once the window is really active, the editor takes focus.
    /// </summary>
    private void OnFirstActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated || _active is null) return;
        Activated -= OnFirstActivated;
        Editor.Focus(FocusState.Programmatic);
    }

    /// <summary>Gives the editor keyboard focus once the window has finished opening its documents (launch with files).</summary>
    public void FocusEditorSoon() =>
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => { if (_active is not null) Editor.Focus(FocusState.Programmatic); });

    // ---- tabs -----------------------------------------------------------------------------------

    /// <summary>Opens <paramref name="path"/> in this window, or activates the window that already has it open.</summary>
    public DocumentTab? OpenPath(string path)
    {
        path = System.IO.Path.GetFullPath(path);
        if (FindTab(path) is { } existing) { Activate(existing); return existing; }
        if (App.WindowHolding(path) is { } other && other != this)
        {
            var tab = other.FindTab(path)!;
            other.Activate(tab);
            other.Activate();
            return tab;
        }
        try
        {
            var tab = DocumentTab.Open(path);
            AddTab(tab);
            return tab;
        }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException)
        {
            SaveState.Text = e.Message;
            return null;
        }
    }

    public DocumentTab? FindTab(string path) =>
        _tabs.FirstOrDefault(t => t.Session.Path is { } p && string.Equals(p, path, StringComparison.OrdinalIgnoreCase));

    private void AddTab(DocumentTab tab)
    {
        _tabs.Add(tab);
        tab.Changed += () => OnTabChanged(tab);
        RefreshSidebarTabs();
        Activate(tab);
    }

    public void Activate(DocumentTab tab)
    {
        if (!ReferenceEquals(_active, tab) && _active is not null)
        {
            _active.ScrollOffset = Editor.ScrollOffset;
            _ = _active.Autosaver.FlushAsync(_active.Session);
        }
        // A paste recovery in flight belongs to the document it started in.
        if (!ReferenceEquals(_active, tab)) _paste.Cancel();
        _active = tab;
        _applying = true;
        try
        {
            // Each tab keeps its own text, selection and undo history; showing it again resumes where it left off.
            tab.SyncEditingBuffer();
            Editor.UseModel(tab.Editing);
            Editor.ScrollOffset = tab.ScrollOffset;
        }
        finally { _applying = false; }
        Editor.Focus(FocusState.Programmatic);
        RefreshSidebarTabs();
        RefreshAll();
    }

    /// <summary>No document is open: show an empty, history-free editor.</summary>
    private void ShowEmpty()
    {
        _paste.Cancel();
        _applying = true;
        try
        {
            Editor.UseModel(_scratch);
            Editor.SetText("");
        }
        finally { _applying = false; }
    }

    private async Task CloseTabAsync(DocumentTab tab)
    {
        if (!await ConfirmCloseAsync(tab)) return;
        var index = _tabs.IndexOf(tab);
        _tabs.Remove(tab);
        tab.Dispose();
        if (ReferenceEquals(_active, tab))
        {
            _active = null;
            if (_tabs.Count > 0) Activate(_tabs[Math.Clamp(index, 0, _tabs.Count - 1)]);
            else ShowEmpty();
        }
        RefreshSidebarTabs();
        RefreshAll();
    }

    /// <summary>Saves before closing. A document that cannot be saved asks first; its text stays in the crash journal either way.</summary>
    private async Task<bool> ConfirmCloseAsync(DocumentTab tab)
    {
        try { await tab.Autosaver.FlushAsync(tab.Session); }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { }

        var session = tab.Session;
        if (!session.IsDirty) return true;
        if (session.Conflict is not null || !session.IsBackedByFile)
        {
            var why = session.Conflict is not null
                ? "This document changed outside Clio and you have not chosen a version."
                : "This document has no file to save to.";
            var result = await Dialog.ShowAsync($"Close {tab.Title}?", $"{why} Your text stays in recovery for 7 days.", "Close anyway", close: "Keep open", destructive: true);
            return result == ContentDialogResult.Primary;
        }
        // Dirty and backed, but the save failed (locked file, disk full): do not drop it silently.
        var message = tab.Autosaver.LastError?.Message ?? "The document could not be saved.";
        var answer = await Dialog.ShowAsync($"Close {tab.Title}?", $"{message} Your text stays in recovery for 7 days.", "Close anyway", close: "Keep open", destructive: true);
        return answer == ContentDialogResult.Primary;
    }

    private void OnOpenDocSelected(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingTabs) return;
        if (OpenDocs.SelectedItem is ListViewItem { Tag: DocumentTab tab } && !ReferenceEquals(tab, _active)) Activate(tab);
    }

    private bool _syncingTabs;

    private void RefreshSidebarTabs()
    {
        _syncingTabs = true;
        try
        {
            OpenDocs.Items.Clear();
            foreach (var tab in _tabs)
            {
                var row = new Grid();
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var title = new TextBlock
                {
                    Text = tab.Session.IsDirty ? tab.Title + " •" : tab.Title,
                    VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
                };
                var close = new Button
                {
                    Content = new FontIcon { Glyph = "", FontSize = 9 }, Padding = new Thickness(4),
                    Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
                    BorderThickness = new Thickness(0), Tag = tab,
                };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(close, $"Close {tab.Title}");
                close.Click += async (_, _) => await CloseTabAsync(tab);
                Grid.SetColumn(close, 1);
                row.Children.Add(title);
                row.Children.Add(close);
                var item = new ListViewItem { Content = row, Tag = tab, Padding = new Thickness(8, 0, 4, 0), MinHeight = 32 };
                OpenDocs.Items.Add(item);
                if (ReferenceEquals(tab, _active)) OpenDocs.SelectedItem = item;
            }
            OpenDocumentsSection.Visibility = _tabs.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        finally { _syncingTabs = false; }
    }

    // ---- editor <-> session ---------------------------------------------------------------------

    private void OnEditorTextChanged()
    {
        UpdateWordCount();
        if (_applying || _active is null) return;
        _active.Session.SetText(Editor.Text);
        _active.Autosaver.DocumentDidChange(_active.Session);
        RefreshStatus();
    }

    private void OnTabChanged(DocumentTab tab)
    {
        if (ReferenceEquals(tab, _active))
        {
            // The session changed under the editor (an outside edit reloaded, or a conflict was resolved).
            if (!string.Equals(tab.Session.Text, Editor.Text, StringComparison.Ordinal))
            {
                var caret = Editor.Model.Caret;
                _applying = true;
                try { Editor.SetText(tab.Session.Text); Editor.Model.SetSelection(caret, caret); }
                finally { _applying = false; }
            }
            RefreshAll();
        }
        RefreshSidebarTabs();
    }

    private void RefreshAll()
    {
        UpdateWordCount();
        RefreshStatus();
        RefreshBanner();
        TitleText.Text = _active is null ? "Clio" : $"{_active.Title} — Clio";
        Title = TitleText.Text;
    }

    private void RefreshStatus()
    {
        if (_active is null) return;
        SaveState.Text = _paste.IsRecovering ? "Formatting pasted text…" : _active.StatusText;
    }

    private void UpdateWordCount()
    {
        var words = Editor.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        WordCount.Text = _active is null ? "" : $"{words} words · {Math.Max(1, (int)Math.Round(words / 238.0))} min read";
    }

    // ---- shortcuts ------------------------------------------------------------------------------

    private void InitShortcuts()
    {
        void Bind(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
        {
            var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
            accelerator.Invoked += (_, e) => { action(); e.Handled = true; };
            ((UIElement)Content).KeyboardAccelerators.Add(accelerator);
        }
        Bind(VirtualKey.S, VirtualKeyModifiers.Control, () => _ = SaveAsync());
        Bind(VirtualKey.O, VirtualKeyModifiers.Control, () => _ = OpenFileAsync());
        Bind(VirtualKey.N, VirtualKeyModifiers.Control, () => _ = NewDocumentAsync());
        Bind(VirtualKey.N, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => App.OpenWindow());
        Bind(VirtualKey.W, VirtualKeyModifiers.Control, () => { if (_active is not null) _ = CloseTabAsync(_active); });
        Bind(VirtualKey.P, VirtualKeyModifiers.Control, () => ShowSearch(SearchMode.QuickOpen));
        Bind(VirtualKey.F, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => ShowSearch(SearchMode.Content));

        // Ctrl+, (Settings) and Ctrl+Tab / Ctrl+Shift+Tab (next and previous document). WinUI 3 never delivers a
        // KeyboardAccelerator for punctuation or for Tab while a text input has focus, so these are a tunnelling handler on
        // the root: it sees the key before the editor or the sidebar does, wherever focus is.
        ((UIElement)Content).PreviewKeyDown += (_, e) =>
        {
            if ((int)e.Key != OemComma && e.Key != VirtualKey.Tab) return;
            var held = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread;
            bool Down(VirtualKey key) => held(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (!Down(VirtualKey.Control) || Down(VirtualKey.Menu)) return;
            var shift = Down(VirtualKey.Shift);
            if (e.Key == VirtualKey.Tab) CycleTab(shift ? -1 : 1);
            else if (!shift) OpenSettings();
            else return;
            e.Handled = true;
        };
    }

    /// <summary>VK_OEM_COMMA. <see cref="VirtualKey"/> has no name for it.</summary>
    private const int OemComma = 0xBC;

    private void CycleTab(int delta)
    {
        if (_tabs.Count < 2 || _active is null) return;
        var index = (_tabs.IndexOf(_active) + delta + _tabs.Count) % _tabs.Count;
        Activate(_tabs[index]);
    }

    // ---- save -----------------------------------------------------------------------------------

    private async Task SaveAsync()
    {
        if (_active is not { } tab) return;
        if (!tab.Session.IsBackedByFile) { await SaveAsAsync(tab); return; }
        try { await tab.Autosaver.FlushAsync(tab.Session); }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { SaveState.Text = e.Message; }
        RefreshStatus();
    }

    // ---- lifetime -------------------------------------------------------------------------------

    private void OnClosed(object sender, WindowEventArgs args)
    {
        if (_closing) return;
        _closing = true;
        _statusTimer.Stop();
        _paste.Cancel();
        _exportCts?.Cancel();
        var services = AppServices.Instance;
        services.WorkspacesChanged -= RebuildTree;
        services.WorkspaceEventsObserved -= OnWorkspaceEvents;
        // Last chance to write: synchronous, so the process cannot exit mid-save. Failures stay in the crash journal.
        foreach (var tab in _tabs)
        {
            try { tab.Autosaver.Flush(tab.Session); }
            catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { }
            tab.Dispose();
        }
        _tabs.Clear();
        App.WindowClosed(this);
    }
}
