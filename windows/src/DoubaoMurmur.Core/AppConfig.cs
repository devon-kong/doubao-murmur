namespace DoubaoMurmur.Core;

/// <summary>
/// Constants for the Doubao ASR service and local paths.
/// Mirrors DoubaoASRClient.swift and linux/src/doubao_murmur/config.py — keep the
/// three implementations in sync (see docs/asr-protocol.md).
/// </summary>
public static class AppConfig
{
    // --- Doubao ASR WebSocket ---

    public const string WssBaseUrl = "wss://ws-samantha.doubao.com/samantha/audio/asr";
    public const string Origin = "https://www.doubao.com";
    public const string LoginUrl = "https://www.doubao.com/chat";
    public const string GitHubRepo = "lilong7676/doubao-murmur";

    /// <summary>
    /// Query parameters that never change, in the same order the macOS client sends
    /// them. device_id / web_id / tea_uuid / web_tab_id are filled in per connection
    /// by <see cref="DoubaoAsrClient.BuildUrl"/>.
    /// </summary>
    public static readonly (string Key, string Value)[] FixedQueryParams =
    {
        ("version_code", "20800"),
        ("language", "zh"),
        ("device_platform", "web"),
        ("aid", "497858"),
        ("real_aid", "497858"),
        ("pkg_type", "release_version"),
        ("pc_version", "3.12.3"),
        ("region", ""),
        ("sys_region", ""),
        ("samantha_web", "1"),
        ("use-olympus-account", "1"),
        ("format", "pcm"),
    };

    // --- Auth error detection ---

    public const long AuthErrorCode = 709599054;

    public static readonly string[] AuthErrorKeywords =
    {
        "cookie", "auth", "login", "session", "unauthorized", "expired",
    };

    // --- Audio capture ---

    public const int AudioSampleRate = 16000;
    public const int AudioChannels = 1;
    public const int AudioBitsPerSample = 16;

    /// <summary>Chunk length pushed to the WebSocket. 100ms keeps partial results snappy.</summary>
    public const int AudioChunkMilliseconds = 100;

    public static int AudioChunkBytes =>
        AudioSampleRate * AudioChannels * (AudioBitsPerSample / 8) * AudioChunkMilliseconds / 1000;

    // --- Timeouts ---

    public static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan StopSafetyTimeout = TimeSpan.FromSeconds(1);
    public static readonly TimeSpan DebounceInterval = TimeSpan.FromMilliseconds(300);
    public static readonly TimeSpan PasteDelay = TimeSpan.FromMilliseconds(80);
    public static readonly TimeSpan AuthExpiryDelay = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan CookieSettleDelay = TimeSpan.FromSeconds(1);

    // --- Overlay UI ---

    public const int OverlayWidth = 760;
    public const int OverlayHeight = 88;
    public const int OverlayTopMargin = 60;
    public const int OverlayMaxLines = 5;

    // --- WebView ---

    public const string WebViewUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

    // --- Paths ---

    private const string AppDirName = "doubao-murmur";
    private static string? _configDirOverride;

    /// <summary>Test hook: redirect all config files to a temp directory.</summary>
    public static void OverrideConfigDir(string? path) => _configDirOverride = path;

    /// <summary>%APPDATA%\doubao-murmur — holds credentials and window geometry.</summary>
    public static string ConfigDir
    {
        get
        {
            var dir = _configDirOverride ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), AppDirName);
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    /// <summary>%LOCALAPPDATA%\doubao-murmur — holds caches that need not roam.</summary>
    public static string LocalDataDir
    {
        get
        {
            var dir = _configDirOverride ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppDirName);
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    public static string ParamsPath => Path.Combine(ConfigDir, "asr_params.json");
    public static string OverlayConfigPath => Path.Combine(ConfigDir, "overlay.json");
    public static string SettingsPath => Path.Combine(ConfigDir, "settings.json");
    public static string LogPath => Path.Combine(LocalDataDir, "app.log");

    /// <summary>
    /// WebView2 needs an explicit user-data folder for unpackaged apps; the default
    /// sits next to the executable and fails when installed under Program Files.
    /// </summary>
    public static string WebView2UserDataDir => Path.Combine(LocalDataDir, "WebView2");
}
