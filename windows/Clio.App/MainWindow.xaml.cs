using Clio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Clio.App;

public sealed partial class MainWindow : Window
{
    private string? _root;
    private string? _path;
    private bool _bom;
    private LineEnding _ending;
    private DiskRevision? _revision;
    private bool _loading;
    private readonly DispatcherTimer _saveTimer = new() { Interval = TimeSpan.FromMilliseconds(800) };

    public MainWindow()
    {
        EditorTheme.Start();
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1100, 760));
        Editor.TextChanged += OnEditorTextChanged;
        _saveTimer.Tick += (_, _) => { _saveTimer.Stop(); Save(); };
        Closed += (_, _) => { _saveTimer.Stop(); Save(); };
        InitPalette();
    }

    private async void OnOpenFolder(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;

        _root = folder.Path;
        Tree.Items.Clear();
        foreach (var entry in WorkspaceScanner.Scan(_root))
        {
            var depth = entry.Relative.Count(c => c == '/');
            Tree.Items.Add(new ListViewItem
            {
                Content = System.IO.Path.GetFileName(entry.Path),
                Tag = entry,
                Padding = new Thickness(12 + 12 * depth, 4, 8, 4),
                IsEnabled = !entry.IsDirectory,
            });
        }
    }

    private void OnTreeSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (Tree.SelectedItem is ListViewItem { Tag: WorkspaceEntry { IsDirectory: false } entry }) Open(entry.Path);
    }

    private void Open(string path)
    {
        Save();
        try
        {
            var doc = DocumentIO.Load(path);
            _loading = true;
            Editor.SetText(doc.Text);
            Editor.Focus(FocusState.Programmatic);
            _loading = false;
            (_path, _bom, _ending, _revision) = (path, doc.Bom, doc.LineEnding, doc.Revision);
            SaveState.Text = "Saved";
            UpdateWordCount();
        }
        catch (ClioException ex)
        {
            _path = null;
            SaveState.Text = ex.Message;
        }
    }

    private void OnEditorTextChanged()
    {
        UpdateWordCount();
        if (_loading || _path is null) return;
        SaveState.Text = "Editing…";
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void Save()
    {
        if (_path is null || _revision is null) return;
        try
        {
            _revision = DocumentIO.Save(_path, Editor.Text, _bom, _ending, _revision);
            SaveState.Text = "Saved";
        }
        catch (ClioException ex)
        {
            // A conflict never overwrites the on-disk file.
            SaveState.Text = ex.Message;
            _path = null;
        }
    }

    private void UpdateWordCount()
    {
        var words = Editor.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        WordCount.Text = $"{words} words · {Math.Max(1, (int)Math.Round(words / 238.0))} min read";
    }
}
