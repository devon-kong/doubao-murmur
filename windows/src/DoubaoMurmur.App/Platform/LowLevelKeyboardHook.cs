using System.Runtime.InteropServices;
using DoubaoMurmur.Core;

namespace DoubaoMurmur.Platform;

/// <summary>
/// Global keyboard listener built on WH_KEYBOARD_LL. Mirrors the CGEventTap on
/// macOS and the XRecord listener on Linux.
///
/// RegisterHotKey cannot bind a bare modifier such as right Alt, so a low-level
/// hook is the only option. The hook must live on a thread with a message pump —
/// it is installed on the UI thread, whose DispatcherQueue already pumps messages.
///
/// Known limitation: UIPI stops the hook from seeing keystrokes while an elevated
/// window has focus, unless this process is elevated too.
/// </summary>
internal sealed class LowLevelKeyboardHook : IDisposable
{
    // Kept in a field: if the delegate is collected the hook silently stops firing.
    private readonly NativeMethods.HookProc _callback;

    private IntPtr _hook;
    private bool _toggleDown;
    private bool _otherKeyPressed;

    public LowLevelKeyboardHook()
    {
        _callback = HookCallback;
    }

    public ToggleKey ToggleKey { get; set; } = ToggleKey.RightAlt;

    /// <summary>Swallow the toggle key so the focused app never sees it.</summary>
    public bool SuppressToggleKey { get; set; }

    /// <summary>Fires on the hook thread — handlers must return immediately.</summary>
    public event Action? TogglePressed;

    /// <summary>Fires on the hook thread — handlers must return immediately.</summary>
    public event Action? CancelPressed;

    public bool IsInstalled => _hook != IntPtr.Zero;

    public bool Install()
    {
        if (_hook != IntPtr.Zero) return true;

        var module = NativeMethods.GetModuleHandleW(null);
        _hook = NativeMethods.SetWindowsHookExW(NativeMethods.WH_KEYBOARD_LL, _callback, module, 0);

        if (_hook == IntPtr.Zero)
        {
            Log.Error($"SetWindowsHookEx failed (error {Marshal.GetLastWin32Error()})");
            return false;
        }

        Log.Info($"Keyboard hook installed, toggle key = {ToggleKey}");
        return true;
    }

    public void Uninstall()
    {
        if (_hook == IntPtr.Zero) return;
        NativeMethods.UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
        Log.Info("Keyboard hook removed");
    }

    public static int VirtualKeyFor(ToggleKey key) => key switch
    {
        ToggleKey.RightAlt => NativeMethods.VK_RMENU,
        ToggleKey.RightControl => NativeMethods.VK_RCONTROL,
        ToggleKey.RightShift => NativeMethods.VK_RSHIFT,
        ToggleKey.ScrollLock => NativeMethods.VK_SCROLL,
        ToggleKey.Pause => NativeMethods.VK_PAUSE,
        _ => NativeMethods.VK_RMENU,
    };

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode != NativeMethods.HC_ACTION)
        {
            return NativeMethods.CallNextHookEx(_hook, nCode, wParam, lParam);
        }

        var suppress = false;
        try
        {
            suppress = Process(wParam, lParam);
        }
        catch (Exception ex)
        {
            // A throwing hook would wedge input for the whole desktop.
            Log.Error("Keyboard hook callback failed", ex);
        }

        return suppress ? new IntPtr(1) : NativeMethods.CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    private bool Process(IntPtr wParam, IntPtr lParam)
    {
        var info = Marshal.PtrToStructure<NativeMethods.KBDLLHOOKSTRUCT>(lParam);
        var message = (int)wParam;
        var isDown = message is NativeMethods.WM_KEYDOWN or NativeMethods.WM_SYSKEYDOWN;
        var isUp = message is NativeMethods.WM_KEYUP or NativeMethods.WM_SYSKEYUP;
        if (!isDown && !isUp) return false;

        var vk = (int)info.vkCode;
        var toggleVk = VirtualKeyFor(ToggleKey);

        if (vk == toggleVk)
        {
            if (isDown)
            {
                // Guard against auto-repeat resetting the "no other key" flag.
                if (!_toggleDown)
                {
                    _toggleDown = true;
                    _otherKeyPressed = false;
                }
            }
            else
            {
                var fire = _toggleDown && !_otherKeyPressed;
                _toggleDown = false;
                if (fire) TogglePressed?.Invoke();
            }

            return SuppressToggleKey;
        }

        if (!isDown) return false;

        // Pressing AltGr synthesises a left-Ctrl down. Counting it as "another key"
        // would mean the toggle never fires on layouts that have AltGr, which is the
        // Windows counterpart of the Linux AltGr fix in commit 37098ef.
        var syntheticAltGrControl = vk == NativeMethods.VK_LCONTROL &&
            ((info.flags & NativeMethods.LLKHF_INJECTED) != 0 || (info.scanCode & 0x200) != 0);
        if (syntheticAltGrControl) return false;

        if (_toggleDown) _otherKeyPressed = true;

        // ESC cancels. Never suppressed: the focused app still needs its Escape.
        if (vk == NativeMethods.VK_ESCAPE) CancelPressed?.Invoke();

        return false;
    }

    public void Dispose() => Uninstall();
}
