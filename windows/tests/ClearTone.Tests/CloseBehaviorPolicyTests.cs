using ClearTone.Core.Persistence;
using ClearTone.Shell;
using Xunit;

namespace ClearTone.Tests;

public class CloseBehaviorPolicyTests
{
    [Fact]
    public void QuitIsTheOnlyBehaviorThatQuitsOnClose()
    {
        foreach (var behavior in Enum.GetValues<CloseBehavior>())
        {
            var settings = new AppSettings { CloseBehavior = behavior };
            Assert.Equal(behavior == CloseBehavior.Quit, CloseBehaviorPolicy.ShouldQuitOnClose(settings));
        }
    }

    [Fact]
    public void MenuBarAlwaysVisibleWinsOverEveryBehaviorAndWindowState()
    {
        foreach (var behavior in Enum.GetValues<CloseBehavior>())
        {
            foreach (var visible in new[] { true, false })
            {
                var settings = new AppSettings
                {
                    CloseBehavior = behavior,
                    MenuBarAlwaysVisible = true,
                };
                Assert.True(CloseBehaviorPolicy.TrayIconShouldBeVisible(settings, visible));
            }
        }
    }

    [Fact]
    public void MinimizeToMenuBarShowsTrayOnlyWithoutVisibleWindows()
    {
        var settings = new AppSettings { CloseBehavior = CloseBehavior.MinimizeToMenuBar };
        Assert.False(CloseBehaviorPolicy.TrayIconShouldBeVisible(settings, true));
        Assert.True(CloseBehaviorPolicy.TrayIconShouldBeVisible(settings, false));
    }

    [Fact]
    public void KeepPlayingKeepsTrayAvailableWithoutVisibleWindows()
    {
        var settings = new AppSettings { CloseBehavior = CloseBehavior.KeepPlaying };
        Assert.False(CloseBehaviorPolicy.TrayIconShouldBeVisible(settings, true));
        Assert.True(CloseBehaviorPolicy.TrayIconShouldBeVisible(settings, false));
    }

    [Fact]
    public void QuitNeverShowsTrayWithoutAlwaysVisible()
    {
        var settings = new AppSettings { CloseBehavior = CloseBehavior.Quit };
        Assert.False(CloseBehaviorPolicy.TrayIconShouldBeVisible(settings, true));
        Assert.False(CloseBehaviorPolicy.TrayIconShouldBeVisible(settings, false));
    }
}
