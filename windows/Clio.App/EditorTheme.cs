using System.Runtime.InteropServices;
using Clio.Editor;

namespace Clio.App;

/// <summary>
/// The current <see cref="EditorPalette"/>: the standard dark palette, or the user's system colours while a
/// Windows high-contrast theme is active. <see cref="Changed"/> fires on the UI thread when the theme switches.
/// <para>
/// <c>AccessibilitySettings.HighContrastChanged</c> cannot be subscribed to from an unpackaged WinUI 3 window
/// (E_NOTFOUND 0x80070490), and <c>SystemEvents</c> is not in the .NET runtime shipped here, so the state is
/// read with <c>SystemParametersInfo</c> and re-checked on a slow dispatcher timer.
/// </para>
/// </summary>
internal static class EditorTheme
{
    private const uint SpiGetHighContrast = 0x0042;
    private const uint HighContrastOn = 0x1;

    private static Microsoft.UI.Dispatching.DispatcherQueue? _queue;

    public static EditorPalette Current { get; private set; } = EditorPalette.Standard;

    public static event Action? Changed;

    /// <summary>Call once on the UI thread. Reads the current theme and follows later switches.</summary>
    public static void Start()
    {
        _queue = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        Current = Resolve();
        _timer = _queue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(1500);
        _timer.IsRepeating = true;
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
    }

    private static Microsoft.UI.Dispatching.DispatcherQueueTimer? _timer;

    private static void Refresh()
    {
        var next = Resolve();
        // Also re-resolve when the user switches between two high-contrast themes (same flag, new colours).
        if (next == Current) return;
        Current = next;
        Changed?.Invoke();
    }

    private static EditorPalette Resolve() => EditorPalette.Resolve(IsHighContrast(), ReadSystemColors);

    public static Windows.UI.Color ToColor(Rgb c) => Windows.UI.Color.FromArgb(255, c.R, c.G, c.B);

    // COLOR_WINDOW, COLOR_WINDOWTEXT, COLOR_HIGHLIGHT, COLOR_HIGHLIGHTTEXT, COLOR_GRAYTEXT, COLOR_HOTLIGHT.
    private static SystemColors ReadSystemColors() => new(Sys(5), Sys(8), Sys(17), Sys(13), Sys(14), Sys(26));

    private static Rgb Sys(int index)
    {
        var colorRef = GetSysColor(index); // 0x00BBGGRR
        return new Rgb((byte)colorRef, (byte)(colorRef >> 8), (byte)(colorRef >> 16));
    }

    private static bool IsHighContrast()
    {
        var info = new HighContrast { Size = (uint)Marshal.SizeOf<HighContrast>() };
        return SystemParametersInfo(SpiGetHighContrast, info.Size, ref info, 0) && (info.Flags & HighContrastOn) != 0;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HighContrast
    {
        public uint Size;
        public uint Flags;
        public IntPtr DefaultScheme;
    }

    [DllImport("user32.dll")]
    private static extern uint GetSysColor(int nIndex);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SystemParametersInfo(uint action, uint param, ref HighContrast info, uint winIni);
}
