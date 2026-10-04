using System.Runtime.InteropServices;
using Clio.Editor;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace Clio.App;

/// <summary>Opens windows at a size in device-independent pixels, scaled for the display they are on.</summary>
public static class WindowSizer
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    /// <summary>
    /// <c>AppWindow.Resize</c> takes physical pixels, so the size is scaled by the window's DPI and kept inside the work
    /// area. Checked against <see cref="WindowSizing"/>.
    /// </summary>
    public static void ResizeDips(Window window, double widthDips, double heightDips)
    {
        var dpi = GetDpiForWindow(WindowNative.GetWindowHandle(window));
        var work = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Nearest).WorkArea;
        var (width, height) = WindowSizing.ToPixels(widthDips, heightDips, dpi, work.Width, work.Height);
        window.AppWindow.Resize(new Windows.Graphics.SizeInt32(width, height));
    }
}
