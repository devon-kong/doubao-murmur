using System.Runtime.InteropServices;
using DoubaoMurmur.Core;

namespace DoubaoMurmur.Platform;

internal sealed record TrayMenuState(
    bool LoggedIn,
    bool Recording,
    ToggleKey ToggleKey,
    bool SuppressToggleKey,
    bool AutoStart);

/// <summary>
/// Notification-area icon built directly on Shell_NotifyIcon plus a Win32 popup
/// menu, hosted by a message-only window.
///
/// WinUI 3 has no tray support of its own, and every third-party wrapper still
/// P/Invokes the same two APIs while adding XAML lifetime rules on top. Doing it
/// directly keeps the behaviour inspectable and independent of the XAML layer.
/// The message-only window is created on the UI thread, whose DispatcherQueue
/// already pumps window messages, so no extra message loop is needed.
/// </summary>
internal sealed class TrayIcon : IDisposable
{
    private const uint CallbackMessage = NativeMethods.WM_APP + 1;
    private const string WindowClassName = "DoubaoMurmurTrayWindow";

    private static class Command
    {
        public const int None = 0;
        public const int Login = 1;
        public const int Logout = 2;
        public const int Help = 3;
        public const int OpenLog = 4;
        public const int CheckUpdate = 5;
        public const int AutoStart = 6;
        public const int SuppressToggleKey = 7;
        public const int Quit = 8;
        public const int ToggleKeyBase = 100;
    }

    // Kept alive for as long as the window class exists.
    private readonly NativeMethods.WndProc _windowProc;
    private readonly Func<TrayMenuState> _stateProvider;
    private readonly uint _taskbarCreatedMessage;

    private IntPtr _hwnd;
    private IntPtr _icon;
    private bool _iconAdded;
    private bool _classRegistered;

    public TrayIcon(Func<TrayMenuState> stateProvider)
    {
        _stateProvider = stateProvider;
        _windowProc = WindowProc;
        _taskbarCreatedMessage = NativeMethods.RegisterWindowMessageW("TaskbarCreated");
    }

    public event Action? LoginClicked;
    public event Action? LogoutClicked;
    public event Action? HelpClicked;
    public event Action? OpenLogClicked;
    public event Action? CheckUpdateClicked;
    public event Action? AutoStartToggled;
    public event Action? SuppressToggleKeyToggled;
    public event Action<ToggleKey>? ToggleKeyChanged;
    public event Action? QuitClicked;

    public bool Start()
    {
        if (!CreateMessageWindow()) return false;
        _icon = LoadTrayIcon();
        return AddIcon();
    }

    private bool CreateMessageWindow()
    {
        var instance = NativeMethods.GetModuleHandleW(null);

        var windowClass = new NativeMethods.WNDCLASSEXW
        {
            cbSize = (uint)Marshal.SizeOf<NativeMethods.WNDCLASSEXW>(),
            style = 0,
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_windowProc),
            cbClsExtra = 0,
            cbWndExtra = 0,
            hInstance = instance,
            hIcon = IntPtr.Zero,
            hCursor = IntPtr.Zero,
            hbrBackground = IntPtr.Zero,
            lpszMenuName = null,
            lpszClassName = WindowClassName,
            hIconSm = IntPtr.Zero,
        };

        if (NativeMethods.RegisterClassExW(ref windowClass) == 0)
        {
            const int errorClassAlreadyExists = 1410;
            var error = Marshal.GetLastWin32Error();
            if (error != errorClassAlreadyExists)
            {
                Log.Error($"RegisterClassEx failed (error {error})");
                return false;
            }
        }
        _classRegistered = true;

        _hwnd = NativeMethods.CreateWindowExW(0, WindowClassName, "Doubao Murmur", 0,
            0, 0, 0, 0, NativeMethods.HWND_MESSAGE, IntPtr.Zero, instance, IntPtr.Zero);

        if (_hwnd == IntPtr.Zero)
        {
            Log.Error($"CreateWindowEx failed (error {Marshal.GetLastWin32Error()})");
            return false;
        }

