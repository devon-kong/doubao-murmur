using System.Text.Json;
using DoubaoMurmur.Core;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.Web.WebView2.Core;

namespace DoubaoMurmur.UI;

/// <summary>
/// WebView2 login window for doubao.com. Mirrors WebViewManager.swift.
///
/// Loads the chat page, watches for a successful login three different ways, then
/// lifts the cookies (including HttpOnly ones, which document.cookie cannot see)
/// and the two localStorage ids needed to open an ASR socket. The window is torn
/// down afterwards so the browser process does not linger.
/// </summary>
public sealed partial class LoginWindow : Window
{
    private readonly IntPtr _hwnd;
    private readonly AppWindow _appWindow;
    private readonly DispatcherQueue _dispatcher;

    private DispatcherQueueTimer? _loginPollTimer;
    private bool _initialised;
    private bool _loginReported;

    public LoginWindow()
    {
        InitializeComponent();

        _hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        _appWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(_hwnd));
        _dispatcher = DispatcherQueue.GetForCurrentThread();

        Title = "Doubao Murmur - 登录豆包";
        _appWindow.Resize(new Windows.Graphics.SizeInt32(1280, 860));

        Closed += (_, _) => StopPolling();
    }

    /// <summary>Raised with ("loggedIn" | "notLoggedIn", nickname).</summary>
    public event Action<string, string?>? LoginStatusChanged;

    public bool IsReady => _initialised && Browser.CoreWebView2 is not null;

    public async Task<bool> InitialiseAsync()
    {
        if (_initialised) return true;

        try
        {
            // Unpackaged apps must name their own user-data folder; the default sits
            // next to the executable and fails when installed under Program Files.
            Directory.CreateDirectory(AppConfig.WebView2UserDataDir);
            // The Windows App SDK flavour of WebView2 exposes only CreateAsync() with
            // no arguments; naming a user-data folder goes through the options form.
            var environment = await CoreWebView2Environment.CreateWithOptionsAsync(
                string.Empty, AppConfig.WebView2UserDataDir, new CoreWebView2EnvironmentOptions());

            await Browser.EnsureCoreWebView2Async(environment);
        }
        catch (Exception ex)
        {
            Log.Error("WebView2 initialisation failed", ex);
            Dialogs.Error(
                "无法初始化 WebView2。\n\n" +
                "请确认已安装 Microsoft Edge WebView2 Runtime（Windows 11 及较新的 " +
                "Windows 10 自带）。可从以下地址安装：\n" +
                "https://developer.microsoft.com/microsoft-edge/webview2/");
            return false;
        }

        var core = Browser.CoreWebView2;
        core.Settings.UserAgent = AppConfig.WebViewUserAgent;
        core.Settings.AreDevToolsEnabled = true;

        var websocketJs = LoadScript("inject-websocket.js");
        if (websocketJs is not null)
        {
            await core.AddScriptToExecuteOnDocumentCreatedAsync(websocketJs);
        }

        var domJs = LoadScript("inject-dom.js");
        if (domJs is not null)
        {
            await core.AddScriptToExecuteOnDocumentCreatedAsync(domJs);
        }

        core.WebMessageReceived += OnWebMessageReceived;
        core.NavigationStarting += OnNavigationStarting;
        core.NavigationCompleted += OnNavigationCompleted;

        _initialised = true;
        return true;
    }

    /// <summary>
    /// The shared scripts target WKWebView's message bridge; WebView2 exposes the
    /// same capability under a different name. Rewriting at load time keeps a single
    /// copy of the JS in sync with the macOS and Linux builds.
    /// </summary>
    private static string? LoadScript(string name)
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Assets", name);
            if (!File.Exists(path))
            {
                Log.Warn($"Injected script missing: {path}");
                return null;
            }

            return File.ReadAllText(path)
                .Replace("window.webkit.messageHandlers.asr_handler.postMessage",
                    "window.chrome.webview.postMessage")
                .Replace("window.webkit.messageHandlers.asrHandler.postMessage",
                    "window.chrome.webview.postMessage");
        }
        catch (Exception ex)
        {
            Log.Error($"Could not load script {name}", ex);
            return null;
        }
    }

    public async Task LoadAsync()
    {
        if (!await InitialiseAsync()) return;
        _loginReported = false;
        Browser.CoreWebView2.Navigate(AppConfig.LoginUrl);
    }

    public void ShowWindow()
    {
        _appWindow.Show();
        NativeActivate();
    }

    private void NativeActivate()
    {
        try
        {
            Activate();
        }
        catch (Exception ex)
        {
            Log.Warn($"Login window activation failed: {ex.Message}");
        }
    }

    public void HideWindow() => _appWindow.Hide();

    private void OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            using var document = JsonDocument.Parse(e.WebMessageAsJson);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return;

            if (!root.TryGetProperty("type", out var type) || type.GetString() != "login") return;

            var status = root.TryGetProperty("status", out var statusElement)
                ? statusElement.GetString() ?? "unknown"
                : "unknown";
            var nickname = root.TryGetProperty("nickname", out var nicknameElement)
                ? nicknameElement.GetString()
                : null;

            ReportLogin(status, nickname);
        }
        catch (Exception ex)
        {
            Log.Warn($"Ignoring malformed web message: {ex.Message}");
        }
    }

    private void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        // Doubao appends from_login=1 when it bounces back from its login flow.
        if (e.Uri.Contains("from_login=1", StringComparison.OrdinalIgnoreCase))
        {
            ReportLogin("loggedIn", null);
        }
    }

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        StartPolling();
    }

    /// <summary>
    /// Third detection path: some sessions never hit the profile API while the
    /// window is open, so poll the DOM for the login button as well.
    /// </summary>
    private void StartPolling()
    {
        StopPolling();

        var timer = _dispatcher.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(2);
        timer.IsRepeating = true;
        timer.Tick += async (_, _) => await PollLoginStateAsync();
        timer.Start();
        _loginPollTimer = timer;
    }

    private void StopPolling()
    {
        _loginPollTimer?.Stop();
        _loginPollTimer = null;
    }

    private async Task PollLoginStateAsync()
    {
        if (Browser.CoreWebView2 is null) return;

        try
        {
            var raw = await Browser.CoreWebView2.ExecuteScriptAsync(
                "(window.__doubaoMurmur && window.__doubaoMurmur.isLoginButtonPresent()) === true");
            if (raw == "true")
            {
                ReportLogin("notLoggedIn", null);
                return;
            }

            // No login button and credentials already in localStorage means the
            // session is live even though we never saw the profile request.
            var hasIds = await Browser.CoreWebView2.ExecuteScriptAsync(
                "(!!localStorage.getItem('__tea_cache_tokens_497858'))");
            if (hasIds == "true") ReportLogin("loggedIn", null);
        }
        catch (Exception ex)
        {
            Log.Warn($"Login poll failed: {ex.Message}");
        }
    }

    private void ReportLogin(string status, string? nickname)
    {
        if (status == "loggedIn")
        {
            if (_loginReported) return;
            _loginReported = true;
            StopPolling();
        }

        LoginStatusChanged?.Invoke(status, nickname);
    }

    /// <summary>Pull cookies + localStorage ids out of the live session.</summary>
    public async Task<AsrParams?> ExtractParamsAsync()
    {
        if (Browser.CoreWebView2 is null) return null;

        try
        {
            // Cookies applicable to the origin, which is what the macOS and Linux
            // clients collect; the domain filter then keeps subdomain entries too.
            var cookies = await Browser.CoreWebView2.CookieManager.GetCookiesAsync(AppConfig.Origin);
            var collected = new Dictionary<string, string>();
            foreach (var cookie in cookies)
            {
                if (!cookie.Domain.Contains("doubao.com", StringComparison.OrdinalIgnoreCase)) continue;
                collected[cookie.Name] = cookie.Value;
            }

            if (collected.Count == 0)
            {
                Log.Warn("No doubao.com cookies found");
                return null;
            }

            const string script = """
                JSON.stringify({
                    device_id_raw: localStorage.getItem('samantha_web_web_id'),
                    tea_cache_raw: localStorage.getItem('__tea_cache_tokens_497858')
                })
                """;

            var raw = await Browser.CoreWebView2.ExecuteScriptAsync(script);

            // ExecuteScriptAsync returns the result JSON-encoded, so a string result
            // arrives quoted and has to be unwrapped before it can be parsed.
            var inner = JsonSerializer.Deserialize<string>(raw);
            if (string.IsNullOrEmpty(inner))
            {
                Log.Warn("localStorage probe returned nothing");
                return null;
            }

            using var document = JsonDocument.Parse(inner);
            var root = document.RootElement;

            var deviceId = string.Empty;
            var webId = string.Empty;
            var userUniqueId = string.Empty;

            if (TryGetString(root, "device_id_raw", out var deviceRaw))
            {
                deviceId = ReadStringField(deviceRaw, "web_id");
            }

            if (TryGetString(root, "tea_cache_raw", out var teaRaw))
            {
                webId = ReadStringField(teaRaw, "web_id");
                userUniqueId = ReadStringField(teaRaw, "user_unique_id");
            }

            // doubao.com dropped samantha_web_web_id when it renamed its localStorage
            // keys; the tea SDK cache still carries the same id (Linux commit 538c950).
            if (deviceId.Length == 0)
            {
                deviceId = userUniqueId.Length > 0 ? userUniqueId : webId;
            }

            if (deviceId.Length == 0 || webId.Length == 0)
            {
                Log.Warn($"Missing localStorage params: device='{deviceId}', web='{webId}'");
                return null;
            }

            Log.Info($"Params extracted: {collected.Count} cookies, device={Preview(deviceId)}, " +
                     $"web={Preview(webId)}");

            return new AsrParams
            {
                Cookies = collected,
                DeviceId = deviceId,
                WebId = webId,
            };
        }
        catch (Exception ex)
        {
            Log.Error("Parameter extraction failed", ex);
            return null;
        }
    }

    private static string Preview(string value) =>
        value.Length <= 6 ? new string('*', value.Length) : value[..6] + "…";

    private static bool TryGetString(JsonElement root, string name, out string value)
    {
        value = string.Empty;
        if (!root.TryGetProperty(name, out var element)) return false;
        if (element.ValueKind != JsonValueKind.String) return false;
        value = element.GetString() ?? string.Empty;
        return value.Length > 0;
    }

    /// <summary>Reads one field out of a JSON string stored inside localStorage.</summary>
    private static string ReadStringField(string json, string field)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object) return string.Empty;
            if (!document.RootElement.TryGetProperty(field, out var element)) return string.Empty;

            // These ids are sometimes numbers and sometimes strings.
            return element.ValueKind switch
            {
                JsonValueKind.String => element.GetString()?.Trim() ?? string.Empty,
                JsonValueKind.Number => element.GetRawText().Trim(),
                _ => string.Empty,
            };
        }
        catch (JsonException)
        {
            return string.Empty;
        }
    }

    public async Task ClearSessionAsync()
    {
        if (Browser.CoreWebView2 is null) return;
        try
        {
            await Browser.CoreWebView2.Profile.ClearBrowsingDataAsync();
            Log.Info("Cleared WebView2 browsing data");
        }
        catch (Exception ex)
        {
            Log.Warn($"Could not clear browsing data: {ex.Message}");
        }
    }

    public void Teardown()
    {
        StopPolling();
        try
        {
            if (Browser.CoreWebView2 is not null)
            {
                Browser.CoreWebView2.WebMessageReceived -= OnWebMessageReceived;
                Browser.CoreWebView2.NavigationStarting -= OnNavigationStarting;
                Browser.CoreWebView2.NavigationCompleted -= OnNavigationCompleted;
            }
            Browser.Close();
        }
        catch (Exception ex)
        {
            Log.Warn($"WebView teardown: {ex.Message}");
        }

        _initialised = false;
        Close();
    }
}
