namespace Clio.Editor.Commands;

/// <summary>Port of macOS <c>EditorCoordinator.isInlineSlashTrigger</c> and <c>isEmptySlashLine</c>. Offsets are UTF-16.</summary>
public static class SlashTrigger
{
    /// <summary>A typed "/" replacing a valid range opens the palette, unless an IME composition is active.</summary>
    public static bool IsInlineSlashTrigger(string source, int start, int length, string replacement, bool hasMarkedText = false)
    {
        if (hasMarkedText || replacement != "/" || length < 0) return false;
        return start >= 0 && start <= source.Length && length <= source.Length - start;
    }

    /// <summary>True when the line holding a caret at <paramref name="start"/> is blank, so the palette anchors at the caret.</summary>
    public static bool IsEmptySlashLine(string source, int start, int length)
    {
        if (length != 0 || start < 0 || start > source.Length) return false;
        var lineStart = start;
        // A caret between CR and LF belongs to the CRLF terminator of the line that precedes it.
        if (lineStart > 0 && lineStart < source.Length && source[lineStart - 1] == '\r' && source[lineStart] == '\n') lineStart--;
        while (lineStart > 0 && !IsTerminator(source[lineStart - 1])) lineStart--;
        var lineEnd = start;
        while (lineEnd < source.Length && !IsTerminator(source[lineEnd])) lineEnd++;
        if (lineEnd < source.Length) lineEnd += source[lineEnd] == '\r' && lineEnd + 1 < source.Length && source[lineEnd + 1] == '\n' ? 2 : 1;
        return source.AsSpan(lineStart, lineEnd - lineStart).Trim().IsEmpty;
    }

    private static bool IsTerminator(char c) => (int)c is 0x0A or 0x0D or 0x2028 or 0x2029 or 0x85;
}
