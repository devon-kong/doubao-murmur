using DoubaoMurmur.Core;
using Xunit;

namespace DoubaoMurmur.Tests;

public class AsrClientTests
{
    private static AsrParams SampleParams() => new()
    {
        Cookies = new Dictionary<string, string> { ["sessionid"] = "abc", ["ttwid"] = "xyz" },
        DeviceId = "1234567890",
        WebId = "9876543210",
    };

    private static Dictionary<string, string> QueryOf(string url)
    {
        var query = new Uri(url).Query.TrimStart('?');
        return query
            .Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(pair => pair.Split('=', 2))
            .ToDictionary(
                parts => Uri.UnescapeDataString(parts[0]),
                parts => parts.Length > 1 ? Uri.UnescapeDataString(parts[1]) : string.Empty);
    }

    [Fact]
    public void BuildUrl_UsesTheDoubaoEndpoint()
    {
        var url = DoubaoAsrClient.BuildUrl(SampleParams(), "tab-1");
        Assert.StartsWith(AppConfig.WssBaseUrl + "?", url, StringComparison.Ordinal);
    }

    [Fact]
    public void BuildUrl_IncludesEveryFixedParameter()
    {
        var query = QueryOf(DoubaoAsrClient.BuildUrl(SampleParams(), "tab-1"));

        foreach (var (key, value) in AppConfig.FixedQueryParams)
        {
            Assert.Equal(value, query[key]);
        }
    }

    [Fact]
    public void BuildUrl_WiresIdentifiersFromParams()
    {
        var parameters = SampleParams();
        var query = QueryOf(DoubaoAsrClient.BuildUrl(parameters, "tab-1"));

        Assert.Equal(parameters.DeviceId, query["device_id"]);
        Assert.Equal(parameters.WebId, query["web_id"]);
        // tea_uuid intentionally mirrors web_id, matching the macOS client.
        Assert.Equal(parameters.WebId, query["tea_uuid"]);
        Assert.Equal("tab-1", query["web_tab_id"]);
    }

    [Fact]
    public void CookieHeader_JoinsPairsWithSemicolons()
    {
        var header = SampleParams().CookieHeader;
        Assert.Contains("sessionid=abc", header, StringComparison.Ordinal);
        Assert.Contains("ttwid=xyz", header, StringComparison.Ordinal);
        Assert.Contains("; ", header, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(709599054, "")]
    [InlineData(1, "Cookie is invalid")]
    [InlineData(2, "AUTH failed")]
    [InlineData(3, "session expired")]
    [InlineData(4, "unauthorized")]
    public void IsAuthError_DetectsCredentialFailures(long code, string message)
    {
        Assert.True(DoubaoAsrClient.IsAuthError(code, message));
    }

    [Theory]
    [InlineData(500, "internal server error")]
    [InlineData(42, "rate limited")]
    public void IsAuthError_IgnoresUnrelatedFailures(long code, string message)
    {
        Assert.False(DoubaoAsrClient.IsAuthError(code, message));
    }
}
