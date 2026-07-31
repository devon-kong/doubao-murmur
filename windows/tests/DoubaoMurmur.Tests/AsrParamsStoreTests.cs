using DoubaoMurmur.Core;
using Xunit;

namespace DoubaoMurmur.Tests;

public class AsrParamsStoreTests
{
    [Fact]
    public void SaveThenLoad_RoundTrips()
    {
        using var temp = new TempConfigDir();

        var original = new AsrParams
        {
            Cookies = new Dictionary<string, string> { ["sessionid"] = "s", ["ttwid"] = "t" },
            DeviceId = "device-1",
            WebId = "web-1",
        };

        AsrParamsStore.Save(original);
        Assert.True(AsrParamsStore.HasSaved());

        var loaded = AsrParamsStore.Load();
        Assert.NotNull(loaded);
        Assert.Equal(original.DeviceId, loaded!.DeviceId);
        Assert.Equal(original.WebId, loaded.WebId);
        Assert.Equal(2, loaded.Cookies.Count);
        Assert.Equal("s", loaded.Cookies["sessionid"]);
    }

    [Fact]
    public void Load_ReturnsNullWhenNothingSaved()
    {
        using var temp = new TempConfigDir();
        Assert.False(AsrParamsStore.HasSaved());
        Assert.Null(AsrParamsStore.Load());
    }

    [Fact]
    public void Clear_RemovesTheFile()
    {
        using var temp = new TempConfigDir();

        AsrParamsStore.Save(new AsrParams
        {
            Cookies = new Dictionary<string, string> { ["a"] = "b" },
            DeviceId = "d",
            WebId = "w",
        });

        AsrParamsStore.Clear();
        Assert.False(AsrParamsStore.HasSaved());
    }

    [Fact]
    public void Load_AcceptsTheMacOsCamelCaseFormat()
    {
        using var temp = new TempConfigDir();

        // Swift's default Codable keys, so credentials copied from a Mac still work.
        File.WriteAllText(AppConfig.ParamsPath, """
            {
              "cookies": { "sessionid": "s" },
              "deviceId": "device-2",
              "webId": "web-2"
            }
            """);

        var loaded = AsrParamsStore.Load();
        Assert.NotNull(loaded);
        Assert.Equal("device-2", loaded!.DeviceId);
        Assert.Equal("web-2", loaded.WebId);
    }

    [Fact]
    public void Load_RejectsIncompleteCredentials()
    {
        using var temp = new TempConfigDir();
        File.WriteAllText(AppConfig.ParamsPath, """{ "cookies": {}, "device_id": "", "web_id": "" }""");
        Assert.Null(AsrParamsStore.Load());
    }
}
