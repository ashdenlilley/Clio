using System.Globalization;
using System.Text;

namespace Clio.Core;

/// <summary>A folder Clio watches and indexes. <see cref="Id"/> is stable across launches.</summary>
public sealed record WorkspaceDescriptor(Guid Id, string RootPath);

/// <summary>A document found by the scanner, with the stable id the identity store resolved for it.</summary>
public sealed record WorkspaceFile(Guid DocumentId, string Path, string RelativePath, long ByteCount, DateTimeOffset Modified);

/// <summary>A UTF-16 range inside a path or an excerpt.</summary>
public readonly record struct TextSpan(int Start, int Length);

/// <summary>Contract: spec/vectors/search-queries.json. The limit clamps into 1...500.</summary>
public sealed record SearchQuery
{
    public const int MaximumResults = 500;

    public SearchQuery(string text, Guid? workspaceFilter = null, bool includesIgnored = false, int limit = 100)
    {
        Text = text;
        WorkspaceFilter = workspaceFilter;
        IncludesIgnored = includesIgnored;
        Limit = Clamp(limit);
    }

    public string Text { get; }
    public Guid? WorkspaceFilter { get; }
    public bool IncludesIgnored { get; }
    public int Limit { get; }

    public static int Clamp(int limit) => Math.Max(1, Math.Min(limit, MaximumResults));
}

public sealed record SearchResult(
    Guid DocumentId,
    Guid WorkspaceId,
    string RelativePath,
    string? Excerpt,
    TextSpan? DocumentMatchRange,
    TextSpan? ExcerptMatchRange,
    double Score);

/// <summary>One step of a progressive search. The last batch has <see cref="IsFinal"/> set.</summary>
public sealed record SearchBatch(IReadOnlyList<SearchResult> Results, bool IsFinal);

public sealed class SearchIndexException(string message, Exception? inner = null) : ClioException(message, inner);

/// <summary>Query construction shared with macOS through <c>spec/vectors/search-queries.json</c>.</summary>
public static class SearchQueryText
{
    public const int MaximumTerms = 16;
    public const int MaximumTermLength = 128;

    /// <summary>
    /// Splits on every text element that is not a letter, a number or '_'. Working on text elements keeps a
    /// combining mark with its base letter, so a decomposed "café" stays one term.
    /// </summary>
    public static IReadOnlyList<string> Terms(string query)
    {
        var terms = new List<string>();
        var current = new StringBuilder();
        var elements = StringInfo.GetTextElementEnumerator(query);
        while (elements.MoveNext())
        {
            var element = (string)elements.Current;
            if (IsWordElement(element)) current.Append(element);
            else Flush();
        }
        Flush();
        return terms;

        void Flush()
        {
            if (current.Length == 0) return;
            if (terms.Count < MaximumTerms) terms.Add(Prefix(current.ToString()));
            current.Clear();
        }
    }

    public static string? FullTextQuery(IReadOnlyList<string> terms) =>
        terms.Count == 0 ? null : string.Join(" AND ", terms.Select(t => "\"" + t.Replace("\"", "\"\"") + "\"*"));

    public static string EscapeLike(string input) =>
        input.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_");

    private static bool IsWordElement(string element)
    {
        if (element == "_") return true;
        var rune = Rune.GetRuneAt(element, 0);
        return Rune.IsLetter(rune) || Rune.IsNumber(rune);
    }

    /// <summary>The first 128 characters, never splitting a text element.</summary>
    private static string Prefix(string term)
    {
        var count = 0;
        var end = 0;
        var elements = StringInfo.GetTextElementEnumerator(term);
        while (count < MaximumTermLength && elements.MoveNext())
        {
            count++;
            end = elements.ElementIndex + ((string)elements.Current).Length;
        }
        return term[..end];
    }
}
