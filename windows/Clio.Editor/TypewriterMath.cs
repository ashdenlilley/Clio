namespace Clio.Editor;

/// <summary>
/// Pure math behind typewriter scrolling (macOS <c>TypewriterScroller</c>). The control owns timers and
/// scroll state; this type decides where to scroll and how far into an ease-back a given moment is.
/// </summary>
public static class TypewriterMath
{
    public const double DefaultAnchor = 0.45;
    public const double MinimumAnchor = 0.3;
    public const double MaximumAnchor = 0.6;
    public const double VerticalPadding = 64;
    public static readonly TimeSpan ReturnDuration = TimeSpan.FromSeconds(2);

    public static double ResolveAnchor(double anchor) => Math.Clamp(anchor, MinimumAnchor, MaximumAnchor);

    /// <summary>Document padding above and below the text so any line can reach the anchor.</summary>
    public static double DocumentPadding(double viewportHeight, double anchor, bool enabled)
    {
        if (!enabled) return VerticalPadding;
        var a = ResolveAnchor(anchor);
        return Math.Max(VerticalPadding, viewportHeight * Math.Max(a, 1 - a));
    }

    /// <summary>Scroll offset that puts the caret's vertical midpoint at the anchor, clamped to the document.</summary>
    public static double TargetScrollOffset(double caretTop, double caretHeight, double viewportHeight, double anchor, double documentHeight)
    {
        var requested = caretTop + caretHeight / 2 - viewportHeight * ResolveAnchor(anchor);
        var max = Math.Max(0, documentHeight - viewportHeight);
        return Math.Clamp(requested, 0, max);
    }

    /// <summary>Smoothstep ease from <paramref name="start"/> to <paramref name="target"/>; progress is 0..1 of <see cref="ReturnDuration"/>.</summary>
    public static double EaseReturn(double start, double target, TimeSpan elapsed)
    {
        var progress = Math.Clamp(elapsed / ReturnDuration, 0, 1);
        var eased = progress * progress * (3 - 2 * progress);
        return start + (target - start) * eased;
    }
}
