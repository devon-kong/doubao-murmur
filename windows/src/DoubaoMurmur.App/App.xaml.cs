using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using DoubaoMurmur.Core;
using DoubaoMurmur.Platform;
using DoubaoMurmur.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace DoubaoMurmur;

/// <summary>
/// Application shell. Mirrors DoubaoMurmurApp.swift / linux app.py: owns every
/// component and wires the state machine to the tray, overlay, hotkeys and login
/// window.
/// </summary>
public partial class App : Application
{
    private readonly SingleInstance _singleInstance = new();

    private AppSettings _settings = new();
    private AppState _state = new();
    private WinUiDispatcher? _dispatcher;
    private DoubaoAsrClient? _asrClient;
    private WasapiMicSource? _audio;
    private TranscriptionManager? _transcription;
    private HotkeyManager? _hotkeys;
    private TrayIcon? _tray;
    private OverlayWindow? _overlay;
    private LoginWindow? _login;
    private HelpWindow? _help;
    private DispatcherQueueTimer? _keepAlive;
    private bool _shuttingDown;

    public App()
    {
        InitializeComponent();
        UnhandledException += OnUnhandledException;
    }

    private static string CurrentVersion =>
        Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion.Split('+')[0] ?? "1.0.0";

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (!_singleInstance.TryAcquire())
        {
            Environment.Exit(0);
            return;
        }

        Log.Info($"Starting Doubao Murmur {CurrentVersion} on {Environment.OSVersion}");

