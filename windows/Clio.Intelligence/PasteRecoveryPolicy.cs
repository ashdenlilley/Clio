using Clio.Editor;

namespace Clio.Intelligence;

/// <summary>
/// When a recovered paste may replace what was pasted (macOS <c>PasteStructureController</c>). The paste itself already
/// happened and the writer saw it land; the replacement is only an offer that arrives a moment later, so it applies only
/// while it still describes exactly what is there.
/// </summary>
public static class PasteRecoveryPolicy
{
    /// <summary>
    /// A paste is only reformatted while it is still the last thing that happened. Past this the writer has moved on and
    /// a replacement under their caret would be an ambush.
    /// </summary>
    public static readonly TimeSpan StaleAfter = TimeSpan.FromSeconds(20);

    /// <summary>
    /// True when <paramref name="range"/> still holds exactly <paramref name="original"/> and the answer arrived in time.
    /// Anything else means the writer has edited since, and the recovered Markdown no longer describes what is there.
    /// </summary>
    public static bool CanApply(string bufferText, TextRange range, string original, TimeSpan elapsed) =>
        elapsed < StaleAfter
        && range.Start >= 0
        && range.Length == original.Length
        && range.End <= bufferText.Length
        && bufferText.AsSpan(range.Start, range.Length).SequenceEqual(original);
}
