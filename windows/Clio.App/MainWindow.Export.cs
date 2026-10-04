using Clio.Core;
using Clio.Export;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace Clio.App;

/// <summary>
/// <c>/export</c> (macOS <c>DocumentExportPresentation</c>): no argument opens the options sheet, a format goes straight to
/// choosing a destination, then the export runs off the UI thread with a Cancel action. A name collision is never
/// overwritten silently, and a failure offers Retry.
/// </summary>
public sealed partial class MainWindow
{
    private CancellationTokenSource? _exportCts;
    private bool _exporting;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _exportDismiss;

    private async Task ExportAsync(IReadOnlyList<string> arguments)
    {
        if (_exporting) { Status("An export is already running"); return; }
        if (_active is not { } tab)
        {
            await Dialog.Message("Nothing to export", "There is no document to export.");
            return;
        }

        var services = AppServices.Instance;
        ExportFormat format;
        try
        {
            if (ExportCommandRoute.Format(arguments) is { } requested) format = requested;
            else
            {
                var initial = ExportCommandRoute.TryParse(services.Settings.LastExportFormat, out var last) ? last : ExportFormat.Pdf;
                if (await ExportOptionsDialog.ShowAsync(Dialog, initial, services.PdfPrint) is not { } chosen) return;
                format = chosen;
            }
        }
        catch (ArgumentException e)
        {
            await Dialog.Message("Can’t export", e.Message);
            return;
        }

        services.Settings.LastExportFormat = ExportCommandRoute.RawValue(format);
        services.Settings.Save();

        if (await ChooseDestinationAsync(tab, format) is not { } destination) return;
        await RunExportAsync(tab, format, destination);
    }

    private async Task<string?> ChooseDestinationAsync(DocumentTab tab, ExportFormat format)
    {
        var (label, extension) = ExportCommandRoute.FileType(format);
        var picker = Pick(new FileSavePicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = System.IO.Path.GetFileNameWithoutExtension(DocumentExporter.SuggestedFileName(tab.Title, format)),
            CommitButtonText = "Export",
        });
        picker.FileTypeChoices.Add(label, [extension]);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return null;
        DiscardPickerPlaceholder(file.Path);
        return file.Path;
    }

    /// <summary>
    /// The save picker creates an empty file for a name that did not exist, which would make every new export look like a
    /// collision. A zero-length file created moments ago is that placeholder, so it is removed before exporting. A
    /// destination that already had content is left alone and reaches the collision dialog.
    /// </summary>
    private static void DiscardPickerPlaceholder(string path)
    {
        try
        {
            var info = new FileInfo(path);
            if (info.Exists && info.Length == 0 && DateTime.UtcNow - info.CreationTimeUtc < TimeSpan.FromSeconds(30)) info.Delete();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private async Task RunExportAsync(DocumentTab tab, ExportFormat format, string destination)
    {
        // The editor's text, as it is right now: the tab's own buffer, so it is exact even if the tab is in the background.
        var request = new ExportRequest(
            format,
            tab.Editing.Buffer.Text,
            System.IO.Path.GetFileNameWithoutExtension(tab.Title),
            destination,
            format == ExportFormat.Pdf ? AppServices.Instance.PdfPrint.Current : null);

        ExportCollisionResolution? resolution = null;
        while (true)
        {
            var cts = _exportCts = new CancellationTokenSource();
            _exporting = true;
            ShowExportProgress(format, System.IO.Path.GetFileName(destination), cts);
            try
            {
                var receipt = await DocumentExporter.ExportAsync(request, resolution, cts.Token);
                ShowExportDone(receipt);
                return;
            }
            catch (OperationCanceledException)
            {
                HideExportBar();
                return;
            }
            catch (DestinationExistsException e)
            {
                HideExportBar();
                if (await AskCollisionAsync(e.Collision) is not { } choice) return;
                resolution = new ExportCollisionResolution(e.Collision, choice);
            }
            catch (DestinationChangedException e)
            {
                HideExportBar();
                // The file changed after the choice was made, so that choice no longer applies. Ask again about what is there now.
                if (e.Current is null) { resolution = null; continue; }
                await Dialog.Message("Destination changed again", $"{System.IO.Path.GetFileName(destination)} changed while Clio was exporting. Choose what to do with the newest version.");
                if (await AskCollisionAsync(e.Current) is not { } choice) return;
                resolution = new ExportCollisionResolution(e.Current, choice);
            }
            catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException)
            {
                HideExportBar();
                var failure = ExportFailureMapper.Failure(e);
                var again = await Dialog.ShowAsync(failure.Title, failure.Message, primary: failure.CanRetry ? "Retry" : "OK", close: failure.CanRetry ? "Dismiss" : "");
                if (!failure.CanRetry || again != ContentDialogResult.Primary) return;
                resolution = null;
            }
            finally { _exporting = false; }
        }
    }

    /// <summary>Keep both, replace only the reviewed version, or cancel. Null for cancel.</summary>
    private async Task<CollisionChoice?> AskCollisionAsync(ExportCollision collision)
    {
        var name = System.IO.Path.GetFileName(collision.DestinationPath);
        var result = await Dialog.ShowAsync(
            $"{name} already exists",
            $"{name} changed or already exists. Replace only that reviewed version, or add the next numbered copy.",
            primary: "Keep both", secondary: "Replace", close: "Cancel");
        return result switch
        {
            ContentDialogResult.Primary => CollisionChoice.KeepBoth,
            ContentDialogResult.Secondary => CollisionChoice.Replace,
            _ => null,
        };
    }

    // ---- progress and completion ----------------------------------------------------------------

    private void ShowExportProgress(ExportFormat format, string fileName, CancellationTokenSource cts)
    {
        _exportDismiss?.Stop();
        var cancel = new Button { Content = "Cancel" };
        cancel.Click += (_, _) => cts.Cancel();
        ExportBar.Severity = InfoBarSeverity.Informational;
        ExportBar.Title = ExportCommandRoute.StatusText(format);
        ExportBar.Message = fileName;
        ExportBar.IsClosable = false;
        ExportBar.ActionButton = cancel;
        ExportBar.Content = new ProgressBar { IsIndeterminate = true, Margin = new Thickness(0, 4, 0, 8) };
        ExportBar.IsOpen = true;
    }

    private void ShowExportDone(ExportReceipt receipt)
    {
        var show = new Button { Content = "Show" };
        show.Click += (_, _) => RevealPath(receipt.DestinationPath);
        ExportBar.Severity = InfoBarSeverity.Success;
        ExportBar.Title = "Exported";
        ExportBar.Message = System.IO.Path.GetFileName(receipt.DestinationPath);
        ExportBar.IsClosable = true;
        ExportBar.ActionButton = show;
        ExportBar.Content = null;
        ExportBar.IsOpen = true;
        _exportDismiss?.Stop();
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(12);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => { if (!_exporting) ExportBar.IsOpen = false; };
        timer.Start();
        _exportDismiss = timer;
    }

    private void HideExportBar()
    {
        _exportDismiss?.Stop();
        ExportBar.IsOpen = false;
        ExportBar.Content = null;
    }
}
