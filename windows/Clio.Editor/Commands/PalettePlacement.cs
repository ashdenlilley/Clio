namespace Clio.Editor.Commands;

public readonly record struct PaletteFrame(double X, double Y, double Width, double Height);

/// <summary>Port of macOS <c>CommandPalettePlacement</c>: fit under (or flip above) an anchor inside a window.</summary>
public static class PalettePlacement
{
    public static PaletteFrame FrameBelow(double anchorX, double anchorY, double anchorHeight, double windowWidth, double windowHeight)
    {
        var width = Math.Min(420, Math.Max(1, windowWidth - 32));
        var x = Math.Min(Math.Max(16, anchorX), Math.Max(16, windowWidth - width - 16));
        var below = anchorY + anchorHeight + 8;
        var belowSpace = windowHeight - 16 - below;
        var placeBelow = belowSpace >= 160;
        var availableHeight = placeBelow ? belowSpace : anchorY - 24;
        var height = Math.Min(400, Math.Max(1, Math.Min(windowHeight - 32, availableHeight)));
        var preferredY = placeBelow ? below : anchorY - height - 8;
        var y = Math.Min(Math.Max(16, preferredY), Math.Max(16, windowHeight - height - 16));
        return new PaletteFrame(x, y, width, height);
    }
}
