using System.Text;
using System.Text.RegularExpressions;

namespace Clio.Export;

/// <summary>What an export may carry out of a document. Shared behaviour: <c>spec/vectors/export-policy.json</c>.</summary>
public static partial class ExportContentPolicy
{
    [GeneratedRegex("^[A-Za-z][A-Za-z0-9+.-]*(?=:)")]
    private static partial Regex SchemeRegex();

    private static readonly HashSet<string> AllowedSchemes = ["http", "https", "mailto"];

    /// <summary>
    /// A link survives export only if it is untrimmed-clean, free of control characters, parses as a URI reference and is
    /// relative (not rooted) or uses http, https or mailto. Anything else loses its destination; the text stays.
    /// </summary>
    public static string? SafeLink(string value)
    {
        if (value != value.Trim()) return null;
        foreach (var rune in value.EnumerateRunes())
            if (rune.Value <= 0x20 || (rune.Value is >= 0x7f and <= 0x9f)) return null;
        if (!IsUriReference(value)) return null;

        var scheme = SchemeRegex().Match(value);
        if (!scheme.Success) return value.StartsWith('/') || value.StartsWith('\\') ? null : value;
        return AllowedSchemes.Contains(scheme.Value.ToLowerInvariant()) ? value : null;
    }

    // RFC 3986 characters plus "%XX" escapes and non-ASCII text; Foundation's URLComponents rejects the rest.
    private static bool IsUriReference(string value)
    {
        for (var i = 0; i < value.Length; i++)
        {
            var c = value[i];
            if (c > 0x7f) continue;
            if (c == '%')
            {
                if (i + 2 >= value.Length || !Uri.IsHexDigit(value[i + 1]) || !Uri.IsHexDigit(value[i + 2])) return false;
                i += 2;
                continue;
            }
            if (!(char.IsAsciiLetterOrDigit(c) || "-._~:/?#[]@!$&'()*+,;=".Contains(c))) return false;
        }
        return true;
    }

    /// <summary>Controls other than TAB, LF and CR, and C1 controls, never reach HTML output.</summary>
    public static bool IsDisallowedControl(int value) =>
        (value < 0x20 && value != 0x09 && value != 0x0a && value != 0x0d) || (value is >= 0x7f and <= 0x9f);

    public static string EscapeHtml(string value)
    {
        var builder = new StringBuilder(value.Length);
        AppendEscapedHtml(builder, value);
        return builder.ToString();
    }

    public static void AppendEscapedHtml(StringBuilder builder, string value)
    {
        foreach (var c in value)
        {
            switch (c)
            {
                case '&': builder.Append("&amp;"); break;
                case '<': builder.Append("&lt;"); break;
                case '>': builder.Append("&gt;"); break;
                case '"': builder.Append("&quot;"); break;
                case '\'': builder.Append("&#39;"); break;
                default:
                    builder.Append(IsDisallowedControl(c) ? '�' : c);
                    break;
            }
        }
    }

    /// <summary>"fn-" plus the lowercase hex of the label's UTF-8 bytes; labels are hostile input, ids must be inert.</summary>
    public static string SafeFootnoteId(string label) =>
        label.Length == 0 ? "fn-empty" : "fn-" + Convert.ToHexStringLower(Encoding.UTF8.GetBytes(label));
}
