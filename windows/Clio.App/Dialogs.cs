using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Clio.App;

/// <summary>ContentDialog helpers. WinUI allows one open dialog per window, so requests queue.</summary>
public sealed class Dialogs(Func<XamlRoot> root)
{
    private readonly SemaphoreSlim _one = new(1, 1);

    /// <summary>Shows a dialog with up to three buttons and returns the one pressed (<see cref="ContentDialogResult.None"/> for close).</summary>
    public async Task<ContentDialogResult> ShowAsync(string title, object? content, string primary, string? secondary = null, string close = "Cancel", bool destructive = false)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = content is string text ? new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap } : content,
            PrimaryButtonText = primary,
            SecondaryButtonText = secondary ?? "",
            CloseButtonText = close,
            DefaultButton = destructive ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        if (destructive) dialog.PrimaryButtonStyle = (Style)Application.Current.Resources["AccentButtonStyle"];
        return await ShowAsync(dialog);
    }

    /// <summary>Shows a prepared dialog once any open one has closed.</summary>
    public async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        await _one.WaitAsync();
        try
        {
            dialog.XamlRoot = root();
            return await dialog.ShowAsync();
        }
        finally { _one.Release(); }
    }

    public Task Message(string title, string text) => ShowAsync(title, text, primary: "OK", close: "");

    /// <summary>Asks for one line of text. Returns null when cancelled.</summary>
    public async Task<string?> PromptAsync(string title, string message, string initial, string primary)
    {
        var box = new TextBox { Text = initial, MinWidth = 320 };
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(box);
        box.Loaded += (_, _) =>
        {
            box.Focus(FocusState.Programmatic);
            var dot = initial.LastIndexOf('.');
            box.Select(0, dot > 0 ? dot : initial.Length);
        };
        var result = await ShowAsync(title, panel, primary);
        return result == ContentDialogResult.Primary ? box.Text.Trim() : null;
    }
}
