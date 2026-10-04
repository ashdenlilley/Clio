using Xunit;

namespace Clio.Editor.Tests;

public class LineMinimapTests
{
    [Fact]
    public void EmptyAndWhitespaceDocumentsHaveNoStrokes()
    {
        Assert.Empty(LineMinimap.Make("").Strokes);
        Assert.Empty(LineMinimap.Make("  \n\t\r\n").Strokes);
        Assert.Empty(LineMinimap.Make(string.Concat(Enumerable.Repeat(" \n", 40_000))).Strokes);
    }

    [Fact]
    public void LinesGrowDownwardWithLengthsAndUtf16Offsets()
    {
        var m = LineMinimap.Make("Hi\n\n🙂 longer line\nend");
        Assert.Equal([0, 4, 19], m.Strokes.Select(s => s.Offset));
        Assert.True(m.Strokes[0].Width < m.Strokes[1].Width);
        Assert.False(m.IsSampled);
        Assert.Equal(1, m.ActiveIndex(5));
    }

    [Fact]
    public void LargeFilesUseBoundedSortedSampling()
    {
        var source = string.Concat(Enumerable.Repeat("🙂 a line of writing\n", 100_000));
        var m = LineMinimap.Make(source);
        Assert.True(m.IsSampled);
        Assert.InRange(m.Strokes.Count, 1, LineMinimap.MaximumStrokes);
        Assert.Equal(source.Length, m.SourceLength);
        Assert.Equal(m.Strokes.Select(s => s.Offset).Order(), m.Strokes.Select(s => s.Offset));
        foreach (var s in m.Strokes)
        {
            Assert.False(char.IsLowSurrogate(source[s.Offset]));
            Assert.InRange(s.Width, 0, 1);
        }
    }

    [Fact]
    public void ShortViewportKeepsFirstAndLastStroke()
    {
        var m = LineMinimap.Make(string.Concat(Enumerable.Repeat("line\n", 300)));
        var d = m.Displayed(80);
        Assert.Equal(10, d.Count);
        Assert.Equal(m.Strokes[0], d[0]);
        Assert.Equal(m.Strokes[^1], d[^1]);
        Assert.Single(m.Displayed(0));
    }
}

public class TypewriterMathTests
{
    [Fact]
    public void TargetPutsCaretMidpointAtAnchorAndClamps()
    {
        // caret midpoint 1000, viewport 800, anchor .45 -> 1000 - 360 = 640
        Assert.Equal(640, TypewriterMath.TargetScrollOffset(990, 20, 800, 0.45, 5000));
        Assert.Equal(0, TypewriterMath.TargetScrollOffset(10, 20, 800, 0.45, 5000));
        Assert.Equal(4200, TypewriterMath.TargetScrollOffset(4990, 20, 800, 0.45, 5000));
    }

    [Fact]
    public void AnchorIsClampedAndPaddingCoversLargerSide()
    {
        Assert.Equal(0.3, TypewriterMath.ResolveAnchor(0.0));
        Assert.Equal(0.6, TypewriterMath.ResolveAnchor(0.9));
        Assert.Equal(800 * 0.6, TypewriterMath.DocumentPadding(800, 0.6, true));
        Assert.Equal(800 * 0.7, TypewriterMath.DocumentPadding(800, 0.3, true));
        Assert.Equal(64, TypewriterMath.DocumentPadding(800, 0.3, false));
    }

    [Fact]
    public void EaseReturnIsSmoothstepOverTwoSeconds()
    {
        Assert.Equal(100, TypewriterMath.EaseReturn(100, 200, TimeSpan.Zero));
        Assert.Equal(150, TypewriterMath.EaseReturn(100, 200, TimeSpan.FromSeconds(1)));
        Assert.Equal(200, TypewriterMath.EaseReturn(100, 200, TimeSpan.FromSeconds(5)));
    }
}
