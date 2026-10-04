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
        AppWindow.Resize(new Windows.Graphics.SizeInt32(560, 560));
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
        Content = new ScrollViewer { Content = panel };

        services.WorkspacesChanged += RebuildFolders;
        Closed += (_, _) => services.WorkspacesChanged -= RebuildFolders;
        RebuildFolders();
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
