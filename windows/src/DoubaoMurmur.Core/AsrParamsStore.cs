using System.Text.Json;

namespace DoubaoMurmur.Core;

/// <summary>Persists <see cref="AsrParams"/> to %APPDATA%\doubao-murmur\asr_params.json.</summary>
public static class AsrParamsStore
{
    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static void Save(AsrParams parameters)
    {
        try
        {
            File.WriteAllText(AppConfig.ParamsPath, JsonSerializer.Serialize(parameters, WriteOptions));
            Log.Info($"Saved ASR params ({parameters.Cookies.Count} cookies)");
        }
        catch (Exception ex)
        {
            Log.Error("Failed to save params", ex);
        }
    }

    public static AsrParams? Load()
    {
        var path = AppConfig.ParamsPath;
        if (!File.Exists(path)) return null;

        string json;
        try
        {
            json = File.ReadAllText(path);
        }
        catch (Exception ex)
        {
            Log.Error("Failed to read params", ex);
            return null;
        }

        try
        {
            var snake = JsonSerializer.Deserialize<AsrParams>(json);
            if (snake is not null && snake.IsUsable) return snake;

            // Fall back to the macOS (camelCase) shape.
            var camel = JsonSerializer.Deserialize<AsrParamsCamelCase>(json);
            var converted = camel?.ToParams();
            if (converted is not null && converted.IsUsable)
            {
                Log.Info("Loaded params in macOS camelCase format");
                return converted;
            }

            Log.Warn("Params file present but incomplete");
            return null;
        }
        catch (Exception ex)
        {
            Log.Error("Failed to parse params", ex);
            return null;
        }
    }

    public static void Clear()
    {
        try
        {
            File.Delete(AppConfig.ParamsPath);
            Log.Info("Cleared saved params");
        }
        catch (Exception ex)
        {
            Log.Error("Failed to clear params", ex);
        }
    }

    public static bool HasSaved() => File.Exists(AppConfig.ParamsPath);
}