        return true;
    }

    private static IntPtr LoadTrayIcon()
    {
        var width = NativeMethods.GetSystemMetrics(NativeMethods.SM_CXSMICON);
        var height = NativeMethods.GetSystemMetrics(NativeMethods.SM_CYSMICON);

        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
        if (File.Exists(iconPath))
        {
            var handle = NativeMethods.LoadImageW(IntPtr.Zero, iconPath, NativeMethods.IMAGE_ICON,
                width, height, NativeMethods.LR_LOADFROMFILE);
            if (handle != IntPtr.Zero) return handle;
            Log.Warn($"LoadImage failed for {iconPath} (error {Marshal.GetLastWin32Error()})");
        }

        // Fall back to the icon embedded in the executable.
        var executable = Environment.ProcessPath;
        if (!string.IsNullOrEmpty(executable))
        {
            NativeMethods.ExtractIconExW(executable, 0, out _, out var small, 1);
            if (small != IntPtr.Zero) return small;
        }

        Log.Warn("No tray icon available; the notification area will show a blank slot");
        return IntPtr.Zero;
    }

    private bool AddIcon()
    {
        var data = CreateIconData(NativeMethods.NIF_MESSAGE | NativeMethods.NIF_ICON | NativeMethods.NIF_TIP);
        data.szTip = Tooltip(_stateProvider());

        if (!NativeMethods.Shell_NotifyIconW(NativeMethods.NIM_ADD, ref data))
        {
            Log.Error($"Shell_NotifyIcon(NIM_ADD) failed (error {Marshal.GetLastWin32Error()})");
            return false;
        }

        _iconAdded = true;
        Log.Info("Tray icon added");
        return true;
    }

    public void Refresh()
    {
        if (!_iconAdded) return;
        var data = CreateIconData(NativeMethods.NIF_TIP);
        data.szTip = Tooltip(_stateProvider());
        NativeMethods.Shell_NotifyIconW(NativeMethods.NIM_MODIFY, ref data);
    }

    private NativeMethods.NOTIFYICONDATAW CreateIconData(uint flags) => new()
    {
        cbSize = (uint)Marshal.SizeOf<NativeMethods.NOTIFYICONDATAW>(),
        hWnd = _hwnd,
        uID = 1,
        uFlags = flags,
        uCallbackMessage = CallbackMessage,
        hIcon = _icon,
        szTip = string.Empty,
        szInfo = string.Empty,
        szInfoTitle = string.Empty,
    };

    private static string Tooltip(TrayMenuState state)
    {
        if (state.Recording) return "Doubao Murmur — 正在识别…";
        return state.LoggedIn ? "Doubao Murmur — 已登录" : "Doubao Murmur — 未登录";
    }

    private IntPtr WindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (msg == CallbackMessage)
            {
                var mouseMessage = (int)(lParam.ToInt64() & 0xFFFF);
                if (mouseMessage is NativeMethods.WM_RBUTTONUP
                    or NativeMethods.WM_LBUTTONUP
                    or NativeMethods.WM_CONTEXTMENU)
                {
                    ShowMenu();
                }
                return IntPtr.Zero;
            }

            // Explorer restarted and dropped every tray icon; put ours back.
            if (msg == _taskbarCreatedMessage && _taskbarCreatedMessage != 0)
            {
                _iconAdded = false;
                AddIcon();
                return IntPtr.Zero;
            }
        }
        catch (Exception ex)
        {
            Log.Error("Tray window procedure failed", ex);
        }

        return NativeMethods.DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private void ShowMenu()
    {
        var state = _stateProvider();
        var menu = NativeMethods.CreatePopupMenu();
        if (menu == IntPtr.Zero) return;

        var hotkeyMenu = IntPtr.Zero;

        try
        {
            AppendItem(menu, NativeMethods.MF_STRING | NativeMethods.MF_GRAYED, Command.None,
                state.LoggedIn ? "状态：已登录" : "状态：未登录");
            AppendSeparator(menu);

            if (state.LoggedIn)
            {
                AppendItem(menu, NativeMethods.MF_STRING, Command.Logout, "退出登录");
            }
            else
            {
                AppendItem(menu, NativeMethods.MF_STRING, Command.Login, "登录豆包");
            }

            AppendItem(menu, NativeMethods.MF_STRING, Command.Help, "使用帮助");
            AppendSeparator(menu);

            hotkeyMenu = NativeMethods.CreatePopupMenu();
            if (hotkeyMenu != IntPtr.Zero)
            {
                foreach (var key in Enum.GetValues<ToggleKey>())
                {
                    var flags = NativeMethods.MF_STRING;
                    if (key == state.ToggleKey) flags |= NativeMethods.MF_CHECKED;
                    AppendItem(hotkeyMenu, flags, Command.ToggleKeyBase + (int)key, DisplayName(key));
                }

                NativeMethods.AppendMenuW(menu, NativeMethods.MF_POPUP,
                    (UIntPtr)(ulong)hotkeyMenu.ToInt64(), "触发热键");
                // Ownership passes to the parent menu; DestroyMenu(menu) frees it.
                hotkeyMenu = IntPtr.Zero;
            }

            AppendItem(menu,
                NativeMethods.MF_STRING | (state.SuppressToggleKey ? NativeMethods.MF_CHECKED : 0),
                Command.SuppressToggleKey, "拦截热键（避免唤出菜单栏，会禁用 AltGr）");
            AppendItem(menu,
                NativeMethods.MF_STRING | (state.AutoStart ? NativeMethods.MF_CHECKED : 0),
                Command.AutoStart, "开机自启");

            AppendSeparator(menu);
            AppendItem(menu, NativeMethods.MF_STRING, Command.OpenLog, "打开日志");
            AppendItem(menu, NativeMethods.MF_STRING, Command.CheckUpdate, "检查更新");
            AppendSeparator(menu);
            AppendItem(menu, NativeMethods.MF_STRING, Command.Quit, "退出");

            NativeMethods.GetCursorPos(out var point);

            // Required so the menu closes when the user clicks elsewhere.
            NativeMethods.SetForegroundWindow(_hwnd);

            var command = NativeMethods.TrackPopupMenuEx(menu,
                NativeMethods.TPM_RIGHTBUTTON | NativeMethods.TPM_RETURNCMD | NativeMethods.TPM_NONOTIFY,
                point.X, point.Y, _hwnd, IntPtr.Zero);

            NativeMethods.PostMessageW(_hwnd, NativeMethods.WM_NULL, IntPtr.Zero, IntPtr.Zero);

            Dispatch(command);
        }
        finally
        {
            if (hotkeyMenu != IntPtr.Zero) NativeMethods.DestroyMenu(hotkeyMenu);
            NativeMethods.DestroyMenu(menu);
        }
    }

    private static string DisplayName(ToggleKey key) => key switch
    {
        ToggleKey.RightAlt => "右 Alt（默认）",
        ToggleKey.RightControl => "右 Ctrl",
        ToggleKey.RightShift => "右 Shift",
        ToggleKey.ScrollLock => "Scroll Lock",
        ToggleKey.Pause => "Pause",
        _ => key.ToString(),
    };

    private void Dispatch(int command)
    {
        switch (command)
        {
            case Command.None:
                break;
            case Command.Login:
                LoginClicked?.Invoke();
                break;
            case Command.Logout:
                LogoutClicked?.Invoke();
                break;
            case Command.Help:
                HelpClicked?.Invoke();
                break;
            case Command.OpenLog:
                OpenLogClicked?.Invoke();
                break;
            case Command.CheckUpdate:
                CheckUpdateClicked?.Invoke();
                break;
            case Command.AutoStart:
                AutoStartToggled?.Invoke();
                break;
            case Command.SuppressToggleKey:
                SuppressToggleKeyToggled?.Invoke();
                break;
            case Command.Quit:
                QuitClicked?.Invoke();
                break;
            default:
                if (command >= Command.ToggleKeyBase)
                {
                    var value = command - Command.ToggleKeyBase;
                    if (Enum.IsDefined(typeof(ToggleKey), value))
                    {
                        ToggleKeyChanged?.Invoke((ToggleKey)value);
                    }
                }
                break;
        }
    }

    private static void AppendItem(IntPtr menu, uint flags, int id, string text) =>
        NativeMethods.AppendMenuW(menu, flags, (UIntPtr)(uint)id, text);

    private static void AppendSeparator(IntPtr menu) =>
        NativeMethods.AppendMenuW(menu, NativeMethods.MF_SEPARATOR, UIntPtr.Zero, null);

    public void Dispose()
    {
        if (_iconAdded)
        {
            var data = CreateIconData(0);
            NativeMethods.Shell_NotifyIconW(NativeMethods.NIM_DELETE, ref data);
            _iconAdded = false;
        }

        if (_icon != IntPtr.Zero)
        {
            NativeMethods.DestroyIcon(_icon);
            _icon = IntPtr.Zero;
        }

        if (_hwnd != IntPtr.Zero)
        {
            NativeMethods.DestroyWindow(_hwnd);
            _hwnd = IntPtr.Zero;
        }

        if (_classRegistered)
        {
            NativeMethods.UnregisterClassW(WindowClassName, NativeMethods.GetModuleHandleW(null));
            _classRegistered = false;
        }
    }
}
