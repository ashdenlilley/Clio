using System.Runtime.InteropServices;
using Clio.Mcp;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Win32;
using Windows.ApplicationModel.DataTransfer;

namespace Clio.App;

/// <summary>
/// The app's side of local MCP (macOS <c>ClioMCPService</c> plus its menu bar actions): the library service, the
/// live-document host, opt-in login autostart and clipboard hygiene for secrets. <see cref="Changed"/> always fires on
/// the UI thread. Nothing here listens, touches Credential Manager or writes the Run key until the owner asks.
/// </summary>
public sealed class McpController : IDisposable
{
    public const string BridgeFileName = "clio-mcp-bridge.exe";

    private readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();

    public AppMcpHost Host { get; }
    public McpService Service { get; }

    /// <summary>A problem from an app-side action (login item, bridge file, clipboard), shown beside the service's own error.</summary>
    public string? Notice { get; private set; }

    public event Action? Changed;

    public McpController()
    {
        Host = new AppMcpHost(_ui);
        var store = new CredentialMcpClientStore(new WindowsCredentialVault(), CredentialMcpClientStore.DefaultMetadataPath);
        Service = new McpService(Host, store);
        Service.Changed += () => _ui.TryEnqueue(OnServiceChanged);
    }

    /// <summary>Where Claude Desktop launches the bridge from: next to <c>Clio.exe</c>.</summary>
    public static string BridgePath => Path.Combine(AppContext.BaseDirectory, BridgeFileName);

    /// <summary>Call once at launch, after recovery and after the workspaces exist.</summary>
    public void StartConfigured()
    {
        Host.Attach();
        Service.StartConfigured();
    }

    private void OnServiceChanged()
    {
        // A paused or stopped service holds no background documents: nothing keeps reading files on a client's behalf.
        if (!Service.Enabled) Host.ClearBackground();
        Changed?.Invoke();
    }

    public void SetEnabled(bool enabled)
    {
        Notice = null;
        Service.SetEnabled(enabled);
        Changed?.Invoke();
    }

    /// <summary>Loads stored clients and login state for the settings page, however Settings was opened.</summary>
    public void PrepareSettingsPage() => Service.PrepareSettingsPage();

    // ---- secrets -------------------------------------------------------------------------------

    public void CopyToken(Guid id) => CopySecret(Service.TokenText(id));

    public void CopyDesktopConfiguration(Guid id)
    {
        CopySecret(Service.DesktopConfig(id, BridgePath));
        if (!File.Exists(BridgePath)) Notice = $"{BridgeFileName} was not found next to Clio.exe. The configuration names that path anyway.";
        Changed?.Invoke();
    }

    public void CopyClaudeCodeConfiguration(Guid id) => CopySecret(Service.ClaudeCodeConfig(id));

    /// <summary>Merges the client into Claude Desktop's own configuration file, keeping the owner's other servers.</summary>
    public bool WriteClaudeDesktopConfiguration(Guid id)
    {
        Notice = null;
        var written = Service.WriteClaudeDesktopConfig(id, BridgePath);
        if (written && !File.Exists(BridgePath)) Notice = $"Claude Desktop was updated, but {BridgeFileName} was not found next to Clio.exe.";
        Changed?.Invoke();
        return written;
    }

    private void CopySecret(string? secret)
    {
        Notice = null;
        if (secret is null) { Notice = "That client no longer has a token."; Changed?.Invoke(); return; }
        try { ClipboardGuard.CopySecret(secret); }
        catch (Exception e) when (e is COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            Notice = "Clio could not use the clipboard. Try again.";
        }
        Changed?.Invoke();
    }

    // ---- login ---------------------------------------------------------------------------------

    public bool LoginEnabled => LoginItem.IsEnabled;
    public string LoginStatus => LoginItem.Status;

    public void SetLoginEnabled(bool enabled)
    {
        Notice = null;
        try { LoginItem.Set(enabled); }
        catch (Exception e) when (e is UnauthorizedAccessException or System.Security.SecurityException or IOException or InvalidOperationException)
        {
            Notice = "The login setting could not be changed. Check Settings, Apps, Startup.";
        }
        Changed?.Invoke();
    }

    public void Dispose()
    {
        ClipboardGuard.ClearIfStillOurs();
        Service.Dispose();
        Host.ClearBackground();
    }
}

/// <summary>
/// Copies a secret so it stays out of clipboard history and the cloud clipboard, then clears it after 60 seconds if
/// nothing else has been copied since (macOS compares the pasteboard change count; Windows has the sequence number).
/// </summary>
public static class ClipboardGuard
{
    public static readonly TimeSpan ClearAfter = TimeSpan.FromSeconds(60);

    private static DispatcherTimer? _timer;
    private static uint _sequence;

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    public static void CopySecret(string secret)
    {
        var package = new DataPackage();
        package.SetText(secret);
        Clipboard.SetContentWithOptions(package, new ClipboardContentOptions { IsAllowedInHistory = false, IsRoamable = false });
        _sequence = GetClipboardSequenceNumber();

        _timer?.Stop();
        _timer = new DispatcherTimer { Interval = ClearAfter };
        _timer.Tick += (_, _) => ClearIfStillOurs();
        _timer.Start();
    }

    /// <summary>Clears the clipboard only when it still holds what <see cref="CopySecret"/> put there.</summary>
    public static void ClearIfStillOurs()
    {
        _timer?.Stop();
        _timer = null;
        if (_sequence == 0) return;
        try { if (GetClipboardSequenceNumber() == _sequence) Clipboard.Clear(); }
        catch (Exception e) when (e is COMException or InvalidOperationException) { }
        _sequence = 0;
    }
}

/// <summary>
/// "Open Clio at login without a window" (macOS <c>SMAppService.mainApp</c>): one value in the current user's Run key,
/// written only when the owner turns it on and removed when they turn it off. Windows lets the owner switch a startup
/// app off in Settings, which is recorded under StartupApproved; that is reported rather than overridden.
/// </summary>
public static class LoginItem
{
    public const string BackgroundArgument = "--background";

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    private const string ValueName = "Clio";

    /// <summary>The command line stored in the Run key for <paramref name="exe"/>.</summary>
    public static string Command(string exe) => $"\"{exe}\" {BackgroundArgument}";

    public static bool IsEnabled => Registered(out _);

    /// <summary>Windows Settings has this startup entry switched off.</summary>
    public static bool IsBlockedByWindows
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(ApprovedKey);
            return key?.GetValue(ValueName) is byte[] { Length: > 0 } flags && (flags[0] & 1) == 1;
        }
    }

    public static string Status =>
        !IsEnabled ? "Open at login is off"
        : IsBlockedByWindows ? "Turned off in Windows Settings, Apps, Startup"
        : "Open at login is enabled";

    public static void Set(bool enabled)
    {
        if (enabled)
        {
            var exe = Environment.ProcessPath ?? throw new InvalidOperationException("Clio could not find its own program.");
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            key.SetValue(ValueName, Command(exe), RegistryValueKind.String);
            // Registering again is the owner's explicit choice, so lift an earlier "off" in Startup settings.
            using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey, writable: true);
            approved?.DeleteValue(ValueName, throwOnMissingValue: false);
        }
        else
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            key?.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }

    private static bool Registered(out string? command)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        command = key?.GetValue(ValueName) as string;
        return command is not null && Environment.ProcessPath is { } exe
            && command.StartsWith($"\"{exe}\"", StringComparison.OrdinalIgnoreCase);
    }
}
