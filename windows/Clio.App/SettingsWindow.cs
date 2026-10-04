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
        AppIcon.Apply(this);
        Title = "Clio Settings";
        SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop { Kind = Microsoft.UI.Composition.SystemBackdrops.MicaKind.BaseAlt };
        WindowSizer.ResizeDips(this, 600, 780);
        Closed += (_, _) => _open = null;

        var services = AppServices.Instance;
        var panel = new StackPanel { Spacing = 14, Padding = new Thickness(24) };
        panel.Children.Add(new TextBlock { Text = "Settings", Style = (Style)Application.Current.Resources["TitleTextBlockStyle"] });

        var text = new ToggleSwitch
        {
            Header = "Include plain text files", OnContent = "On", OffContent = "Off", IsOn = services.Settings.IncludeTextFiles,
        };
        text.Toggled += (_, _) => services.SetIncludeTextFiles(text.IsOn);
        // A keyboard user lands on the first setting instead of an empty window.
        text.Loaded += (_, _) => text.Focus(FocusState.Programmatic);
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
        panel.Children.Add(BuildMcpSection(services));
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

    // ---- local MCP ------------------------------------------------------------------------------

    private static void Identify(DependencyObject element, string id, string? name = null)
    {
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(element, id);
        if (name is not null) Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, name);
    }

    /// <summary>
    /// Local MCP, matching the macOS Local MCP page: the switch, the endpoint, login autostart, authorizing a named client for
    /// chosen folders, and each client's token and configuration actions. Tokens are secrets; the copy actions keep them
    /// out of clipboard history and clear them after 60 seconds.
    /// </summary>
    private StackPanel BuildMcpSection(AppServices services)
    {
        var mcp = services.Mcp;
        var service = mcp.Service;
        mcp.PrepareSettingsPage();

        var section = new StackPanel { Spacing = 10, Margin = new Thickness(0, 16, 0, 0) };
        section.Children.Add(new TextBlock { Text = "Local MCP", Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] });

        var enabled = new ToggleSwitch { Header = "Enable local MCP", OnContent = "On", OffContent = "Off", IsOn = service.Enabled };
        Identify(enabled, "settings.mcp.enabled");
        section.Children.Add(enabled);
        var status = new TextBlock { FontSize = 12 };
        Identify(status, "settings.mcp.status");
        section.Children.Add(status);
        section.Children.Add(new TextBlock { Text = $"Endpoint: http://127.0.0.1:{Clio.Mcp.McpLimits.Port}/mcp", IsTextSelectionEnabled = true, FontSize = 12 });
        section.Children.Add(Note("Available only while Clio runs, and only on this computer. Authorized clients can read and change the selected folders, including unsaved text. Only deletion asks you to confirm. Browser and hosted connections are not enabled."));

        var login = new ToggleSwitch { Header = "Open Clio at login without a window", OnContent = "On", OffContent = "Off", IsOn = mcp.LoginEnabled };
        Identify(login, "settings.mcp.openAtLogin");
        section.Children.Add(login);
        var loginStatus = new TextBlock { FontSize = 12 };
        Identify(loginStatus, "settings.mcp.loginStatus");
        section.Children.Add(loginStatus);

        section.Children.Add(new TextBlock { Text = "Authorize a client", Margin = new Thickness(0, 8, 0, 0) });
        var name = new TextBox { PlaceholderText = "Client name", MaxLength = 64, Width = 280, HorizontalAlignment = HorizontalAlignment.Left };
        Identify(name, "settings.mcp.clientName", "Client name");
        section.Children.Add(name);
        var folders = new StackPanel { Spacing = 2 };
        section.Children.Add(folders);
        var authorize = new Button { Content = "Authorize selected folders" };
        Identify(authorize, "settings.mcp.authorize");
        section.Children.Add(authorize);

        var clientsHeader = new TextBlock { Margin = new Thickness(0, 8, 0, 0) };
        Identify(clientsHeader, "settings.mcp.clientsHeader");
        section.Children.Add(clientsHeader);
        var clients = new StackPanel { Spacing = 10 };
        section.Children.Add(clients);
        section.Children.Add(Note("Tokens are credentials. Paste them only into your client’s local configuration. Copied tokens are kept out of clipboard history and cleared after 60 seconds; do not share them in chat or logs."));
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.OrangeRed) };
        Identify(error, "settings.mcp.error");
        section.Children.Add(error);

        var selected = new HashSet<Guid>();
        var refreshing = false;

        void RefreshAuthorize()
        {
            authorize.IsEnabled = name.Text.Trim().Length > 0 && selected.Count > 0;
        }

        void Refresh()
        {
            refreshing = true;
            try
            {
                if (enabled.IsOn != service.Enabled) enabled.IsOn = service.Enabled;
                status.Text = service.Status;
                if (login.IsOn != mcp.LoginEnabled) login.IsOn = mcp.LoginEnabled;
                loginStatus.Text = mcp.LoginStatus;

                var workspaces = services.Workspaces.ToList();
                selected.IntersectWith(workspaces.Select(w => w.Id));
                folders.Children.Clear();
                if (workspaces.Count == 0) folders.Children.Add(new TextBlock { Text = "Open a folder in the sidebar to authorize it.", Opacity = 0.7, FontSize = 12 });
                foreach (var workspace in workspaces)
                {
                    var box = new CheckBox { Content = workspace.DisplayName, IsChecked = selected.Contains(workspace.Id) };
                    Identify(box, $"settings.mcp.folder.{workspace.Id}", workspace.DisplayName);
                    box.Checked += (_, _) => { selected.Add(workspace.Id); RefreshAuthorize(); };
                    box.Unchecked += (_, _) => { selected.Remove(workspace.Id); RefreshAuthorize(); };
                    folders.Children.Add(box);
                }
                RefreshAuthorize();

                var list = service.Clients;
                clientsHeader.Text = $"Authorized clients ({service.ConnectedSessions} sessions)";
                clients.Children.Clear();
                if (list.Count == 0) clients.Children.Add(new TextBlock { Text = "No clients yet.", Opacity = 0.7, FontSize = 12 });
                foreach (var client in list) clients.Children.Add(ClientRow(client));

                error.Text = string.Join(" ", new[] { service.ErrorMessage, mcp.Notice }.Where(m => !string.IsNullOrEmpty(m)));
            }
            finally { refreshing = false; }
        }

        StackPanel ClientRow(Clio.Mcp.McpClientInfo client)
        {
            var row = new StackPanel { Spacing = 4 };
            row.Children.Add(new TextBlock { Text = client.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            Button Action(string label, string id, Action run)
            {
                var button = new Button { Content = label };
                Identify(button, $"settings.mcp.{id}.{client.Id}", $"{label} for {client.Name}");
                button.Click += (_, _) => run();
                return button;
            }
            var first = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            first.Children.Add(Action("Copy token", "copyToken", () => mcp.CopyToken(client.Id)));
            first.Children.Add(Action("Copy Claude Desktop config", "copyDesktop", () => mcp.CopyDesktopConfiguration(client.Id)));
            first.Children.Add(Action("Add to Claude Desktop", "writeDesktop", () => mcp.WriteClaudeDesktopConfiguration(client.Id)));
            var second = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            second.Children.Add(Action("Copy Claude Code config", "copyCode", () => mcp.CopyClaudeCodeConfiguration(client.Id)));
            second.Children.Add(Action("Remove", "revoke", () => service.Revoke(client.Id)));
            row.Children.Add(first);
            row.Children.Add(second);
            return row;
        }

        enabled.Toggled += (_, _) => { if (!refreshing) mcp.SetEnabled(enabled.IsOn); };
        login.Toggled += (_, _) => { if (!refreshing) mcp.SetLoginEnabled(login.IsOn); };
        name.TextChanged += (_, _) => RefreshAuthorize();
        authorize.Click += (_, _) =>
        {
            var added = service.AddClient(name.Text.Trim(), selected.ToHashSet());
            if (added is null) return;
            name.Text = "";
            selected.Clear();
        };

        void OnChanged() => DispatcherQueue.TryEnqueue(Refresh);
        mcp.Changed += OnChanged;
        services.WorkspacesChanged += OnChanged;
        Closed += (_, _) => { mcp.Changed -= OnChanged; services.WorkspacesChanged -= OnChanged; };
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
