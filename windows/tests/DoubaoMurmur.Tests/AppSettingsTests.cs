using DoubaoMurmur.Core;
using Xunit;

namespace DoubaoMurmur.Tests;

public class AppSettingsTests
{
    [Fact]
    public void Defaults_MatchTheOtherPlatforms()
    {
        var settings = new AppSettings();
        Assert.Equal(ToggleKey.RightAlt, settings.ToggleKey);
        // Suppression breaks AltGr, so it must stay opt-in.
        Assert.False(settings.SuppressToggleKey);
        Assert.Equal(PasteMode.Clipboard, settings.PasteMode);
    }

    [Fact]
    public void SaveThenLoad_RoundTrips()
    {
        using var temp = new TempConfigDir();

        new AppSettings
        {
            ToggleKey = ToggleKey.ScrollLock,
            SuppressToggleKey = true,
            PasteMode = PasteMode.Typing,
        }.Save();

        var loaded = AppSettings.Load();
        Assert.Equal(ToggleKey.ScrollLock, loaded.ToggleKey);
        Assert.True(loaded.SuppressToggleKey);
        Assert.Equal(PasteMode.Typing, loaded.PasteMode);
    }

    [Fact]
    public void Load_FallsBackToDefaultsOnCorruptFile()
    {
        using var temp = new TempConfigDir();
        File.WriteAllText(AppConfig.SettingsPath, "{ not json");

        var loaded = AppSettings.Load();
        Assert.Equal(ToggleKey.RightAlt, loaded.ToggleKey);
    }
}
