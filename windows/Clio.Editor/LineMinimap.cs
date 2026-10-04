using System.Globalization;

namespace Clio.Editor;

/// <summary>Port of macOS <c>LineMinimapSnapshot</c>. Offsets are UTF-16 code units.</summary>
public sealed record LineMinimap(IReadOnlyList<LineMinimap.Stroke> Strokes, int SourceLength, bool IsSampled)
{
    public readonly record struct Stroke(int Offset, double Width);

    public const int MaximumStrokes = 160;
    private const int SampleThreshold = 65_536;
    public static LineMinimap Empty { get; } = new([], 0, false);

    public static LineMinimap Make(string source)
    {
        var length = source.Length;
        if (length == 0) return Empty;
        var lines = new List<Stroke>();

        if (length > SampleThreshold)
        {
            for (var index = 0; index < MaximumStrokes; index++)
            {
                var offset = (int)((long)index * length / MaximumStrokes);
                if (offset > 0 && char.IsLowSurrogate(source[offset])) offset--;
                var sample = source.AsSpan(offset, Math.Min(128, length - offset));
                var eol = sample.IndexOfAny('\n', '\r');
                if (eol >= 0) sample = sample[..eol];
                var count = NonWhitespaceElements(sample);
                if (count > 0) lines.Add(new Stroke(offset, Math.Min(1, count / 72.0)));
            }
            return new LineMinimap(lines, length, true);
        }

        var pos = 0;
        while (pos < length)
        {
            var end = pos;
            while (end < length && source[end] is not ('\n' or '\r')) end++;
            var next = end;
            if (next < length) next += source[next] == '\r' && next + 1 < length && source[next + 1] == '\n' ? 2 : 1;
            var count = source.AsSpan(pos, end - pos).Trim(" \t").Length == 0
                ? 0
                : StringInfo.ParseCombiningCharacters(source[pos..end].Trim(' ', '\t')).Length;
            if (count > 0) lines.Add(new Stroke(pos, Math.Min(1, count / 72.0)));
            if (next <= pos) break;
            pos = next;
        }
        if (lines.Count > MaximumStrokes)
        {
            var all = lines;
            lines = [.. Enumerable.Range(0, MaximumStrokes).Select(i => all[i * (all.Count - 1) / (MaximumStrokes - 1)])];
            return new LineMinimap(lines, length, true);
        }
        return new LineMinimap(lines, length, false);
    }

    public int ActiveIndex(int offset)
    {
        for (var i = Strokes.Count - 1; i >= 0; i--) if (Strokes[i].Offset <= offset) return i;
        return 0;
    }

    /// <summary>Strokes that fit <paramref name="height"/> at 8 px each, always keeping first and last.</summary>
    public IReadOnlyList<Stroke> Displayed(double height)
    {
        var capacity = Math.Max(1, Math.Min(MaximumStrokes, (int)(Math.Max(0, height) / 8)));
        if (Strokes.Count <= capacity) return Strokes;
        if (capacity == 1) return [Strokes[0]];
        return [.. Enumerable.Range(0, capacity).Select(i => Strokes[i * (Strokes.Count - 1) / (capacity - 1)])];
    }

    private static int NonWhitespaceElements(ReadOnlySpan<char> s)
    {
        var count = 0;
        var e = StringInfo.GetTextElementEnumerator(s.ToString());
        while (e.MoveNext()) if (!string.IsNullOrWhiteSpace((string)e.Current)) count++;
        return count;
    }
}
