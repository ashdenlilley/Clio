using Clio.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Clio.App;

public enum TreeEntryKind { Workspace, Folder, File }

/// <summary>A sidebar tree row. <see cref="ToString"/> is what the TreeView shows.</summary>
public sealed record TreeEntry(TreeEntryKind Kind, string Name, string Path, WorkspaceHost Host)
{
    public override string ToString() => Name;
}

/// <summary>Sidebar workspace tree and the reaction to watcher events.</summary>
public sealed partial class MainWindow
{
    private readonly HashSet<string> _collapsed = new(StringComparer.OrdinalIgnoreCase);
    private readonly DispatcherTimer _treeTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private int _treeGeneration;
    private bool _treeTimerWired;

    private async void OnOpenFolder(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;
        AppServices.Instance.AddWorkspace(folder.Path);
        if (Sidebar.Visibility != Visibility.Visible) ToggleSidebar();
    }

    private void RequestTreeRefresh()
    {
        if (!_treeTimerWired)
        {
            _treeTimerWired = true;
            _treeTimer.Tick += (_, _) => { _treeTimer.Stop(); RebuildTree(); };
        }
        _treeTimer.Stop();
        _treeTimer.Start();
    }

    /// <summary>Rescans every workspace (off the UI thread, identity-based) and rebuilds the tree, keeping collapsed folders.</summary>
    private async void RebuildTree()
    {
        var generation = ++_treeGeneration;
        var services = AppServices.Instance;
        var hosts = services.Workspaces.ToList();
        var includeText = services.Settings.IncludeTextFiles;
        var scanned = await Task.Run(() => hosts.Select(host =>
        {
            try { return (host, files: (IReadOnlyList<WorkspaceFile>)WorkspaceScanner.ScanFiles(host.Id, host.Root, services.Identities, includeText)); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or ClioException) { return (host, files: []); }
        }).ToList());
        if (generation != _treeGeneration) return; // a newer rebuild started meanwhile

        Tree.RootNodes.Clear();
        foreach (var (host, files) in scanned)
        {
            var root = new TreeViewNode { Content = new TreeEntry(TreeEntryKind.Workspace, host.DisplayName, host.Root, host), IsExpanded = !_collapsed.Contains(host.Root) };
            var folders = new Dictionary<string, TreeViewNode>(StringComparer.OrdinalIgnoreCase);
            foreach (var file in files.OrderBy(f => f.RelativePath, StringComparer.OrdinalIgnoreCase))
            {
                var parts = file.RelativePath.Split('/');
                var parent = root;
                var folderPath = host.Root;
                for (var i = 0; i < parts.Length - 1; i++)
                {
                    folderPath = System.IO.Path.Combine(folderPath, parts[i]);
                    if (!folders.TryGetValue(folderPath, out var node))
                    {
                        node = new TreeViewNode { Content = new TreeEntry(TreeEntryKind.Folder, parts[i], folderPath, host), IsExpanded = !_collapsed.Contains(folderPath) };
                        parent.Children.Add(node);
                        folders[folderPath] = node;
                    }
                    parent = node;
                }
                parent.Children.Add(new TreeViewNode { Content = new TreeEntry(TreeEntryKind.File, parts[^1], file.Path, host) });
            }
            Tree.RootNodes.Add(root);
        }
        Tree.Expanding -= OnNodeExpansion;
        Tree.Collapsed -= OnNodeCollapsed;
        Tree.Expanding += OnNodeExpansion;
        Tree.Collapsed += OnNodeCollapsed;
        TreeHint.Visibility = Tree.RootNodes.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnNodeExpansion(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (args.Node.Content is TreeEntry entry) _collapsed.Remove(entry.Path);
    }

    private void OnNodeCollapsed(TreeView sender, TreeViewCollapsedEventArgs args)
    {
        if (args.Node.Content is TreeEntry entry) _collapsed.Add(entry.Path);
    }

    private void OnTreeItemInvoked(TreeView sender, TreeViewItemInvokedEventArgs args)
    {
        if (args.InvokedItem is not TreeViewNode { Content: TreeEntry entry } node) return;
        if (entry.Kind == TreeEntryKind.File) OpenPath(entry.Path);
        else node.IsExpanded = !node.IsExpanded;
    }

    private void OnTreeRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var element = e.OriginalSource as DependencyObject;
        while (element is not null && element is not TreeViewItem) element = VisualTreeHelper.GetParent(element);
        if (element is not TreeViewItem item || Tree.NodeFromContainer(item) is not { Content: TreeEntry entry }) return;

        var flyout = new MenuFlyout();
        void Add(string text, Action action)
        {
            var menuItem = new MenuFlyoutItem { Text = text };
            menuItem.Click += (_, _) => action();
            flyout.Items.Add(menuItem);
        }
        switch (entry.Kind)
        {
            case TreeEntryKind.File:
                Add("Open", () => OpenPath(entry.Path));
                Add("Rename…", () => _ = WithOpenTab(entry.Path, RenameAsync));
                Add("Move to folder…", () => _ = WithOpenTab(entry.Path, MoveToFolderAsync));
                Add("Move to Recycle Bin…", () => _ = WithOpenTab(entry.Path, DeleteAsync));
                Add("Show in File Explorer", () => RevealPath(entry.Path));
                break;
            case TreeEntryKind.Folder:
                Add("New document here…", () => _ = NewDocumentAsync(entry.Path));
                Add("Show in File Explorer", () => RevealPath(entry.Path));
                break;
            case TreeEntryKind.Workspace:
                Add("New document here…", () => _ = NewDocumentAsync(entry.Path));
                Add("Show in File Explorer", () => RevealPath(entry.Path));
                Add("Remove from sidebar", () => AppServices.Instance.RemoveWorkspace(entry.Host));
                break;
        }
        flyout.ShowAt(item, new Microsoft.UI.Xaml.Controls.Primitives.FlyoutShowOptions { Position = e.GetPosition(item) });
        e.Handled = true;
    }

