using System.Text.Json.Serialization;

namespace DoubaoMurmur.Core;

/// <summary>
/// Credentials needed to open a WSS ASR connection.
/// Serialised with the same snake_case keys the Linux port uses, so an
/// asr_params.json can be moved between the two installs.
/// </summary>
public sealed class AsrParams
{
    [JsonPropertyName("cookies")]
    public Dictionary<string, string> Cookies { get; set; } = new();

    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = string.Empty;

    [JsonPropertyName("web_id")]
    public string WebId { get; set; } = string.Empty;

    /// <summary>The Cookie request header for HTTP/WSS requests.</summary>
    [JsonIgnore]
    public string CookieHeader => string.Join("; ", Cookies.Select(kv => $"{kv.Key}={kv.Value}"));

    [JsonIgnore]
    public bool IsUsable => Cookies.Count > 0 && DeviceId.Length > 0 && WebId.Length > 0;
}

/// <summary>
/// The macOS build persists the same struct through Swift's default Codable keys
/// (camelCase). Accepting that shape too lets a user copy credentials over from a
/// Mac install instead of logging in again.
/// </summary>
internal sealed class AsrParamsCamelCase
{
    [JsonPropertyName("cookies")]
    public Dictionary<string, string> Cookies { get; set; } = new();

    [JsonPropertyName("deviceId")]
    public string DeviceId { get; set; } = string.Empty;

    [JsonPropertyName("webId")]
    public string WebId { get; set; } = string.Empty;

    public AsrParams ToParams() => new()
    {
        Cookies = Cookies,
        DeviceId = DeviceId,
        WebId = WebId,
    };
}
