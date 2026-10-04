using Clio.Intelligence;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Clio.App;

/// <summary>Settings: folders, the text-file policy, and the opt-in Markdown association.</summary>
public sealed class SettingsWindow : Window
{
    private static SettingsWindow? _open;
    private readonly StackPanel _folders = new() { Spacing = 4 };
    private readonly TextBlock _error = new() { TextWrapping = TextWrapping.Wrap, Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.OrangeRed) };

    public static void Show()
    {
        if (_open is null) _open = new SettingsWindow();
        _open.Activate();
    }

    public static void CloseIfOpen() => _open?.Close();

    private SettingsWindow()
    {
        Title = "Clio Settings";
        SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop { Kind = Microsoft.UI.Composition.SystemBackdrops.MicaKind.BaseAlt };
        AppWindow.Resize(new Windows.Graphics.SizeInt32(600, 780));
        Closed += (_, _) => _open = null;

        var services = AppServices.Instance;
        var panel = new StackPanel { Spacing = 14, Padding = new Thickness(24) };
        panel.Children.Add(new TextBlock { Text = "Settings", Style = (Style)Application.Current.Resources["TitleTextBlockStyle"] });

        var text = new ToggleSwitch
        {
            Header = "Include plain text files", OnContent = "On", OffContent = "Off", IsOn = services.Settings.IncludeTextFiles,
        };
        text.Toggled += (_, _) => services.SetIncludeTextFiles(text.IsOn);
        panel.Children.Add(text);

        var association = new ToggleSwitch
        {
            Header = "Offer Clio in “Open with” for Markdown files", OnContent = "On", OffContent = "Off", IsOn = FileAssociation.IsRegistered,
        };
        association.Toggled += (_, _) =>
        {
            try
            {
                if (association.IsOn) FileAssociation.Register(); else FileAssociation.Unregister();
                _error.Text = "";
            }
            catch (Exception e) when (e is UnauthorizedAccessException or System.Security.SecurityException or InvalidOperationException or IOException)
            {
                _error.Text = e.Message;
                association.IsOn = FileAssociation.IsRegistered;
            }
        };
        panel.Children.Add(association);
        var defaults = new HyperlinkButton { Content = "Make Clio the default in Windows Settings…", Padding = new Thickness(0) };
        defaults.Click += (_, _) => FileAssociation.OpenDefaultAppsSettings();
        panel.Children.Add(defaults);
        panel.Children.Add(_error);

        panel.Children.Add(new TextBlock { Text = "Folders", Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"], Margin = new Thickness(0, 8, 0, 0) });
        panel.Children.Add(_folders);

        panel.Children.Add(BuildAssistedCommandsSection(services));
        Content = new ScrollViewer { Content = panel };

        services.WorkspacesChanged += RebuildFolders;
        Closed += (_, _) => services.WorkspacesChanged -= RebuildFolders;
        RebuildFolders();
    }

    // ---- assisted commands ----------------------------------------------------------------------

    private static TextBlock Note(string text) => new()
    {
        Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.75,
    };

    /// <summary>
    /// The one place Clio's offline promise is relaxed. The copy says exactly what is sent, to whom, and where the key
    /// lives, because turning this on is a privacy decision.
    /// </summary>
    private StackPanel BuildAssistedCommandsSection(AppServices services)
    {
        var intelligence = services.Intelligence;
        var section = new StackPanel { Spacing = 10, Margin = new Thickness(0, 16, 0, 0) };
        section.Children.Add(new TextBlock { Text = "Assisted commands (TypeSafe)", Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });

        var enabled = new ToggleSwitch { Header = "Enable assisted commands", OnContent = "On", OffContent = "Off", IsOn = intelligence.IsEnabled };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(enabled, "settings.intelligence.enabled");
        section.Children.Add(enabled);
        section.Children.Add(Note("Clio is otherwise offline. Turning this on lets it send text over HTTPS to TypeSafe (api.typesafe.ai), a third-party service, to work out what a typed command means and to rebuild the structure of pasted plain text. Your documents are never uploaded on their own, and nothing is sent while this is off."));

        var details = new StackPanel { Spacing = 10 };
        var paste = new ToggleSwitch { Header = "Reformat long plain-text pastes", OnContent = "On", OffContent = "Off", IsOn = intelligence.FormatsPastes };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(paste, "settings.intelligence.formatPastes");
        details.Children.Add(paste);
        details.Children.Add(Note("Sends the pasted text only, and only when it arrives with no Markdown of its own. The command bar sends what you typed there plus whether a document is open, saved to disk, and whether focus mode, typewriter scrolling and the sidebar are on. It never sends the document, its name or its path."));

        var key = new PasswordBox { PlaceholderText = "Paste your TypeSafe API key", Width = 280, MaxLength = 2000 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(key, "settings.intelligence.key");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(key, "TypeSafe API key");
        var save = new Button { Content = "Save" };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(save, "settings.intelligence.save");
        var keyRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        keyRow.Children.Add(key);
        keyRow.Children.Add(save);
        details.Children.Add(new TextBlock { Text = "Your API key" });
        details.Children.Add(keyRow);

        var keyState = new TextBlock { FontSize = 12, Opacity = 0.8 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(keyState, "settings.intelligence.keyState");
        var check = new Button { Content = "Check" };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(check, "settings.intelligence.check");
        var remove = new Button { Content = "Remove" };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(remove, "settings.intelligence.remove");
        var stateRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        stateRow.Children.Add(keyState);
        stateRow.Children.Add(check);
        stateRow.Children.Add(remove);
        details.Children.Add(stateRow);
        details.Children.Add(Note("The key is yours, not Clio's. It is kept in this Windows account's Credential Manager on this device, is never written to Clio's settings file or install folder, and is not synced. Each Windows account adds its own."));
        details.Children.Add(new HyperlinkButton { Content = "Where to get a key", NavigateUri = new Uri("https://docs.typesafe.ai/introduction/quickstart"), Padding = new Thickness(0) });
        section.Children.Add(details);

        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(status, "settings.intelligence.status");
        section.Children.Add(status);

        void Refresh()
        {
            details.Visibility = intelligence.IsEnabled ? Visibility.Visible : Visibility.Collapsed;
            if (enabled.IsOn != intelligence.IsEnabled) enabled.IsOn = intelligence.IsEnabled;
            if (paste.IsOn != intelligence.FormatsPastes) paste.IsOn = intelligence.FormatsPastes;
            key.PlaceholderText = intelligence.HasApiKey ? "Replace the stored key" : "Paste your TypeSafe API key";
            keyState.Text = intelligence.HasApiKey ? "A key is stored in Credential Manager" : "No key stored";
            check.IsEnabled = intelligence.HasApiKey && intelligence.KeyVerification != IntelligenceService.KeyVerificationState.Checking;
            remove.Visibility = check.Visibility = intelligence.HasApiKey ? Visibility.Visible : Visibility.Collapsed;
            status.Text = intelligence.StatusDescription;
            save.IsEnabled = key.Password.Trim().Length > 0;
        }

        enabled.Toggled += (_, _) => { intelligence.IsEnabled = enabled.IsOn; Refresh(); };
        paste.Toggled += (_, _) => intelligence.FormatsPastes = paste.IsOn;
        key.PasswordChanged += (_, _) => save.IsEnabled = key.Password.Trim().Length > 0;
        void SaveKey()
        {
            if (key.Password.Trim().Length == 0) return;
            intelligence.SetApiKey(key.Password);
            key.Password = "";
        }
        save.Click += (_, _) => SaveKey();
        key.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { SaveKey(); e.Handled = true; } };
        check.Click += async (_, _) => await intelligence.VerifyKeyAsync();
        remove.Click += (_, _) => intelligence.ClearApiKey();

        void OnChanged() => DispatcherQueue.TryEnqueue(Refresh);
        intelligence.Changed += OnChanged;
        Closed += (_, _) => intelligence.Changed -= OnChanged;
        Refresh();
        return section;
    }

    private void RebuildFolders()
    {
        _folders.Children.Clear();
        var workspaces = AppServices.Instance.Workspaces.ToList();
        if (workspaces.Count == 0) _folders.Children.Add(new TextBlock { Text = "No folders yet. Use Open folder in the sidebar.", Opacity = 0.7 });
        foreach (var host in workspaces)
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = host.Root, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center });
            var remove = new Button { Content = "Remove" };
            remove.Click += (_, _) => AppServices.Instance.RemoveWorkspace(host);
            Grid.SetColumn(remove, 1);
            row.Children.Add(remove);
            _folders.Children.Add(row);
        }
    }
}
