using Clio.Mcp;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Clio.App;

/// <summary>What local MCP needs from an editor window: its live editor, tab adoption, and the native deletion prompt.</summary>
public sealed partial class MainWindow
{
    internal EditorControl EditorSurface => Editor;
    internal DocumentTab? ActiveTab => _active;
    internal bool IsClosing => _closing;

    internal Task ShowMessageAsync(string title, string text) => Dialog.Message(title, text);

    /// <summary>Takes a tab that was opened without a window (an MCP background read) and shows it here.</summary>
    internal void AdoptTab(DocumentTab tab)
    {
        if (_tabs.Contains(tab)) { Activate(tab); return; }
        AddTab(tab);
    }

    /// <summary>
    /// The native confirmation for an MCP deletion request. Only this dialog can approve it: nothing a client sends reaches
    /// it. It names the document, its path and the requesting client, defaults to Cancel, and cancels itself after
    /// <see cref="McpLimits.ApprovalLifetime"/> or when the request is cancelled.
    /// </summary>
    internal async Task<bool> ConfirmMcpDeletionAsync(McpDeletionRequest request, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        Activate();
        var body = new StackPanel { Spacing = 8 };
        body.Children.Add(new TextBlock { Text = $"Requested by {request.ClientName}.", TextWrapping = TextWrapping.Wrap });
        body.Children.Add(new TextBlock { Text = request.FilePath, TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.8, IsTextSelectionEnabled = true });
        body.Children.Add(new TextBlock { Text = "This removes the document from its folder. You can restore it from the Recycle Bin.", TextWrapping = TextWrapping.Wrap });
        var dialog = new ContentDialog
        {
            Title = $"Move {request.Filename} to the Recycle Bin?",
            Content = body,
            PrimaryButtonText = "Move to Recycle Bin",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        using var timer = new CancellationTokenSource();
        // The clock starts when the owner can see the prompt, not while another dialog is still queued ahead of it.
        dialog.Opened += (_, _) => _ = ExpireAsync(dialog, timer.Token);
        dialog.Closed += (_, _) => timer.Cancel();
        using var cancelled = ct.Register(() => dialog.DispatcherQueue.TryEnqueue(dialog.Hide));
        var result = await Dialog.ShowAsync(dialog);
        ct.ThrowIfCancellationRequested();
        return result == ContentDialogResult.Primary;
    }

    private static async Task ExpireAsync(ContentDialog dialog, CancellationToken closed)
    {
        try { await Task.Delay(McpLimits.ApprovalLifetime, closed); }
        catch (OperationCanceledException) { return; }
        dialog.DispatcherQueue.TryEnqueue(dialog.Hide);
    }
}
