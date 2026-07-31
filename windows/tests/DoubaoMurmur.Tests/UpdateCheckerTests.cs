using DoubaoMurmur.Core;
using Xunit;

namespace DoubaoMurmur.Tests;

public class UpdateCheckerTests
{
    [Theory]
    [InlineData("1.0.1", "1.0.0")]
    [InlineData("1.1.0", "1.0.9")]
    [InlineData("2.0.0", "1.9.9")]
    [InlineData("1.0.0.1", "1.0.0")]
    [InlineData("1.2", "1.1.9")]
    public void IsNewer_DetectsUpgrades(string remote, string current)
    {
        Assert.True(UpdateChecker.IsNewer(remote, current));
    }

    [Theory]
    [InlineData("1.0.0", "1.0.0")]
    [InlineData("1.0.0", "1.0.1")]
    [InlineData("1.0", "1.0.0")]
    [InlineData("0.9.9", "1.0.0")]
    public void IsNewer_RejectsSameOrOlder(string remote, string current)
    {
        Assert.False(UpdateChecker.IsNewer(remote, current));
    }

    [Fact]
    public void IsNewer_IgnoresNonNumericSuffixes()
    {
        Assert.True(UpdateChecker.IsNewer("1.2.0", "1.1.0-beta"));
    }
}
