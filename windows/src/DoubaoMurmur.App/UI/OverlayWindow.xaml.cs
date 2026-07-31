using System.Text.Json;
using System.Text.Json.Serialization;
using DoubaoMurmur.Core;
using DoubaoMurmur.Platform;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace DoubaoMurmur.UI;

/// <summary>
/// Borderless status overlay pinned above every other window. Mirrors
/// OverlayPanel.swift + OverlayView.swift.
///
/// It must never take focus — the whole point is to paste into whatever the user
/// was already typing in — which is why WS_EX_NOACTIVATE is applied to the HWND
/// before the window is ever shown.
/// </summary>
public sealed partial class OverlayWindow : Window
{
    private readonly IntPtr _hwnd;
    private readonly AppWindow _appWindow;

    private bool _dragging;
    private NativeMethods.POINT _dragStartCursor;
    private PointInt32 _dragStartWindow;
    private OverlayGeometry? _saved;

    public OverlayWindow()
    {
        InitializeComponent();

        _hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        _appWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(_hwnd));

        Title = "Doubao Murmur";

        if (_appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.SetBorderAndTitleBar(false, false);
            presenter.IsAlwaysOnTop = true;
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
        }
        _appWindow.IsShownInSwitchers = false;

        // Applied before the first Show so the window can never grab focus.
        WindowHelper.MakeNonActivating(_hwnd);
        WindowHelper.SetRoundedCorners(_hwnd);
        _appWindow.Hide();

        RootGrid.PointerPressed += OnPointerPressed;
        RootGrid.PointerMoved += OnPointerMoved;
        RootGrid.PointerReleased += OnPointerReleased;

        _saved = OverlayGeometry.Load();
    }

    public void ShowOverlay()
    {
        Reposition();
        _appWindow.Show(false);
        WindowHelper.ShowWithoutActivating(_hwnd);
    }

    public void HideOverlay() => _appWindow.Hide();

    public void UpdateText(string text)
    {
        TranscriptText.Text = string.IsNullOrEmpty(text) ? "正在聆听…" : text;
        TranscriptText.Foreground = new SolidColorBrush(Microsoft.UI.Colors.White);
    }

    public void ShowError(string message)
    {
        TranscriptText.Text = message;
        TranscriptText.Foreground = new SolidColorBrush(
            Windows.UI.Color.FromArgb(0xFF, 0xFF, 0x66, 0x66));
    }

    public void SetRecording(bool recording)
    {
        Indicator.Fill = new SolidColorBrush(recording
            ? Windows.UI.Color.FromArgb(0xFF, 0xFF, 0x5F, 0x57)
            : Windows.UI.Color.FromArgb(0xFF, 0x8A, 0x8A, 0x8A));
    }

    private void Reposition()
    {
        var scale = WindowHelper.GetScale(_hwnd);
        var width = (int)Math.Round(AppConfig.OverlayWidth * scale);
        var height = (int)Math.Round(AppConfig.OverlayHeight * scale);

        var cursor = WindowHelper.GetCursorPosition();
        var display = DisplayArea.GetFromPoint(new PointInt32(cursor.X, cursor.Y),
            DisplayAreaFallback.Nearest);
        var work = display.WorkArea;

        int x, y;
        if (_saved is not null && IsOnScreen(_saved, work, width, height))
        {
            x = _saved.X;
            y = _saved.Y;
        }
        else
        {
            x = work.X + (work.Width - width) / 2;
            y = work.Y + (int)Math.Round(AppConfig.OverlayTopMargin * scale);
        }

        _appWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }

    private static bool IsOnScreen(OverlayGeometry geometry, RectInt32 work, int width, int height)
    {
        // Keep at least a strip of the overlay reachable if the monitor layout changed.
        var right = geometry.X + width;
        var bottom = geometry.Y + height;
        return right > work.X + 80 &&
               geometry.X < work.X + work.Width - 80 &&
               bottom > work.Y &&
               geometry.Y < work.Y + work.Height - 20;
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        _dragStartCursor = WindowHelper.GetCursorPosition();
        _dragStartWindow = _appWindow.Position;
        _dragging = RootGrid.CapturePointer(e.Pointer);
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;

        var cursor = WindowHelper.GetCursorPosition();
        var x = _dragStartWindow.X + (cursor.X - _dragStartCursor.X);
        var y = _dragStartWindow.Y + (cursor.Y - _dragStartCursor.Y);
        _appWindow.Move(new PointInt32(x, y));
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        RootGrid.ReleasePointerCapture(e.Pointer);

        var position = _appWindow.Position;
        _saved = new OverlayGeometry { X = position.X, Y = position.Y };
        _saved.Save();
    }
}

/// <summary>Remembered overlay position, mirroring the Linux overlay.json.</summary>
internal sealed class OverlayGeometry
{
    [JsonPropertyName("x")] public int X { get; set; }
    [JsonPropertyName("y")] public int Y { get; set; }

    public static OverlayGeometry? Load()
    {
        try
        {
            var path = AppConfig.OverlayConfigPath;
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<OverlayGeometry>(File.ReadAllText(path));
        }
        catch (Exception ex)
        {
            Log.Warn($"Could not load overlay position: {ex.Message}");
            return null;
        }
    }

    public void Save()
    {
        try
        {
            File.WriteAllText(AppConfig.OverlayConfigPath, JsonSerializer.Serialize(this));
        }
        catch (Exception ex)
        {
            Log.Warn($"Could not save overlay position: {ex.Message}");
        }
    }
}
