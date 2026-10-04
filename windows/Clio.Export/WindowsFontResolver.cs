using PdfSharp.Fonts;

namespace Clio.Export;

/// <summary>
/// PDFsharp font source: the TrueType files of the Windows fonts folder (and the per-user fonts folder). Each requested
/// family maps to regular, bold, italic and bold-italic files; a family whose files are missing falls back to a
/// universally installed one (Arial for text, Courier New for code), so export never fails on a trimmed-down system.
/// </summary>
internal sealed class WindowsFontResolver : IFontResolver
{
    private sealed record Family(string Regular, string Bold, string Italic, string BoldItalic, string Fallback);

    private static readonly Dictionary<string, Family> Families = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Segoe UI"] = new("segoeui.ttf", "segoeuib.ttf", "segoeuii.ttf", "segoeuiz.ttf", "Arial"),
        ["Segoe UI Symbol"] = new("seguisym.ttf", "seguisym.ttf", "seguisym.ttf", "seguisym.ttf", "Arial"),
        ["Consolas"] = new("consola.ttf", "consolab.ttf", "consolai.ttf", "consolaz.ttf", "Courier New"),
        ["Arial"] = new("arial.ttf", "arialbd.ttf", "ariali.ttf", "arialbi.ttf", "Arial"),
        ["Courier New"] = new("cour.ttf", "courbd.ttf", "couri.ttf", "courbi.ttf", "Courier New"),
    };

    private readonly string[] _directories =
    [
        Environment.GetFolderPath(Environment.SpecialFolder.Fonts),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "Windows", "Fonts"),
    ];

    private readonly Dictionary<string, byte[]> _cache = [];

    public FontResolverInfo? ResolveTypeface(string familyName, bool isBold, bool isItalic)
    {
        if (!Families.TryGetValue(familyName, out var family)) family = Families["Arial"];
        var file = Pick(family, isBold, isItalic);
        if (Locate(file) is null)
        {
            family = Families[family.Fallback];
            file = Pick(family, isBold, isItalic);
            if (Locate(file) is null) return null;
        }
        // The face name is the file name: GetFont maps it straight back. Symbol-only families have one face, so the
        // requested style is simulated by PDFsharp rather than failing.
        var simulateBold = isBold && file == family.Regular && family.Regular != family.Bold;
        var simulateItalic = isItalic && file == family.Regular && family.Regular != family.Italic;
        return new FontResolverInfo(file, simulateBold, simulateItalic);
    }

    public byte[]? GetFont(string faceName)
    {
        lock (_cache)
        {
            if (_cache.TryGetValue(faceName, out var cached)) return cached;
            if (Locate(faceName) is not { } path) return null;
            return _cache[faceName] = File.ReadAllBytes(path);
        }
    }

    private static string Pick(Family family, bool bold, bool italic) =>
        bold && italic ? family.BoldItalic : bold ? family.Bold : italic ? family.Italic : family.Regular;

    private string? Locate(string file)
    {
        foreach (var directory in _directories)
        {
            var path = Path.Combine(directory, file);
            if (File.Exists(path)) return path;
        }
        return null;
    }
}