        try
        {
            SetupComponents();
        }
        catch (Exception ex)
        {
            Log.Error("Startup failed", ex);
            Dialogs.Error($"启动失败：{ex.Message}\n\n详情见日志：\n{AppConfig.LogPath}");
            Environment.Exit(1);
        }
    }

    private void SetupComponents()
    {
        _settings = AppSettings.Load();
        _dispatcher = new WinUiDispatcher(DispatcherQueue.GetForCurrentThread());

        _state = new AppState();
        _state.PropertyChanged += OnStateChanged;
        _state.LoginStatus = AsrParamsStore.HasSaved() ? LoginStatus.LoggedIn : LoginStatus.NotLoggedIn;
        Log.Info(AsrParamsStore.HasSaved()
            ? "Cached params found, skipping login"
            : "No cached params; login required");

        _overlay = new OverlayWindow();

        _asrClient = new DoubaoAsrClient();
        _audio = new WasapiMicSource();
        _transcription = new TranscriptionManager(_state, _asrClient, _audio, _dispatcher)
        {
            OnShowLogin = ShowLogin,
            OnPaste = text => _ = PasteAsync(text),
            OnOverlayShow = () => _overlay?.ShowOverlay(),
            OnOverlayHide = () => _overlay?.HideOverlay(),
            OnOverlayUpdate = text => _overlay?.UpdateText(text),
            OnParamsNeeded = RequestParams,
            OnAuthExpired = OnAuthExpired,
            OnCancelEnabledChanged = enabled => _hotkeys?.SetCancelEnabled(enabled),
        };

        _hotkeys = new HotkeyManager(_dispatcher)
        {
            OnToggle = () => _transcription?.HandleToggle(),
            OnCancel = () => _transcription?.HandleCancel(),
        };

        if (!_hotkeys.Start(_settings))
        {
            Dialogs.Error(
                "无法安装全局键盘钩子，热键将不可用。\n\n" +
                "请确认没有其他安全软件拦截，然后重启本程序。");
        }

        _tray = new TrayIcon(BuildMenuState);
        _tray.LoginClicked += ShowLogin;
        _tray.LogoutClicked += () => _ = LogoutAsync();
        _tray.HelpClicked += ShowHelp;
        _tray.OpenLogClicked += OpenLog;
        _tray.CheckUpdateClicked += () => _ = CheckForUpdatesAsync(silent: false);
        _tray.AutoStartToggled += ToggleAutoStart;
        _tray.SuppressToggleKeyToggled += ToggleSuppressHotkey;
        _tray.ToggleKeyChanged += ChangeToggleKey;
        _tray.QuitClicked += Quit;

        if (!_tray.Start())
        {
            Dialogs.Warn("无法创建托盘图标，但热键仍然可用。");
        }

        StartKeepAlive();
        Log.Info("All components initialised");
    }

    /// <summary>
    /// This app shows no window at startup. A periodic no-op keeps work in the
    /// dispatcher queue so the XAML message loop has no reason to unwind.
    /// </summary>
    private void StartKeepAlive()
    {
        var queue = DispatcherQueue.GetForCurrentThread();
        _keepAlive = queue.CreateTimer();
        _keepAlive.Interval = TimeSpan.FromMinutes(1);
        _keepAlive.IsRepeating = true;
        _keepAlive.Tick += (_, _) => { };
        _keepAlive.Start();
    }

    private TrayMenuState BuildMenuState() => new(
        LoggedIn: _state.LoginStatus == LoginStatus.LoggedIn,
        Recording: _state.IsRecording,
        ToggleKey: _settings.ToggleKey,
        SuppressToggleKey: _settings.SuppressToggleKey,
        AutoStart: AutoStart.IsEnabled);

    private void OnStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppState.ErrorMessage):
                if (!string.IsNullOrEmpty(_state.ErrorMessage)) _overlay?.ShowError(_state.ErrorMessage!);
                break;
            case nameof(AppState.RecordingState):
                _overlay?.SetRecording(_state.RecordingState == RecordingState.Recording);
                _tray?.Refresh();
                break;
            case nameof(AppState.LoginStatus):
                _tray?.Refresh();
                break;
        }
    }

    private async Task PasteAsync(string text)
    {
        try
        {
            await PasteHelper.CopyAndPasteAsync(text, _settings.PasteMode);
        }
        catch (Exception ex)
        {
            Log.Error("Paste failed", ex);
        }
    }

    // --- Login ---

    private void ShowLogin() => _ = ShowLoginAsync();

    private async Task ShowLoginAsync()
    {
        try
        {
            if (_login is null)
            {
                var window = new LoginWindow();
                window.LoginStatusChanged += OnLoginStatusChanged;
                window.Closed += (_, _) => _login = null;
                _login = window;

                if (!await window.InitialiseAsync())
                {
                    _login = null;
                    return;
                }

                await window.LoadAsync();
            }

            _login.ShowWindow();
        }
        catch (Exception ex)
        {
            Log.Error("Could not open the login window", ex);
            Dialogs.Error($"打开登录窗口失败：{ex.Message}");
            _login = null;
        }
    }

    private void OnLoginStatusChanged(string status, string? nickname)
    {
        if (status == "loggedIn")
        {
            _state.LoginStatus = LoginStatus.LoggedIn;
            Log.Info($"Logged in{(string.IsNullOrEmpty(nickname) ? string.Empty : $" as {nickname}")}");

            // Give the browser a moment to commit its cookies before reading them.
            _dispatcher?.Schedule(AppConfig.CookieSettleDelay, () => _ = ExtractAndStoreAsync());
        }
        else
        {
            _state.LoginStatus = LoginStatus.NotLoggedIn;
        }
    }

    private async Task ExtractAndStoreAsync()
    {
        var window = _login;
        if (window is null) return;

        var parameters = await window.ExtractParamsAsync();
        if (parameters is not null)
        {
            AsrParamsStore.Save(parameters);
            _state.LoginStatus = LoginStatus.LoggedIn;
        }
        else
        {
            Dialogs.Warn("登录成功，但没有取到连接参数。请重新打开登录窗口再试一次。");
        }

        // Mirrors destroyWebView(): drop the browser as soon as we have credentials.
        window.HideWindow();
        window.Teardown();
        _login = null;
        _tray?.Refresh();
    }

    /// <summary>Called by the state machine when no cached credentials exist.</summary>
    private void RequestParams(Action<AsrParams?> callback)
    {
        var window = _login;
        if (window is null || !window.IsReady)
        {
            callback(null);
            return;
        }

        _ = Task.Run(async () =>
        {
            var parameters = await window.ExtractParamsAsync();
            _dispatcher?.Post(() => callback(parameters));
        });
    }

    private void OnAuthExpired()
    {
        if (Dialogs.Confirm("豆包登录凭证已失效，是否重新登录？")) ShowLogin();
    }

    private async Task LogoutAsync()
    {
        AsrParamsStore.Clear();
        _state.LoginStatus = LoginStatus.NotLoggedIn;

        if (_login is not null)
        {
            await _login.ClearSessionAsync();
        }
        else
        {
            // No browser is running, so the profile directory can just be removed.
            try
            {
                if (Directory.Exists(AppConfig.WebView2UserDataDir))
                {
                    Directory.Delete(AppConfig.WebView2UserDataDir, recursive: true);
                }
            }
            catch (Exception ex)
            {
                Log.Warn($"Could not delete WebView2 profile: {ex.Message}");
            }
        }

        _tray?.Refresh();
        Dialogs.Info("已退出登录。");
    }

    // --- Tray commands ---

    private void ShowHelp()
    {
        try
        {
            _help = new HelpWindow(_settings.ToggleKey);
            _help.Activate();
        }
        catch (Exception ex)
        {
            Log.Error("Could not open help", ex);
        }
    }

    private static void OpenLog()
    {
        try
        {
            var path = AppConfig.LogPath;
            if (!File.Exists(path)) File.WriteAllText(path, string.Empty);
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Error("Could not open the log", ex);
            Dialogs.Info($"日志位置：\n{AppConfig.LogPath}");
        }
    }

    private void ToggleAutoStart()
    {
        AutoStart.SetEnabled(!AutoStart.IsEnabled);
        _tray?.Refresh();
    }

    private void ToggleSuppressHotkey()
    {
        _settings.SuppressToggleKey = !_settings.SuppressToggleKey;
        _settings.Save();
        _hotkeys?.ApplySettings(_settings);
    }

    private void ChangeToggleKey(ToggleKey key)
    {
        _settings.ToggleKey = key;
        _settings.Save();
        _hotkeys?.ApplySettings(_settings);
    }

    private async Task CheckForUpdatesAsync(bool silent)
    {
        try
        {
            var info = await UpdateChecker.CheckAsync(CurrentVersion);
            if (info is null)
            {
                if (!silent) Dialogs.Info($"已经是最新版本（{CurrentVersion}）。");
                return;
            }

            if (Dialogs.Confirm($"发现新版本 {info.Version}（当前 {CurrentVersion}），是否前往下载？"))
            {
                Process.Start(new ProcessStartInfo(info.ReleaseUrl) { UseShellExecute = true });
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"Update check failed: {ex.Message}");
            if (!silent) Dialogs.Warn("检查更新失败，请稍后再试。");
        }
    }

    private void Quit()
    {
        if (_shuttingDown) return;
        _shuttingDown = true;
        Log.Info("Shutting down");

        try
        {
            _keepAlive?.Stop();
            _transcription?.HandleCancel();
            _hotkeys?.Dispose();
            _tray?.Dispose();
            _transcription?.Dispose();
            _asrClient?.Dispose();
            _audio?.Dispose();
            _login?.Teardown();
            _help?.Close();
            _overlay?.Close();
            _singleInstance.Dispose();
        }
        catch (Exception ex)
        {
            Log.Warn($"Cleanup during shutdown: {ex.Message}");
        }

        Exit();

        // XAML shutdown can stall for a process whose windows were never activated.
        _ = Task.Delay(1500).ContinueWith(_ => Environment.Exit(0));
    }

    private static void OnUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        Log.Error("Unhandled exception", e.Exception);
        e.Handled = true;
    }
}
