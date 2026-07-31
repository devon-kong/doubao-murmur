using System.Runtime.InteropServices;
using DoubaoMurmur.Core;

namespace DoubaoMurmur.Platform;

/// <summary>
/// Copies the transcription to the clipboard and synthesises the paste shortcut.
/// Mirrors PasteHelper.swift.
/// </summary>
internal static class PasteHelper
{
    private enum Shortcut
    {
        CtrlV,
        CtrlShiftV,
        ShiftInsert,
    }

    /// <summary>
    /// Apps whose paste shortcut is not Ctrl+V. Windows Terminal and modern conhost
    /// both accept Ctrl+V, so unlike Linux this list stays very short.
    /// </summary>
    private static readonly Dictionary<string, Shortcut> ShortcutOverrides = new(StringComparer.OrdinalIgnoreCase)
    {
        ["mintty"] = Shortcut.CtrlShiftV,   // Git Bash / Cygwin
        ["putty"] = Shortcut.ShiftInsert,
        ["kitty"] = Shortcut.CtrlShiftV,
        ["alacritty"] = Shortcut.CtrlShiftV,
        ["wezterm-gui"] = Shortcut.CtrlShiftV,
    };

    /// <summary>Must be called on the UI thread (clipboard ownership is per-thread).</summary>
    public static async Task CopyAndPasteAsync(string text, PasteMode mode)
    {
        if (string.IsNullOrEmpty(text)) return;

        if (mode == PasteMode.Typing)
        {
            ReleaseStuckModifiers();
            SendUnicodeText(text);
            Log.Info($"Typed {text.Length} chars directly");
            return;
        }

        if (!await TrySetClipboardTextAsync(text).ConfigureAwait(true))
        {
            Log.Error("Clipboard was locked by another process; paste skipped");
            return;
        }

        await Task.Delay(AppConfig.PasteDelay).ConfigureAwait(true);

        var process = ForegroundWindowInfo.GetProcessName();
        var shortcut = process is not null && ShortcutOverrides.TryGetValue(process, out var found)
            ? found
            : Shortcut.CtrlV;

        ReleaseStuckModifiers();
        SendShortcut(shortcut);
        Log.Info($"Pasted into '{process ?? "unknown"}' using {shortcut}");
    }

    public static Task<bool> CopyOnlyAsync(string text) => TrySetClipboardTextAsync(text);

    private static async Task<bool> TrySetClipboardTextAsync(string text)
    {
        // Another process frequently holds the clipboard open for a few
        // milliseconds; retrying is what makes this reliable in practice.
        for (var attempt = 0; attempt < 10; attempt++)
        {
            if (SetClipboardText(text)) return true;
            await Task.Delay(50).ConfigureAwait(true);
        }
        return false;
    }

    private static bool SetClipboardText(string text)
    {
        if (!NativeMethods.OpenClipboard(IntPtr.Zero)) return false;

        var handle = IntPtr.Zero;
        try
        {
            if (!NativeMethods.EmptyClipboard()) return false;

            var bytes = (text.Length + 1) * sizeof(char);
            handle = NativeMethods.GlobalAlloc(NativeMethods.GMEM_MOVEABLE, (UIntPtr)bytes);
            if (handle == IntPtr.Zero) return false;

            var target = NativeMethods.GlobalLock(handle);
            if (target == IntPtr.Zero) return false;

            try
            {
                Marshal.Copy(text.ToCharArray(), 0, target, text.Length);
                Marshal.WriteInt16(target, text.Length * sizeof(char), 0);
            }
            finally
            {
                NativeMethods.GlobalUnlock(handle);
            }

            if (NativeMethods.SetClipboardData(NativeMethods.CF_UNICODETEXT, handle) == IntPtr.Zero)
            {
                return false;
            }

            // Ownership transferred to the clipboard; must not free it.
            handle = IntPtr.Zero;
            return true;
        }
        catch (Exception ex)
        {
            Log.Error("Clipboard write failed", ex);
            return false;
        }
        finally
        {
            if (handle != IntPtr.Zero) NativeMethods.GlobalFree(handle);
            NativeMethods.CloseClipboard();
        }
    }

