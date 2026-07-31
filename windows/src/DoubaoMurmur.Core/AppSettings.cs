using System.Text.Json;
using System.Text.Json.Serialization;

namespace DoubaoMurmur.Core;

/// <summary>
/// The key that toggles dictation. Right Alt matches macOS/Linux, but it is
/// configurable because a bare Alt tap opens the menu bar in some Win32 apps and
/// because AltGr layouts put a third meaning on that same physical key.
/// </summary>
public enum ToggleKey
{
    RightAlt,
    RightControl,
    RightShift,
    ScrollLock,
    Pause,
}

public enum PasteMode
{
    /// <summary>Copy to clipboard, then send Ctrl+V.</summary>
    Clipboard,

    /// <summary>Type the text directly with synthesised Unicode keystrokes.</summary>
    Typing,
}

public sealed class AppSettings
{
    [JsonPropertyName("toggle_key")]
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public ToggleKey ToggleKey { get; set; } = ToggleKey.RightAlt;

    /// <summary>
    /// Swallow the toggle key so the app under the cursor never sees it. Stops a
    /// bare Alt tap from opening menu bars, but also disables AltGr, so it is off
    /// by default.
    /// </summary>
    [JsonPropertyName("suppress_toggle_key")]
    public bool SuppressToggleKey { get; set; }

    [JsonPropertyName("paste_mode")]
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public PasteMode PasteMode { get; set; } = PasteMode.Clipboard;

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static AppSettings Load()
    {
        try
        {
            var path = AppConfig.SettingsPath;
            if (!File.Exists(path)) return new AppSettings();
            return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), Options)
                   ?? new AppSettings();
        }
        catch (Exception ex)
        {
            Log.Warn($"Failed to load settings, using defaults: {ex.Message}");
            return new AppSettings();
        }
    }

    public void Save()
    {
        try
        {
            File.WriteAllText(AppConfig.SettingsPath, JsonSerializer.Serialize(this, Options));
        }
        catch (Exception ex)
        {
            Log.Error("Failed to save settings", ex);
        }
    }
}
