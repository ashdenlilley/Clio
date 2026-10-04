using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Clio.App;

/// <summary>
/// Opt-in Markdown association. Registers Clio as an "Open with" choice for .md and .markdown under HKCU, which
/// needs no administrator rights. Windows 11 protects the default-app choice, so the user still picks Clio in
/// Settings: this never changes the default on its own.
/// </summary>
public static class FileAssociation
{
    private const string ProgId = "Clio.Markdown";
    private static readonly string[] Extensions = [".md", ".markdown"];

    public static bool IsRegistered
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey($@"Software\Classes\{ProgId}\shell\open\command");
            return key?.GetValue(null) is string command && command.Contains(Environment.ProcessPath ?? "", StringComparison.OrdinalIgnoreCase);
        }
    }

    public static void Register()
    {
        var exe = Environment.ProcessPath ?? throw new InvalidOperationException("Clio’s executable path is unknown.");
        using (var progId = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{ProgId}"))
        {
            progId.SetValue(null, "Markdown document");
            using var icon = progId.CreateSubKey("DefaultIcon");
            icon.SetValue(null, $"\"{exe}\",0");
            using var command = progId.CreateSubKey(@"shell\open\command");
            command.SetValue(null, $"\"{exe}\" \"%1\"");
        }
        foreach (var extension in Extensions)
        {
            using var key = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{extension}\OpenWithProgids");
            key.SetValue(ProgId, Array.Empty<byte>(), RegistryValueKind.None);
        }
        Notify();
    }

    public static void Unregister()
    {
        foreach (var extension in Extensions)
        {
            using var key = Registry.CurrentUser.OpenSubKey($@"Software\Classes\{extension}\OpenWithProgids", writable: true);
            key?.DeleteValue(ProgId, throwOnMissingValue: false);
        }
        Registry.CurrentUser.DeleteSubKeyTree($@"Software\Classes\{ProgId}", throwOnMissingSubKey: false);
        Notify();
    }

    public static void OpenDefaultAppsSettings() =>
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:defaultapps") { UseShellExecute = true });

    [DllImport("shell32.dll")]
    private static extern void SHChangeNotify(int eventId, uint flags, nint item1, nint item2);

    private static void Notify() => SHChangeNotify(0x08000000 /* SHCNE_ASSOCCHANGED */, 0, 0, 0);
}
