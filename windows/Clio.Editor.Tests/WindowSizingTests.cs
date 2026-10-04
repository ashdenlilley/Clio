using Xunit;

namespace Clio.Editor.Tests;

public class WindowSizingTests
{
    [Theory]
    [InlineData(96u, 1100, 760)]
    [InlineData(120u, 1375, 950)]
    [InlineData(144u, 1650, 1140)]
    [InlineData(192u, 2200, 1520)]
    public void DipSizesScaleWithTheDisplay(uint dpi, int width, int height) =>
        Assert.Equal((width, height), WindowSizing.ToPixels(1100, 760, dpi, 10_000, 10_000));

    [Fact]
    public void TheWindowNeverExceedsTheWorkArea()
    {
        Assert.Equal((1280, 680), WindowSizing.ToPixels(1100, 760, 192, 1280, 680));
        Assert.Equal((1100, 700), WindowSizing.ToPixels(1100, 760, 96, 1920, 700));
    }

    [Fact]
    public void AnUnknownDpiOrWorkAreaFallsBackSafely()
    {
        Assert.Equal((1100, 760), WindowSizing.ToPixels(1100, 760, 0, 0, 0));
        Assert.Equal((1, 1), WindowSizing.ToPixels(0, 0, 96, 100, 100));
    }

    [Fact]
    public void FractionalScalesRoundToTheNearestPixel() =>
        Assert.Equal((1001, 1004), WindowSizing.ToPixels(801, 803, 120, 10_000, 10_000));
}
