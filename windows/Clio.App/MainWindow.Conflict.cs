using System.Text;
using Clio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Clio.App;

/// <summary>
/// External-edit and deletion UI. A banner above the editor says what happened and offers the next step;
/// resolving a conflict goes through <see cref="DocumentService.Resolve"/>, which re-reads the disk before every write.
/// </summary>
public sealed partial class MainWindow
{
    private void RefreshBanner()
    {
        if (_active is not { } tab) { Banner.IsOpen = false; return; }
        var session = tab.Session;
        var name = tab.Title;

        if (session.Conflict is not null && tab.ConflictIsDeletion)
        {
            Show(InfoBarSeverity.Warning, $"“{name}” was deleted outside Clio",
                "You have unsaved changes. Your text is kept in recovery.", "Keep as new file…", () => _ = KeepDeletedConflictAsync(tab));
        }
        else if (session.Conflict is not null)
        {
            Show(InfoBarSeverity.Warning, $"“{name}” changed outside Clio",
                "Autosave is paused until you choose a version.", "Choose version…", () => _ = ResolveConflictAsync(tab));
        }
        else if (session.RequiresExplicitRestore)
        {
            Show(InfoBarSeverity.Informational, $"“{name}” was deleted outside Clio",
                "Your text is kept. Save it to a new file to continue.", "Save as…", () => _ = SaveAsAsync(tab));
        }
        else if (!session.IsBackedByFile)
        {
            Show(InfoBarSeverity.Informational, "This document is not saved yet", "Choose where to save it.", "Save as…", () => _ = SaveAsAsync(tab));
        }
        else Banner.IsOpen = false;
    }

    private void Show(InfoBarSeverity severity, string title, string message, string action, Action invoke)
    {
        var button = new Button { Content = action };
        button.Click += (_, _) => invoke();
        Banner.Severity = severity;
        Banner.Title = title;
        Banner.Message = message;
        Banner.ActionButton = button;
        Banner.IsOpen = true;
    }

    private async Task ResolveConflictAsync(DocumentTab tab)
    {
        if (tab.Session.Conflict is not { } conflict) return;

        var choices = new RadioButtons { SelectedIndex = -1 };
        choices.Items.Add("Keep my version. The outside version is saved to recovery.");
        choices.Items.Add("Load the outside version. My version is saved to recovery.");
        choices.Items.Add("Keep both. My text is saved as a separate conflict copy.");

        var panel = new StackPanel { Spacing = 12, MinWidth = 420 };
        panel.Children.Add(new TextBlock
        {
            Text = $"Your version changed {Describe(conflict.Clio)}. The version on disk changed {Describe(conflict.External)}.",
            TextWrapping = TextWrapping.Wrap,
        });
        panel.Children.Add(new TextBlock
        {
            Text = ConflictPreview.Make(conflict.Clio.Data, conflict.External.Data),
            FontFamily = (Microsoft.UI.Xaml.Media.FontFamily)Application.Current.Resources["EditorFont"],
            FontSize = 11, TextWrapping = TextWrapping.Wrap, Opacity = 0.8,
        });
        panel.Children.Add(choices);

        var dialog = new ContentDialog
        {
            Title = $"“{tab.Title}” changed outside Clio",
            Content = panel,
            PrimaryButtonText = "Apply",
            CloseButtonText = "Decide later",
            DefaultButton = ContentDialogButton.Close,
            IsPrimaryButtonEnabled = false,
        };
        choices.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = choices.SelectedIndex >= 0;
        if (await Dialog.ShowAsync(dialog) != ContentDialogResult.Primary) return;

        var choice = choices.SelectedIndex switch { 0 => ConflictChoice.KeepClio, 1 => ConflictChoice.LoadExternal, _ => ConflictChoice.KeepBoth };
        try
        {
            var receipt = await Task.Run(() => AppServices.Instance.Documents.Resolve(choice, tab.Session));
            SaveState.Text = receipt is null ? "Resolved" : "Resolved. The other version is in recovery";
        }
        catch (ConflictResolutionException e)
        {
            var text = e.Failure == ResolutionFailure.ConflictChanged
                ? "The file changed again while you were deciding. Review the new version."
                : "There is nothing left to resolve.";
            await Dialog.Message("Not resolved", text);
        }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException)
        {
            await Dialog.Message("Couldn’t resolve the conflict", e.Message);
        }
        OnTabChanged(tab);
    }

    /// <summary>The file was deleted while the buffer had unsaved changes: settle the conflict, then ask where to save.</summary>
    private async Task KeepDeletedConflictAsync(DocumentTab tab)
    {
        try { await Task.Run(() => AppServices.Instance.Documents.DetachAfterExternalDeletion(tab.Session)); }
        catch (ConflictResolutionException)
        {
            await Dialog.Message("The file is back", "The file reappeared. Review its current version first.");
            OnTabChanged(tab);
            return;
        }
        catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException)
        {
            await Dialog.Message("Couldn’t keep the document", e.Message);
            return;
        }
        OnTabChanged(tab);
        await SaveAsAsync(tab);
    }

    private static string Describe(ConflictSide side) =>
        $"{side.Modified.ToLocalTime():g} ({side.Data.Length:N0} bytes)";
}

/// <summary>Concise display projection of two versions (macOS <c>ConflictPreviewBuilder</c>): the first changed lines of each.</summary>
internal static class ConflictPreview
{
    private const int MaximumBytesPerSide = 256 * 1024;
    private const int MaximumLineLength = 240;

    public static string Make(byte[] mine, byte[] outside)
    {
        var a = Lines(mine);
        var b = Lines(outside);
        var removed = new List<string>();
        var added = new List<string>();
        var changed = 0;
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var left = i < a.Length ? a[i] : null;
            var right = i < b.Length ? b[i] : null;
            if (left == right) continue;
            changed++;
            if (left is not null && removed.Count < 3) removed.Add("− " + Bound(left));
            if (right is not null && added.Count < 3) added.Add("+ " + Bound(right));
        }
        if (changed == 0) return "The two versions differ only in line endings or encoding.";
        var text = new StringBuilder($"{changed:N0} changed line{(changed == 1 ? "" : "s")}\n");
        foreach (var line in removed.Concat(added)) text.AppendLine(line);
        if (mine.Length > MaximumBytesPerSide || outside.Length > MaximumBytesPerSide) text.AppendLine("(preview shows the first 256 KB of each version)");
        return text.ToString().TrimEnd();
    }

    private static string[] Lines(byte[] data) =>
        Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, MaximumBytesPerSide)).Replace("\r\n", "\n").Split('\n');

    private static string Bound(string line) => line.Length <= MaximumLineLength ? line : line[..MaximumLineLength] + "…";
}
