using Xunit;

namespace Clio.Editor.Tests;

public class EditorPaletteTests
{
    // Windows "High Contrast Black" and "High Contrast White" system colours.
    private static readonly SystemColors Black = new(
        Rgb.FromHex(0x000000), Rgb.FromHex(0xFFFFFF), Rgb.FromHex(0x3FF23F), Rgb.FromHex(0x1AEBFF), Rgb.FromHex(0x000000), Rgb.FromHex(0xFFFF00));

    private static readonly SystemColors White = new(
        Rgb.FromHex(0xFFFFFF), Rgb.FromHex(0x000000), Rgb.FromHex(0x600000), Rgb.FromHex(0x37006E), Rgb.FromHex(0xFFFFFF), Rgb.FromHex(0x00009F));

    [Fact]
    public void ContrastMatchesWcagReferenceValues()
    {
        Assert.Equal(21.0, Rgb.Contrast(Rgb.FromHex(0x000000), Rgb.FromHex(0xFFFFFF)), 3);
        Assert.Equal(1.0, Rgb.Contrast(Rgb.FromHex(0x777777), Rgb.FromHex(0x777777)), 3);
        // #767676 on white is the well-known 4.54:1 AA boundary.
        Assert.Equal(4.54, Rgb.Contrast(Rgb.FromHex(0x767676), Rgb.FromHex(0xFFFFFF)), 2);
    }

    [Fact]
    public void StandardBodyTextHasAaaContrastOnTheCanvas()
    {
        var p = EditorPalette.Standard;
        Assert.True(Rgb.Contrast(p.Foreground, p.Background) >= 7);
        Assert.True(Rgb.Contrast(p.Emphasis, p.Background) >= 7);
        Assert.True(Rgb.Contrast(p.Reference, p.Background) >= 4.5);
        Assert.True(Rgb.Contrast(p.Literal, p.Background) >= 4.5);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void HighContrastUsesOnlySystemColours(bool white)
    {
        var colors = white ? White : Black;
        var p = EditorPalette.HighContrast(colors);
        Assert.True(p.IsHighContrast);
        Assert.Equal(colors.Window, p.Background);
        Assert.Equal(colors.WindowText, p.Foreground);
        Assert.Equal(colors.WindowText, p.Emphasis);
        // Hue-coded roles collapse to the text colour so nothing depends on a colour the user did not pick.
        Assert.Equal(colors.WindowText, p.Literal);
        Assert.Equal(colors.WindowText, p.Meta);
        Assert.Equal(colors.WindowText, p.Marker);
        Assert.Equal(colors.Hotlight, p.Reference);
        Assert.Equal(colors.GrayText, p.Dimmed);
        Assert.Equal(colors.Highlight, p.Selection);
        Assert.Equal(colors.HighlightText, p.SelectionText);
        Assert.Equal(colors.Window, p.Panel);
        Assert.Equal(colors.WindowText, p.PanelBorder);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void HighContrastPairsStayReadable(bool white)
    {
        var p = EditorPalette.HighContrast(white ? White : Black);
        Assert.True(Rgb.Contrast(p.Foreground, p.Background) >= 7);
        Assert.True(Rgb.Contrast(p.Reference, p.Background) >= 7);
        Assert.True(Rgb.Contrast(p.SelectionText!.Value, p.Selection) >= 7);
        Assert.True(Rgb.Contrast(p.Dimmed, p.Background) >= 4.5);
    }

    [Fact]
    public void ResolveReadsSystemColoursOnlyInHighContrast()
    {
        var reads = 0;
        SystemColors Read() { reads++; return Black; }
        Assert.Same(EditorPalette.Standard, EditorPalette.Resolve(false, Read));
        Assert.Equal(0, reads);
        Assert.True(EditorPalette.Resolve(true, Read).IsHighContrast);
        Assert.Equal(1, reads);
    }
}