    /// <summary>
    /// Drops any modifier the user might still be holding. Without this a held
    /// Alt turns our Ctrl+V into Ctrl+Alt+V and nothing gets pasted.
    /// </summary>
    private static void ReleaseStuckModifiers()
    {
        int[] modifiers =
        {
            NativeMethods.VK_LMENU, NativeMethods.VK_RMENU,
            NativeMethods.VK_LCONTROL, NativeMethods.VK_RCONTROL,
            NativeMethods.VK_LSHIFT, NativeMethods.VK_RSHIFT,
            NativeMethods.VK_LWIN, NativeMethods.VK_RWIN,
        };

        var inputs = new List<NativeMethods.INPUT>();
        foreach (var vk in modifiers)
        {
            if ((NativeMethods.GetAsyncKeyState(vk) & 0x8000) == 0) continue;
            inputs.Add(KeyInput((ushort)vk, 0, NativeMethods.KEYEVENTF_KEYUP));
        }

        if (inputs.Count > 0) Send(inputs.ToArray());
    }

    private static void SendShortcut(Shortcut shortcut)
    {
        var inputs = shortcut switch
        {
            Shortcut.CtrlShiftV => new[]
            {
                ScanInput(NativeMethods.SC_LCONTROL, false),
                ScanInput(NativeMethods.SC_LSHIFT, false),
                ScanInput(NativeMethods.SC_V, false),
                ScanInput(NativeMethods.SC_V, true),
                ScanInput(NativeMethods.SC_LSHIFT, true),
                ScanInput(NativeMethods.SC_LCONTROL, true),
            },
            Shortcut.ShiftInsert => new[]
            {
                ScanInput(NativeMethods.SC_LSHIFT, false),
                ScanInput(NativeMethods.SC_INSERT, false, extended: true),
                ScanInput(NativeMethods.SC_INSERT, true, extended: true),
                ScanInput(NativeMethods.SC_LSHIFT, true),
            },
            _ => new[]
            {
                ScanInput(NativeMethods.SC_LCONTROL, false),
                ScanInput(NativeMethods.SC_V, false),
                ScanInput(NativeMethods.SC_V, true),
                ScanInput(NativeMethods.SC_LCONTROL, true),
            },
        };

        Send(inputs);
    }

    private static void SendUnicodeText(string text)
    {
        var inputs = new List<NativeMethods.INPUT>(text.Length * 2);
        foreach (var ch in text)
        {
            inputs.Add(KeyInput(0, (ushort)ch, NativeMethods.KEYEVENTF_UNICODE));
            inputs.Add(KeyInput(0, (ushort)ch, NativeMethods.KEYEVENTF_UNICODE | NativeMethods.KEYEVENTF_KEYUP));

            // SendInput takes an array; chunk it so very long transcriptions do not
            // allocate one huge block and so the target app can keep up.
            if (inputs.Count < 200) continue;
            Send(inputs.ToArray());
            inputs.Clear();
        }

        if (inputs.Count > 0) Send(inputs.ToArray());
    }

    /// <summary>Scan-code based input: some apps and games ignore virtual-key events.</summary>
    private static NativeMethods.INPUT ScanInput(ushort scanCode, bool keyUp, bool extended = false)
    {
        var flags = NativeMethods.KEYEVENTF_SCANCODE;
        if (keyUp) flags |= NativeMethods.KEYEVENTF_KEYUP;
        if (extended) flags |= NativeMethods.KEYEVENTF_EXTENDEDKEY;
        return KeyInput(0, scanCode, flags);
    }

    private static NativeMethods.INPUT KeyInput(ushort virtualKey, ushort scanCode, uint flags) => new()
    {
        type = NativeMethods.INPUT_KEYBOARD,
        U = new NativeMethods.InputUnion
        {
            ki = new NativeMethods.KEYBDINPUT
            {
                wVk = virtualKey,
                wScan = scanCode,
                dwFlags = flags,
                time = 0,
                dwExtraInfo = IntPtr.Zero,
            },
        },
    };

    private static void Send(NativeMethods.INPUT[] inputs)
    {
        var sent = NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.INPUT>());
        if (sent != inputs.Length)
        {
            // Most common cause: the focused window belongs to an elevated process
            // and UIPI blocks synthetic input from this non-elevated one.
            Log.Warn($"SendInput sent {sent}/{inputs.Length} events " +
                     $"(error {Marshal.GetLastWin32Error()}); is the target window elevated?");
        }
    }
}
