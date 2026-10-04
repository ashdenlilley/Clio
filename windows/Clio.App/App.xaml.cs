using Clio.Core;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace Clio.App;

public partial class App : Application
{
    private static readonly List<MainWindow> EditorWindows = [];
    private static TrayIcon? _tray;
    private static bool _quitting;
    private static bool _shutDown;

    public App() => InitializeComponent();

    /// <summary>Every open editor window, in the order they were opened. UI thread.</summary>
    public static IReadOnlyList<MainWindow> Windows => EditorWindows;

    /// <summary>The editor window the owner used last: where MCP shows documents and prompts.</summary>
    public static MainWindow? LastActiveWindow { get; private set; }

    public static void NoteActive(MainWindow window) => LastActiveWindow = window;

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // With MCP on, Clio stays resident with only its tray icon after the last window closes; Quit ends it.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;

        // Recovery runs before any window can open a file, so an interrupted write or move settles first.
        var services = AppServices.Create();
        services.Start();
        _tray = new TrayIcon(services.Mcp, () => OpenClio(), ShowMcpSettings, Quit);

        var commandLine = Environment.GetCommandLineArgs().Skip(1).ToList();
        if (commandLine.Contains(LoginItem.BackgroundArgument))
        {
            // "Open at login without a window": only worth running if MCP was left on. Otherwise there is nothing to serve.
            if (!services.Mcp.Service.Enabled) Shutdown();
            return;
        }

        var window = OpenWindow();
        // Files passed on the command line (Open with, a registered .md association).
        foreach (var arg in commandLine)
            if (File.Exists(arg)) window.OpenPath(arg);
        window.FocusEditorSoon();
    }

    public static MainWindow OpenWindow()
    {
        var window = new MainWindow();
        EditorWindows.Add(window);
        LastActiveWindow = window;
        window.Activate();
        return window;
    }

    /// <summary>Brings an editor window forward (the tray's "Open Clio"), opening one when none exists.</summary>
    public static MainWindow OpenClio()
    {
        var window = LastActiveWindow ?? EditorWindows.FirstOrDefault();
        if (window is null) return OpenWindow();
        if (window.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
        window.Activate();
        return window;
    }

    private static void ShowMcpSettings()
    {
        AppServices.Instance.Mcp.PrepareSettingsPage();
        SettingsWindow.Show();
    }

    /// <summary>The window that has <paramref name="path"/> open, if any.</summary>
    public static MainWindow? WindowHolding(string path) => EditorWindows.FirstOrDefault(w => w.FindTab(path) is not null);

    public static void WindowClosed(MainWindow window)
    {
        EditorWindows.Remove(window);
        if (ReferenceEquals(LastActiveWindow, window)) LastActiveWindow = EditorWindows.LastOrDefault();
        if (EditorWindows.Count > 0) return;
        // MCP keeps Clio running without a window: clients can still read, and the tray can bring a window back.
        if (!_quitting && AppServices.Instance.Mcp.Service.Enabled) return;
        Shutdown();
    }

    /// <summary>
    /// Quit from the tray (macOS <c>applicationShouldTerminate</c>). MCP stops first, so no client write can slip in while
    /// documents are saving; if a document cannot be saved the quit is cancelled and MCP resumes.
    /// </summary>
    public static async void Quit()
    {
        var services = AppServices.Instance;
        var resumeMcp = services.Mcp.Service.Enabled;
        services.Mcp.Service.QuiesceForQuit();

        var unsaved = false;
        foreach (var tab in EditorWindows.SelectMany(w => w.Tabs).ToList())
        {
            try { tab.Autosaver.Flush(tab.Session); }
            catch (Exception e) when (e is ClioException or IOException or UnauthorizedAccessException) { }
            var session = tab.Session;
            // A conflict or a deleted file is resolved by the owner, and its text is already in recovery.
            if (session.IsDirty && session.IsBackedByFile && session.Conflict is null) unsaved = true;
        }
        if (unsaved)
        {
            if (resumeMcp) services.Mcp.Service.SetEnabled(true);
            await OpenClio().ShowMessageAsync("Clio couldn’t save every document",
                "Quit was cancelled so your unsaved text stays in Clio. Free disk space or restore access to the folder, then try again.");
            return;
        }

        _quitting = true;
        foreach (var window in EditorWindows.ToList()) window.Close();
        if (EditorWindows.Count == 0) Shutdown();
    }

    private static void Shutdown()
    {
        if (_shutDown) return;
        _shutDown = true;
        SettingsWindow.CloseIfOpen();
        _tray?.Dispose();
        AppServices.Instance.Dispose();
        Current.Exit();
    }
}
