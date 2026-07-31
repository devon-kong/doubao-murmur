using DoubaoMurmur.Core;
using Microsoft.Win32;

namespace DoubaoMurmur.Platform;

/// <summary>Launch at sign-in via the per-user Run key (no elevation needed).</summary>
internal static class AutoStart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "DoubaoMurmur";

    public static bool IsEnabled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(ValueName) is string value && value.Length > 0;
            }
            catch (Exception ex)
            {
                Log.Warn($"Could not read autostart state: {ex.Message}");
                return false;
            }
        }
    }

    public static void SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (key is null) return;

            if (enabled)
            {
                var path = Environment.ProcessPath;
                if (string.IsNullOrEmpty(path))
                {
                    Log.Warn("Cannot enable autostart: executable path unknown");
                    return;
                }
                key.SetValue(ValueName, $"\"{path}\"");
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }

            Log.Info($"Autostart {(enabled ? "enabled" : "disabled")}");
        }
        catch (Exception ex)
        {
            Log.Error("Failed to update autostart", ex);
        }
    }
}
