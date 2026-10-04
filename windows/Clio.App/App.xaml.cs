using Microsoft.UI.Xaml;

namespace Clio.App;

public partial class App : Application
{
    private static readonly List<MainWindow> EditorWindows = [];

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Recovery runs before any window can open a file, so an interrupted write or move settles first.
        AppServices.Create().Start();
        var window = OpenWindow();

        // Files passed on the command line (Open with, a registered .md association).
        foreach (var arg in Environment.GetCommandLineArgs().Skip(1))
            if (File.Exists(arg)) window.OpenPath(arg);
    }

    public static MainWindow OpenWindow()
    {
        var window = new MainWindow();
        EditorWindows.Add(window);
        window.Activate();
        return window;
    }

    /// <summary>The window that has <paramref name="path"/> open, if any.</summary>
    public static MainWindow? WindowHolding(string path) => EditorWindows.FirstOrDefault(w => w.FindTab(path) is not null);

    public static void WindowClosed(MainWindow window)
    {
        EditorWindows.Remove(window);
        if (EditorWindows.Count > 0) return;
        SettingsWindow.CloseIfOpen();
        AppServices.Instance.Dispose();
        Current.Exit();
    }
}
