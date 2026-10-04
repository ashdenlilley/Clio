using Clio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Clio.App;

/// <summary>New, open, save as, rename, move and delete. File changes go through <see cref="DocumentMover"/>.</summary>
public sealed partial class MainWindow
{
    private static readonly string[] DocumentExtensions = [".md", ".markdown", ".txt"];

    private async void OnNewDocument(object sender, RoutedEventArgs e) => await NewDocumentAsync();

    private T Pick<T>(T picker)
    {
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        return picker;
    }

    // ---- open / new / save as -------------------------------------------------------------------

    private async Task OpenFileAsync()
    {
        var picker = Pick(new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary });
        foreach (var extension in DocumentExtensions) picker.FileTypeFilter.Add(extension);
        var file = await picker.PickSingleFileAsync();
        if (file is not null) OpenPath(file.Path);
    }

    /// <summary>Asks where to create the document, creates it empty, and opens it (as macOS does).</summary>
    private async Task NewDocumentAsync(string? folder = null)
    {
        var picker = Pick(new FileSavePicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, SuggestedFileName = "Untitled" });
        picker.FileTypeChoices.Add("Markdown", [".md"]);
        picker.FileTypeChoices.Add("Plain text", [".txt"]);
        if (folder is not null) picker.CommitButtonText = "Create here";
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        if (!FileNames.IsSafeComponent(file.Name))
        {
            await Dialog.Message("Choose another name", "Windows can’t use that name for a document.");
            return;
        }
        OpenPath(file.Path);
    }

    private async Task SaveAsAsync(DocumentTab tab)
    {
        var picker = Pick(new FileSavePicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, SuggestedFileName = System.IO.Path.GetFileNameWithoutExtension(tab.Title) });
        picker.FileTypeChoices.Add("Markdown", [".md"]);
        picker.FileTypeChoices.Add("Plain text", [".txt"]);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return;
        try
        {
            await Task.Run(() => tab.SaveAs(file.Path));
            SaveState.Text = "Saved";
        }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException)
        {
            await Dialog.Message("Couldn’t save the document", e.Message);
        }
        RefreshSidebarTabs();
        RefreshAll();
    }

    // ---- rename / move --------------------------------------------------------------------------

    private async Task RenameAsync(DocumentTab tab)
    {
        if (tab.Session.Path is not { } path) { await Dialog.Message("Nothing to rename", "Save this document to a file first."); return; }
        var current = System.IO.Path.GetFileName(path);
        var entered = await Dialog.PromptAsync("Rename document", "Enter a filename. The document stays in its current folder.", current, "Rename");
        if (string.IsNullOrWhiteSpace(entered)) return;

        var name = System.IO.Path.GetFileName(entered);
        if (System.IO.Path.GetExtension(name).Length == 0) name += System.IO.Path.GetExtension(current);
        if (name == current) return;
        if (!FileNames.IsSafeComponent(name))
        {
            await Dialog.Message("Choose another name", "Windows can’t use that name for a file.");
            return;
        }
        var root = RootFor(tab, path);
        var parent = RelativeParent(path, root);
        await MoveAsync(tab, root, tab.Workspace, parent, name);
    }

    private async Task MoveToFolderAsync(DocumentTab tab)
    {
        if (tab.Session.Path is not { } path) { await Dialog.Message("Nothing to move", "Save this document to a file first."); return; }
        var picker = Pick(new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary });
        picker.FileTypeFilter.Add("*");
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null) return;

        var host = AppServices.Instance.WorkspaceContaining(folder.Path);
        if (host is null)
        {
            await Dialog.Message("Choose a folder in the sidebar", "A document can only move into a folder that is open in Clio. Open the destination folder first.");
            return;
        }
        await MoveAsync(tab, host.Root, host, RelativeParent(System.IO.Path.Combine(folder.Path, "x"), host.Root), null);
    }

    private static string RootFor(DocumentTab tab, string path) => tab.Workspace?.Root ?? System.IO.Path.GetDirectoryName(path)!;

    private static string RelativeParent(string filePath, string root)
    {
        var relative = System.IO.Path.GetRelativePath(root, System.IO.Path.GetDirectoryName(filePath)!);
        return relative == "." ? "" : relative.Replace('\\', '/');
    }

    private async Task MoveAsync(DocumentTab tab, string destinationRoot, WorkspaceHost? destinationHost, string parentRelativePath, string? filename)
    {
        var session = tab.Session;
        if (session.Path is not { } source) return;
        if (session.Conflict is not null)
        {
            await Dialog.Message("Resolve the conflict first", "Choose a version of this document before moving or renaming it.");
            return;
        }

        try { await tab.Autosaver.FlushAsync(session); }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException)
        {
            await Dialog.Message("Couldn’t save before moving", e.Message);
            return;
        }

        var sourceRoot = RootFor(tab, source);
        tab.Autosaver.SuspendForFileOperation();
        try
        {
            await tab.Autosaver.SettlePendingFileIOAsync();
            CollisionChoice? choice = null;
            FileCollision? approved = null;
            while (true)
            {
                var request = new MoveRequest(
                    source, sourceRoot, destinationRoot, session.Id, parentRelativePath, filename, choice, approved,
                    session.ExpectedDiskRevision, new BufferGeneration(session.Id, session.Revision),
                    tab.Workspace?.Id, destinationHost?.Id);
                var outcome = await Task.Run(() => AppServices.Instance.Mover.Move(request));

                switch (outcome)
                {
                    case MoveOutcome.Completed done:
                        FinishMove(tab, done.DestinationPath, replacedPath: approved is null ? null : done.DestinationPath);
                        return;
                    case MoveOutcome.CompletedWithRecovery recovered:
                        FinishMove(tab, recovered.DestinationPath, replacedPath: approved is null ? null : recovered.DestinationPath);
                        await Dialog.Message("Moved, with a recovery copy", $"Some bytes could not be removed from the old location. A copy is kept at:\n{recovered.Notice.RetainedPath}");
                        return;
                    case MoveOutcome.Cancelled:
                        return;
                    case MoveOutcome.Collision collision:
                        var decision = await AskCollisionAsync(collision.Details);
                        if (decision is null) return;
                        choice = decision;
                        approved = decision == CollisionChoice.Replace ? collision.Details : null;
                        if (decision == CollisionChoice.Replace) PreserveOpenDestination(collision.Details.ProposedPath);
                        continue;
                }
            }
        }
        catch (MoveException e)
        {
            var text = e.Failure switch
            {
                MoveFailure.SourceChanged => "The document changed on disk during the move. Nothing was moved. Review it and try again.",
                MoveFailure.DestinationChanged => "The destination changed during the move. Nothing was replaced.",
                _ => "That location isn’t allowed for this document.",
            };
            await Dialog.Message("Couldn’t move the document", text);
        }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException)
        {
            await Dialog.Message("Couldn’t move the document", e.Message);
        }
        finally
        {
            tab.Autosaver.ResumeAfterFileOperation();
            RefreshSidebarTabs();
            RefreshAll();
        }
    }

    private async Task<CollisionChoice?> AskCollisionAsync(FileCollision collision)
    {
        var name = System.IO.Path.GetFileName(collision.ProposedPath);
        var result = await Dialog.ShowAsync($"“{name}” already exists", "Keep both documents, or replace the existing one? A replaced document is kept in recovery for 7 days.",
            primary: "Keep both", secondary: "Replace", close: "Cancel");
        return result switch
        {
            ContentDialogResult.Primary => CollisionChoice.KeepBoth,
            ContentDialogResult.Secondary => CollisionChoice.Replace,
            _ => null,
        };
    }

    /// <summary>A document the move replaces may be open with unsaved text. Preserve it before the bytes go.</summary>
    private static void PreserveOpenDestination(string path)
    {
        if (App.WindowHolding(path)?.FindTab(path) is not { } open || !open.Session.IsDirty) return;
        var snapshot = open.Session.Snapshot();
        try { AppServices.Instance.Recovery.Preserve(snapshot.DocumentId, snapshot.Filename, snapshot.Encode()); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private void FinishMove(DocumentTab tab, string destination, string? replacedPath)
    {
        if (replacedPath is not null) App.WindowHolding(replacedPath)?.CloseTabQuietly(replacedPath);
        tab.Rebind(destination);
        OnTabChanged(tab);
    }

    /// <summary>Closes a tab whose file was replaced underneath it. Its unsaved text was preserved first.</summary>
    public void CloseTabQuietly(string path)
    {
        if (FindTab(path) is not { } tab) return;
        _tabs.Remove(tab);
        tab.Dispose();
        if (ReferenceEquals(_active, tab))
        {
            _active = null;
            if (_tabs.Count > 0) Activate(_tabs[0]);
            else ShowEmpty();
        }
        RefreshSidebarTabs();
        RefreshAll();
    }

    // ---- delete ---------------------------------------------------------------------------------

    private async Task DeleteAsync(DocumentTab tab)
    {
        if (tab.Session.Path is not { } path)
        {
            await CloseTabAsync(tab);
            return;
        }
        var answer = await Dialog.ShowAsync($"Move {System.IO.Path.GetFileName(path)} to the Recycle Bin?", "You can restore it from the Recycle Bin.",
            primary: "Move to Recycle Bin", close: "Cancel", destructive: true);
        if (answer != ContentDialogResult.Primary) return;

        try { await tab.Autosaver.FlushAsync(tab.Session); }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { }
        try
        {
            var expected = tab.Session.ExpectedDiskRevision;
            await Task.Run(() => DocumentMover.MoveToTrash(path, expected));
        }
        catch (MoveException e) when (e.Failure == MoveFailure.SourceChanged)
        {
            await Dialog.Message("Not deleted", "The document changed on disk. Review it before deleting.");
            return;
        }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException)
        {
            await Dialog.Message("Couldn’t delete the document", e.Message);
            return;
        }
        CloseTabQuietly(path);
    }
}
