namespace Clio.Editor;

/// <summary>An opaque sRGB colour. The editor library stays UI-framework free; the app converts at the edge.</summary>
public readonly record struct Rgb(byte R, byte G, byte B)
{
    public static Rgb FromHex(int value) => new((byte)(value >> 16), (byte)(value >> 8), (byte)value);

    /// <summary>WCAG relative luminance.</summary>
    public double Luminance
    {
        get
        {
            static double Channel(byte c)
            {
                var s = c / 255.0;
                return s <= 0.03928 ? s / 12.92 : Math.Pow((s + 0.055) / 1.055, 2.4);
            }
            return 0.2126 * Channel(R) + 0.7152 * Channel(G) + 0.0722 * Channel(B);
        }
    }

    /// <summary>WCAG contrast ratio, 1 to 21.</summary>
    public static double Contrast(Rgb a, Rgb b)
    {
        var (hi, lo) = a.Luminance >= b.Luminance ? (a.Luminance, b.Luminance) : (b.Luminance, a.Luminance);
        return (hi + 0.05) / (lo + 0.05);
    }
}

/// <summary>The system high-contrast colour slots (<c>GetSysColor</c> window, window text, highlight, ...).</summary>
public readonly record struct SystemColors(Rgb Window, Rgb WindowText, Rgb GrayText, Rgb Highlight, Rgb HighlightText, Rgb Hotlight);

/// <summary>
/// Colours for the editor and its palette. <see cref="Standard"/> is the macOS dark appearance
/// (<c>Palette.swift</c>). <see cref="HighContrast"/> uses only the user's system colours, so semantic hues
/// collapse to the text colour and meaning is carried by weight, style and underline instead.
/// </summary>
public sealed record EditorPalette(
    bool IsHighContrast,
    Rgb Background,
    Rgb Foreground,
    Rgb Emphasis,
    Rgb Muted,
    Rgb Marker,
    Rgb Dimmed,
    Rgb Literal,
    Rgb Reference,
    Rgb Meta,
    Rgb Selection,
    Rgb? SelectionText,
    Rgb Caret,
    Rgb Panel,
    Rgb PanelBorder,
    Rgb PanelSelection)
{
    public static EditorPalette Standard { get; } = new(
        IsHighContrast: false,
        Background: Rgb.FromHex(0x000000),
        Foreground: Rgb.FromHex(0xD4D4D4),
        Emphasis: Rgb.FromHex(0xF0F0F0),
        Muted: Rgb.FromHex(0x6E6E6E),
        Marker: Rgb.FromHex(0x4A4A4A),
        Dimmed: Rgb.FromHex(0x3A3A3A),
        Literal: Rgb.FromHex(0x30D158),
        Reference: Rgb.FromHex(0x0A84FF),
        Meta: Rgb.FromHex(0xBF5AF2),
        Selection: Rgb.FromHex(0x1F2937),
        SelectionText: null,
        Caret: Rgb.FromHex(0x398AB0),
        Panel: Rgb.FromHex(0x161616),
        PanelBorder: Rgb.FromHex(0x2A2A2A),
        PanelSelection: Rgb.FromHex(0x1F2937));

    public static EditorPalette HighContrast(SystemColors c) => new(
        IsHighContrast: true,
        Background: c.Window,
        Foreground: c.WindowText,
        Emphasis: c.WindowText,
        Muted: c.WindowText,
        Marker: c.WindowText,
        Dimmed: c.GrayText,
        Literal: c.WindowText,
        Reference: c.Hotlight,
        Meta: c.WindowText,
        Selection: c.Highlight,
        SelectionText: c.HighlightText,
        Caret: c.WindowText,
        Panel: c.Window,
        PanelBorder: c.WindowText,
        PanelSelection: c.Highlight);

    public static EditorPalette Resolve(bool highContrast, Func<SystemColors> systemColors) =>
        highContrast ? HighContrast(systemColors()) : Standard;
}
