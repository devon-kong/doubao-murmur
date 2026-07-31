using DoubaoMurmur.Core;

namespace DoubaoMurmur.Platform;

/// <summary>
/// Debounces the raw hook events and marshals them onto the UI thread.
/// Mirrors HotkeyManager.swift / hotkey/manager.py.
/// </summary>
internal sealed class HotkeyManager : IDisposable
{
    private readonly LowLevelKeyboardHook _hook = new();
    private readonly IDispatcher _dispatcher;

    private DateTime _lastToggle = DateTime.MinValue;
    private bool _cancelEnabled;

    public HotkeyManager(IDispatcher dispatcher)
    {
        _dispatcher = dispatcher;
        _hook.TogglePressed += OnTogglePressed;
        _hook.CancelPressed += OnCancelPressed;
    }

    public Action? OnToggle { get; set; }
    public Action? OnCancel { get; set; }

    public bool IsActive => _hook.IsInstalled;

    public bool Start(AppSettings settings)
    {
        _hook.ToggleKey = settings.ToggleKey;
        _hook.SuppressToggleKey = settings.SuppressToggleKey;
        return _hook.Install();
    }

    public void ApplySettings(AppSettings settings)
    {
        _hook.ToggleKey = settings.ToggleKey;
        _hook.SuppressToggleKey = settings.SuppressToggleKey;
        Log.Info($"Hotkey updated: {settings.ToggleKey}, suppress={settings.SuppressToggleKey}");
    }

    public void SetCancelEnabled(bool enabled) => _cancelEnabled = enabled;

    private void OnTogglePressed()
    {
        var now = DateTime.UtcNow;
        if (now - _lastToggle < AppConfig.DebounceInterval) return;
        _lastToggle = now;
        _dispatcher.Post(() => OnToggle?.Invoke());
    }

    private void OnCancelPressed()
    {
        if (!_cancelEnabled) return;
        _dispatcher.Post(() =>
        {
            if (_cancelEnabled) OnCancel?.Invoke();
        });
    }

    public void Stop() => _hook.Uninstall();

    public void Dispose()
    {
        _hook.TogglePressed -= OnTogglePressed;
        _hook.CancelPressed -= OnCancelPressed;
        _hook.Dispose();
    }
}
