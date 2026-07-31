namespace DoubaoMurmur.Core;

public sealed record UpdateInfo(string Version, string Tag, string ReleaseUrl);

/// <summary>
/// Checks GitHub for a newer release. Mirrors UpdateChecker.swift: request
/// /releases/latest without following the redirect and read the tag out of the
/// Location header, which avoids needing the API (and its rate limit).
/// </summary>
public static class UpdateChecker
{
    private static readonly string LatestUrl =
        $"https://github.com/{AppConfig.GitHubRepo}/releases/latest";

    public static async Task<UpdateInfo?> CheckAsync(string currentVersion, CancellationToken ct = default)
    {
        using var handler = new HttpClientHandler { AllowAutoRedirect = false };
        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };

        using var response = await http.GetAsync(LatestUrl, ct).ConfigureAwait(false);
        var status = (int)response.StatusCode;
        if (status is < 300 or > 399) return null;

        var location = response.Headers.Location?.ToString();
        if (string.IsNullOrEmpty(location)) return null;

        var tag = location.TrimEnd('/').Split('/').LastOrDefault();
        if (string.IsNullOrEmpty(tag)) return null;

        var remote = tag.StartsWith('v') ? tag[1..] : tag;
        return IsNewer(remote, currentVersion)
            ? new UpdateInfo(remote, tag, location)
            : null;
    }

    /// <summary>Numeric dotted-version comparison. Exposed for tests.</summary>
    public static bool IsNewer(string remote, string current)
    {
        var left = Parse(remote);
        var right = Parse(current);
        var length = Math.Max(left.Length, right.Length);

        for (var i = 0; i < length; i++)
        {
            var a = i < left.Length ? left[i] : 0;
            var b = i < right.Length ? right[i] : 0;
            if (a != b) return a > b;
        }
        return false;
    }

    private static int[] Parse(string version) =>
        version.Split('.')
            .Select(part =>
            {
                var digits = new string(part.TakeWhile(char.IsDigit).ToArray());
                return int.TryParse(digits, out var value) ? value : 0;
            })
            .ToArray();
}
