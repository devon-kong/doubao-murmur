using DoubaoMurmur.Core;

namespace DoubaoMurmur.Platform;

/// <summary>Window tweaks WinUI 3 does not expose, applied straight to the HWND.</summary>
internal static class WindowHelper
{
    /// <summary>
    /// Makes a window that never takes focus and never shows up in the taskbar or
    /// Alt+Tab.
    ///
    /// This is load-bearing for the overlay: if it ever takes focus, the
    /// transcription gets pasted into the overlay itself instead of the app the
    /// user was typing in.
    /// </summary>
    public static void MakeNonActivating(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;

        var style = (long)NativeMethods.GetWindowLongPtr(hwnd, NativeMethods.GWL_EXSTYLE);
        style |= NativeMethods.WS_EX_NOACTIVATE | NativeMethods.WS_EX_TOOLWINDOW | NativeMethods.WS_EX_TOPMOST;
        style &= ~(long)NativeMethods.WS_EX_APPWINDOW;

        NativeMethods.SetWindowLongPtr(hwnd, NativeMethods.GWL_EXSTYLE, new IntPtr(style));
    }

    /// <summary>Opt into the rounded corners Windows 11 draws for top-level windows.</summary>
    public static void SetRoundedCorners(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        var preference = NativeMethods.DWMWCP_ROUND;
        // Fails harmlessly (unknown attribute) on Windows 10.
        NativeMethods.DwmSetWindowAttribute(hwnd, NativeMethods.DWMWA_WINDOW_CORNER_PREFERENCE,
            ref preference, sizeof(int));
    }

    /// <summary>Show without stealing focus from whatever the user is typing in.</summary>
    public static void ShowWithoutActivating(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        NativeMethods.ShowWindow(hwnd, NativeMethods.SW_SHOWNOACTIVATE);
    }

    public static void Hide(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        NativeMethods.ShowWindow(hwnd, NativeMethods.SW_HIDE);
    }

    /// <summary>DPI scale factor (1.0 at 96 DPI).</summary>
    public static double GetScale(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return 1.0;
        var dpi = NativeMethods.GetDpiForWindow(hwnd);
        return dpi == 0 ? 1.0 : dpi / 96.0;
    }

    public static NativeMethods.POINT GetCursorPosition()
    {
        if (NativeMethods.GetCursorPos(out var point)) return point;
        Log.Warn("GetCursorPos failed");
        return new NativeMethods.POINT { X = 0, Y = 0 };
    }
}
