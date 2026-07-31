using System.Diagnostics;
using System.Text;

namespace DoubaoMurmur.Core;

/// <summary>
/// Minimal file logger. The app is a background tray process with no console, so
/// the log file is the only way to diagnose a failed hotkey / paste / connection.
/// </summary>
public static class Log
{
    private static readonly object Gate = new();
    private const long MaxBytes = 2 * 1024 * 1024;
    private static bool _failed;

    public static void Info(string message, [System.Runtime.CompilerServices.CallerMemberName] string caller = "")
        => Write("INFO ", message, caller);

    public static void Warn(string message, [System.Runtime.CompilerServices.CallerMemberName] string caller = "")
        => Write("WARN ", message, caller);

    public static void Error(string message, Exception? ex = null,
        [System.Runtime.CompilerServices.CallerMemberName] string caller = "")
        => Write("ERROR", ex is null ? message : $"{message}: {ex}", caller);

    private static void Write(string level, string message, string caller)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{level}] {caller}: {message}";
        Debug.WriteLine(line);
        if (_failed) return;

        lock (Gate)
        {
            try
            {
                var path = AppConfig.LogPath;
                var info = new FileInfo(path);
                if (info.Exists && info.Length > MaxBytes)
                {
                    var old = path + ".1";
                    File.Delete(old);
                    File.Move(path, old);
                }
                File.AppendAllText(path, line + Environment.NewLine, Encoding.UTF8);
            }
            catch
            {
                // Never let logging take the app down; stop trying after the first failure.
                _failed = true;
            }
        }
    }
}