    private async Task WithOpenTab(string path, Func<DocumentTab, Task> action)
    {
        if (OpenPath(path) is { } tab) await action(tab);
    }

    // ---- watcher events -------------------------------------------------------------------------

    private void OnWorkspaceEvents(WorkspaceHost host, IReadOnlyList<WorkspaceEvent> events)
    {
        RequestTreeRefresh();

        foreach (var tab in _tabs.ToList())
        {
            if (tab.Session.Path is not { } path) continue;
            var moved = events.FirstOrDefault(e => e.Kind == WorkspaceEventKind.Moved && e.PreviousPath is not null && e.Path is not null &&
                                                    string.Equals(e.PreviousPath, path, StringComparison.OrdinalIgnoreCase));
            if (moved is not null)
            {
                // A move outside Clio: the buffer follows the file.
                tab.Session.DidMove(moved.Path!);
                continue;
            }
            var affected = events.Any(e => e.Kind is WorkspaceEventKind.RescanRequired or WorkspaceEventKind.RootChanged ||
                (e.Path is { } p && (string.Equals(p, path, StringComparison.OrdinalIgnoreCase) ||
                                     path.StartsWith(p.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))));
            if (affected) _ = ReconcileAsync(tab);
        }
    }

    private async Task ReconcileAsync(DocumentTab tab)
    {
        try
        {
            // A write in flight must land before the disk is compared with the buffer.
            await tab.Autosaver.SettlePendingFileIOAsync();
            await Task.Run(() => AppServices.Instance.Documents.ReconcileExternalChange(tab.Session));
        }
        catch (ExternalConflictException) { /* the conflict is already registered on the session */ }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { SaveState.Text = e.Message; }
        OnTabChanged(tab);
    }

    // ---- reveal ---------------------------------------------------------------------------------

    private static void RevealPath(string path)
    {
        var args = Directory.Exists(path) ? $"\"{path}\"" : $"/select,\"{path}\"";
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe") { Arguments = args, UseShellExecute = true });
    }
}
