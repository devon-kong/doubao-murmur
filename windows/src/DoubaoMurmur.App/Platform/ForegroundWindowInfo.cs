using System.Text;
using DoubaoMurmur.Core;

namespace DoubaoMurmur.Platform;

/// <summary>Identifies the window that will receive the paste.</summary>
internal static class ForegroundWindowInfo
{
    /// <summary>Lowercased executable name without extension, or null.</summary>
    public static string? GetProcessName()
    {
        var hwnd = NativeMethods.GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return null;

        NativeMethods.GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == 0) return null;

        var handle = NativeMethods.OpenProcess(
            NativeMethods.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (handle == IntPtr.Zero) return null;

        try
        {
            var buffer = new StringBuilder(1024);
            var size = (uint)buffer.Capacity;
            if (!NativeMethods.QueryFullProcessImageNameW(handle, 0, buffer, ref size)) return null;

            var name = Path.GetFileNameWithoutExtension(buffer.ToString(0, (int)size));
            return string.IsNullOrEmpty(name) ? null : name.ToLowerInvariant();
        }
        catch (Exception ex)
        {
            Log.Warn($"Foreground process lookup failed: {ex.Message}");
            return null;
        }
        finally
        {
            NativeMethods.CloseHandle(handle);
        }
    }
}
