using System.Runtime.InteropServices;

namespace Clio.App;

/// <summary>
/// The notification-area icon (macOS menu bar extra): MCP status, Open Clio, MCP Settings, Pause or Resume MCP, Open at
/// login, a Revoke entry per authorized client, and Quit. WinUI has no tray API, so this is a message-only window plus
/// <c>Shell_NotifyIcon</c> and a native popup menu. Everything runs on the UI thread, which pumps its messages.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    private const uint WmTray = 0x8001; // WM_APP + 1
    private const uint WmLeftButtonUp = 0x0202, WmRightButtonUp = 0x0205, WmLeftDoubleClick = 0x0203, WmContextMenu = 0x007B;
    private const uint NinSelect = 0x0400, NinKeySelect = 0x0401;
    private const uint NimAdd = 0, NimModify = 1, NimDelete = 2;
    private const uint NifMessage = 1, NifIcon = 2, NifTip = 4;
    private const uint MfString = 0, MfGrayed = 1, MfChecked = 8, MfSeparator = 0x800;
    private const uint TpmReturnCmd = 0x100, TpmNoNotify = 0x80, TpmRightButton = 2;
    private const int CommandOpen = 1, CommandSettings = 2, CommandToggleMcp = 3, CommandLogin = 4, CommandQuit = 5, CommandRevokeBase = 100;
    private static readonly IntPtr MessageOnlyParent = new(-3);

    private readonly McpController _mcp;
    private readonly Action _openClio;
    private readonly Action _showSettings;
    private readonly Action _quit;
    private readonly WndProc _proc;
    private readonly uint _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
    private IntPtr _hwnd;
    private IntPtr _icon;
    private bool _added;

    private delegate IntPtr WndProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    public TrayIcon(McpController mcp, Action openClio, Action showSettings, Action quit)
    {
        (_mcp, _openClio, _showSettings, _quit) = (mcp, openClio, showSettings, quit);
        _proc = Handle;
        var instance = GetModuleHandle(null);
        var wc = new WndClass { lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_proc), hInstance = instance, lpszClassName = "ClioTrayWindow" };
        RegisterClass(ref wc);
        _hwnd = CreateWindowEx(0, wc.lpszClassName, "Clio tray", 0, 0, 0, 0, 0, MessageOnlyParent, IntPtr.Zero, instance, IntPtr.Zero);
        _icon = DocumentIcon.Create();
        _mcp.Changed += Update;
        Add();
    }

    public bool IsShown => _added;

    private void Add()
    {
        if (_hwnd == IntPtr.Zero) return;
        var data = Data(NifMessage | NifIcon | NifTip);
        _added = Shell_NotifyIcon(NimAdd, ref data);
    }

    private void Update()
    {
        if (!_added) return;
        var data = Data(NifTip);
        Shell_NotifyIcon(NimModify, ref data);
    }

    private NotifyIconData Data(uint flags) => new()
    {
        cbSize = (uint)Marshal.SizeOf<NotifyIconData>(),
        hWnd = _hwnd,
        uID = 1,
        uFlags = flags,
        uCallbackMessage = WmTray,
        hIcon = _icon,
        szTip = Truncate($"Clio. {_mcp.Service.Status}", 127),
    };

    private static string Truncate(string text, int length) => text.Length <= length ? text : text[..length];

    private IntPtr Handle(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message == WmTray)
        {
            switch ((uint)(lParam.ToInt64() & 0xFFFF))
            {
                case WmLeftButtonUp or WmLeftDoubleClick: _openClio(); break;
                case WmRightButtonUp or WmContextMenu or NinSelect or NinKeySelect: ShowMenu(); break;
            }
            return IntPtr.Zero;
        }
        if (message == _taskbarCreated && _taskbarCreated != 0)
        {
            // Explorer restarted and dropped every icon.
            Add();
            return IntPtr.Zero;
        }
        return DefWindowProc(hwnd, message, wParam, lParam);
    }

    private void ShowMenu()
    {
        var service = _mcp.Service;
        var clients = service.Clients;
        var menu = CreatePopupMenu();
        try
        {
            AppendMenu(menu, MfString | MfGrayed, 0, service.Status);
            AppendMenu(menu, MfSeparator, 0, null);
            AppendMenu(menu, MfString, CommandOpen, "Open Clio");
            AppendMenu(menu, MfString, CommandSettings, "MCP Settings…");
            AppendMenu(menu, MfString, CommandToggleMcp, service.Enabled ? "Pause MCP" : "Resume MCP");
            AppendMenu(menu, MfString | (_mcp.LoginEnabled ? MfChecked : 0), CommandLogin, "Open at login");
            AppendMenu(menu, MfString | MfGrayed, 0, $"{service.ConnectedSessions} client sessions");
            for (var i = 0; i < clients.Count; i++) AppendMenu(menu, MfString, (nuint)(CommandRevokeBase + i), $"Revoke {clients[i].Name.Replace("&", "&&")}");
            AppendMenu(menu, MfSeparator, 0, null);
            AppendMenu(menu, MfString, CommandQuit, "Quit Clio");

            GetCursorPos(out var at);
            // The menu closes when the owner clicks elsewhere only if its owner window is foreground first.
            SetForegroundWindow(_hwnd);
            var chosen = (int)TrackPopupMenuEx(menu, TpmReturnCmd | TpmNoNotify | TpmRightButton, at.X, at.Y, _hwnd, IntPtr.Zero);
            PostMessage(_hwnd, 0, IntPtr.Zero, IntPtr.Zero);
            switch (chosen)
            {
                case CommandOpen: _openClio(); break;
                case CommandSettings: _showSettings(); break;
                case CommandToggleMcp: _mcp.SetEnabled(!service.Enabled); break;
                case CommandLogin: _mcp.SetLoginEnabled(!_mcp.LoginEnabled); break;
                case CommandQuit: _quit(); break;
                case >= CommandRevokeBase when chosen - CommandRevokeBase < clients.Count: service.Revoke(clients[chosen - CommandRevokeBase].Id); break;
            }
        }
        finally { DestroyMenu(menu); }
    }

    public void Dispose()
    {
        _mcp.Changed -= Update;
        if (_added)
        {
            var data = Data(0);
            Shell_NotifyIcon(NimDelete, ref data);
            _added = false;
        }
        if (_hwnd != IntPtr.Zero) { DestroyWindow(_hwnd); _hwnd = IntPtr.Zero; }
        if (_icon != IntPtr.Zero) { DestroyIcon(_icon); _icon = IntPtr.Zero; }
    }

    // ---- native ---------------------------------------------------------------------------------

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WndClass
    {
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "Shell_NotifyIconW")]
    private static extern bool Shell_NotifyIcon(uint message, ref NotifyIconData data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegisterClassW")]
    private static extern ushort RegisterClass(ref WndClass wc);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreateWindowExW")]
    private static extern IntPtr CreateWindowEx(uint exStyle, string className, string windowName, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "DefWindowProcW")]
    private static extern IntPtr DefWindowProc(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegisterWindowMessageW")] private static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll")] private static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll")] private static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "AppendMenuW")] private static extern bool AppendMenu(IntPtr menu, uint flags, nuint id, string? text);
    [DllImport("user32.dll")] private static extern uint TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr parameters);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll", EntryPoint = "PostMessageW")] private static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr icon);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetModuleHandleW")] private static extern IntPtr GetModuleHandle(string? name);
}

