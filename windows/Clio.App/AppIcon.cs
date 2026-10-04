using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace Clio.App;

/// <summary>The Clio icon shipped as <c>Assets\Clio.ico</c> next to the program (also embedded as the exe's icon).</summary>
internal static class AppIcon
{
    private static string Path => System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Clio.ico");

    /// <summary>Sets the window's taskbar and Alt+Tab icon. A missing file leaves the default icon.</summary>
    public static void Apply(Window window)
    {
        try { if (File.Exists(Path)) window.AppWindow.SetIcon(Path); }
        catch (Exception) { /* cosmetic only */ }
    }

    /// <summary>A notification-area sized icon handle (caller destroys it), or zero when the file is unavailable.</summary>
    public static IntPtr LoadSmall()
    {
        const uint ImageIcon = 1, LoadFromFile = 0x10, DefaultSize = 0x40;
        return File.Exists(Path) ? LoadImage(IntPtr.Zero, Path, ImageIcon, 0, 0, LoadFromFile | DefaultSize) : IntPtr.Zero;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "LoadImageW")]
    private static extern IntPtr LoadImage(IntPtr instance, string name, uint type, int width, int height, uint flags);
}
