namespace Clio.Editor;

/// <summary>
/// Pure math for opening a window at a size given in device-independent pixels (DIPs). <c>AppWindow.Resize</c> takes
/// physical pixels, so a window sized 1100 x 760 would open at 55% of its intended size on a 200% display.
/// </summary>
public static class WindowSizing
{
    public const double BaselineDpi = 96;

    /// <summary>
    /// Scales a DIP size to physical pixels for <paramref name="dpi"/> and keeps it inside the work area, so a window
    /// designed for a large screen still opens fully visible on a small or heavily scaled one.
    /// </summary>
    public static (int Width, int Height) ToPixels(double widthDips, double heightDips, uint dpi, int workAreaWidth, int workAreaHeight)
    {
        var scale = dpi == 0 ? 1 : dpi / BaselineDpi;
        var width = (int)Math.Round(widthDips * scale);
        var height = (int)Math.Round(heightDips * scale);
        if (workAreaWidth > 0) width = Math.Min(width, workAreaWidth);
        if (workAreaHeight > 0) height = Math.Min(height, workAreaHeight);
        return (Math.Max(1, width), Math.Max(1, height));
    }
}
