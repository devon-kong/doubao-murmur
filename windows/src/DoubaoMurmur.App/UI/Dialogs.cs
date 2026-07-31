using DoubaoMurmur.Platform;

namespace DoubaoMurmur.UI;

/// <summary>
/// Native message boxes. A ContentDialog needs a XamlRoot from a visible window,
/// which a tray-only app does not reliably have.
/// </summary>
internal static class Dialogs
{
    private const string Caption = "Doubao Murmur";

    public static void Info(string message) =>
        Show(message, NativeMethods.MB_OK | NativeMethods.MB_ICONINFORMATION);

    public static void Warn(string message) =>
        Show(message, NativeMethods.MB_OK | NativeMethods.MB_ICONWARNING);

    public static void Error(string message) =>
        Show(message, NativeMethods.MB_OK | NativeMethods.MB_ICONERROR);

    public static bool Confirm(string message) =>
        Show(message, NativeMethods.MB_YESNO | NativeMethods.MB_ICONQUESTION) == NativeMethods.IDYES;

    private static int Show(string message, uint flags) =>
        NativeMethods.MessageBoxW(IntPtr.Zero, message, Caption,
            flags | NativeMethods.MB_SETFOREGROUND | NativeMethods.MB_TOPMOST);
}