/// <summary>A small page icon drawn pixel by pixel, so the tray needs no icon file shipped beside the program.</summary>
internal static class DocumentIcon
{
    private const int Size = 32;

    public static IntPtr Create()
    {
        var pixels = new byte[Size * Size * 4];
        for (var y = 0; y < Size; y++)
        for (var x = 0; x < Size; x++)
        {
            var (r, g, b, a) = Pixel(x, y);
            var i = (y * Size + x) * 4;
            (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) = (b, g, r, a);
        }
        var color = CreateBitmap(Size, Size, 1, 32, pixels);
        var mask = CreateBitmap(Size, Size, 1, 1, new byte[Size * 4]);
        var info = new IconInfo { fIcon = true, hbmMask = mask, hbmColor = color };
        var icon = CreateIconIndirect(ref info);
        DeleteObject(color);
        DeleteObject(mask);
        return icon;
    }

    /// <summary>A page with a folded corner and three lines of text: light fill, dark outline, so it reads on either taskbar.</summary>
    private static (byte R, byte G, byte B, byte A) Pixel(int x, int y)
    {
        const int left = 6, right = 25, top = 2, bottom = 29, fold = 7;
        if (x < left || x > right || y < top || y > bottom) return (0, 0, 0, 0);
        var cut = x - (right - fold) + (top + fold - y); // beyond the folded corner
        if (x > right - fold && y < top + fold && cut > fold) return (0, 0, 0, 0);
        var edge = x == left || x == right || y == top || y == bottom || (x > right - fold && y < top + fold && cut == fold);
        if (edge) return (0x40, 0x40, 0x40, 0xFF);
        var line = (y is 13 or 17 or 21 or 25) && x >= 10 && x <= (y == 25 ? 16 : 21);
        if (line) return (0x55, 0x55, 0x55, 0xFF);
        return (0xF2, 0xF2, 0xF2, 0xFF);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IconInfo
    {
        public bool fIcon;
        public int xHotspot, yHotspot;
        public IntPtr hbmMask, hbmColor;
    }

    [DllImport("gdi32.dll")] private static extern IntPtr CreateBitmap(int width, int height, uint planes, uint bitsPerPixel, byte[] bits);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr handle);
    [DllImport("user32.dll")] private static extern IntPtr CreateIconIndirect(ref IconInfo info);
}
