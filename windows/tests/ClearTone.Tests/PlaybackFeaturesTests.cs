using System.Text.Json;
using ClearTone.Core.Models;
using ClearTone.Core.Persistence;
using ClearTone.Playback;
using Xunit;

namespace ClearTone.Tests;

public class PlaybackFeaturesTests
{
    [Fact]
    public void TestRateClampsToSaneRange()
    {
        var player = PlayerController.Shared;
        var original = player.PlaybackRate;
        try
        {
            player.SetPlaybackRate(1.5f);
            Assert.Equal(1.5, (double)player.PlaybackRate, 3);

            player.SetPlaybackRate(99f);
            Assert.Equal(3.0, (double)player.PlaybackRate, 3);
            player.SetPlaybackRate(0f);
            Assert.Equal(0.25, (double)player.PlaybackRate, 3);
            player.SetPlaybackRate(-5f);
            Assert.Equal(0.25, (double)player.PlaybackRate, 3);
        }
        finally
        {
            player.SetPlaybackRate(original);
        }
    }

    [Fact]
    public void TestNormalRateHasNoBadge()
    {
        var player = PlayerController.Shared;
        var original = player.PlaybackRate;
        try
        {
            player.SetPlaybackRate(1.0f);
            Assert.False(player.IsRateAdjusted);
            Assert.Equal("", player.PlaybackRateLabel);

            player.SetPlaybackRate(1.5f);
            Assert.True(player.IsRateAdjusted);
            Assert.False(string.IsNullOrEmpty(player.PlaybackRateLabel));
            Assert.Contains("1.5", player.PlaybackRateLabel);
        }
        finally
        {
            player.SetPlaybackRate(original);
        }
    }

    [Fact]
    public void TestRateLabelFormatting()
    {
        Assert.Equal("2×", PlayerController.RateLabel(2.0f));
        Assert.Equal("0.5×", PlayerController.RateLabel(0.5f));
    }

    [Fact]
    public void TestQuarterRatesAreNotRoundedAway()
    {
        var expected = new Dictionary<float, string>
        {
            [0.5f] = "0.5×",
            [0.75f] = "0.75×",
            [1.0f] = "1×",
            [1.25f] = "1.25×",
            [1.5f] = "1.5×",
            [1.75f] = "1.75×",
            [2.0f] = "2×",
        };
        Assert.Equal(new HashSet<float>(expected.Keys), new HashSet<float>(PlayerController.AvailableRates));
        foreach (var rate in PlayerController.AvailableRates)
        {
            Assert.Equal(expected[rate], PlayerController.RateLabel(rate));
        }
    }

    [Fact]
    public void TestAvailableRatesAreOrderedAndCentred()
    {
        var rates = PlayerController.AvailableRates;
        Assert.Equal(rates.OrderBy(rate => rate).ToArray(), rates.ToArray());
        Assert.Contains(1.0f, rates);
        Assert.True(rates.First() >= 0.25f);
        Assert.True(rates.Last() <= 3.0f);
    }

    [Fact]
    public void TestRestoredPlaybackRateSnapsToAvailableRate()
    {
        foreach (var rate in PlayerController.AvailableRates)
        {
            Assert.Equal(rate, PlayerController.ResolveRestoredPlaybackRate(rate));
        }
        Assert.Equal(2.0f, PlayerController.ResolveRestoredPlaybackRate(99f));
        Assert.Equal(0.5f, PlayerController.ResolveRestoredPlaybackRate(0f));
        Assert.Equal(0.5f, PlayerController.ResolveRestoredPlaybackRate(-5f));
        Assert.Equal(1.0f, PlayerController.ResolveRestoredPlaybackRate(1.1f));
        Assert.Equal(2.0f, PlayerController.ResolveRestoredPlaybackRate(1.9f));
    }

    [Fact]
    public void TestSleepTimerSetsAndCancels()
    {
        var player = PlayerController.Shared;
        player.CancelSleepTimer();
        Assert.Null(player.SleepTimerEndDate);

        player.SetSleepTimer(15);
        Assert.NotNull(player.SleepTimerEndDate);
        Assert.InRange(player.SleepTimerRemaining, 899.0, 901.0);
        Assert.True(player.SleepTimerEndDate > DateTimeOffset.Now);

        player.CancelSleepTimer();
        Assert.Null(player.SleepTimerEndDate);
        Assert.Equal(0, player.SleepTimerRemaining, 3);
    }

    [Fact]
    public void TestNonPositiveSleepTimerCancels()
    {
        var player = PlayerController.Shared;
        player.SetSleepTimer(30);
        player.SetSleepTimer(0);
        Assert.Null(player.SleepTimerEndDate);

        player.SetSleepTimer(30);
        player.SetSleepTimer(-5);
        Assert.Null(player.SleepTimerEndDate);
    }

    [Fact]
    public void TestSleepTimerReplacesPrevious()
    {
        var player = PlayerController.Shared;
        player.SetSleepTimer(60);
        var first = player.SleepTimerEndDate;
        player.SetSleepTimer(10);
        var second = player.SleepTimerEndDate;
        Assert.NotNull(second);
        Assert.True(second < first);
        player.CancelSleepTimer();
    }

    [Fact]
    public void TestSpectrumModeDoesNotOfferRealSpectrum()
    {
        var modes = Enum.GetValues<SpectrumMode>();
        Assert.Equal(2, modes.Length);
        Assert.Contains(SpectrumMode.Ambient, modes);
        Assert.Contains(SpectrumMode.Off, modes);
        Assert.DoesNotContain(modes, mode => mode.ToString() == "Real");
    }

    [Fact]
    public void TestSpectrumDefaultIsAmbient()
    {
        Assert.Equal(SpectrumMode.Ambient, new AppSettings().SpectrumMode);
    }

    [Fact]
    public void TestLegacySpectrumValueDoesNotBreakSettingsDecoding()
    {
        const string legacy = "{\"themeMode\":\"dark\",\"spectrumMode\":\"真实频谱\",\"lyricOffset\":1.5,\"preferredQuality\":\"无损\",\"audioCacheEnabled\":false}";
        var decoded = JsonSerializer.Deserialize<AppSettings>(legacy, JsonDefaults.Options);
        Assert.NotNull(decoded);
        Assert.Equal(SpectrumMode.Ambient, decoded!.SpectrumMode);
        Assert.Equal(CTThemeMode.Dark, decoded.ThemeMode);
        Assert.Equal(QualityLevel.Lossless, decoded.PreferredQuality);
        Assert.False(decoded.AudioCacheEnabled);
        Assert.Equal(1.5, decoded.LyricOffset, 4);
    }

    [Fact]
    public void TestUnrecognizedFieldDoesNotResetTheRest()
    {
        const string broken = "{\"themeMode\":\"chartreuse\",\"closeBehavior\":\"fly-to-the-moon\",\"performanceMode\":\"turbo\",\"spectrumMode\":42,\"lyricOffset\":\"soon\",\"preferredQuality\":\"无损\",\"audioCacheEnabled\":false,\"miniPlayerAlwaysOnTop\":false}";
        var decoded = JsonSerializer.Deserialize<AppSettings>(broken, JsonDefaults.Options);
        Assert.NotNull(decoded);
        Assert.Equal(CTThemeMode.System, decoded!.ThemeMode);
        Assert.Equal(CloseBehavior.KeepPlaying, decoded.CloseBehavior);
        Assert.Equal(PerformanceMode.Auto, decoded.PerformanceMode);
        Assert.Equal(SpectrumMode.Ambient, decoded.SpectrumMode);
        Assert.Equal(0, decoded.LyricOffset, 4);
        Assert.Equal(QualityLevel.Lossless, decoded.PreferredQuality);
        Assert.False(decoded.AudioCacheEnabled);
        Assert.False(decoded.MiniPlayerAlwaysOnTop);
    }

    [Fact]
    public void TestEmptyObjectDecodesToDefaults()
    {
        var decoded = JsonSerializer.Deserialize<AppSettings>("{}", JsonDefaults.Options);
        Assert.NotNull(decoded);
        Assert.Equal(CloseBehavior.KeepPlaying, decoded!.CloseBehavior);
        Assert.False(decoded.MenuBarAlwaysVisible);
        Assert.True(decoded.MiniPlayerAlwaysOnTop);
        Assert.True(decoded.AudioCacheEnabled);
        Assert.Equal(SongQualityPolicy.AutoLevel, decoded.PreferredQuality);
    }

    [Fact]
    public void TestStoredQualityValueIsNotOverwrittenByNewDefault()
    {
        var decoded = JsonSerializer.Deserialize<AppSettings>("{\"preferredQuality\":\"极高\"}", JsonDefaults.Options);
        Assert.NotNull(decoded);
        Assert.Equal(QualityLevel.ExHigh, decoded!.PreferredQuality);
    }

    [Fact]
    public void TestSettingsRoundTripKeepsMenuBarFlag()
    {
        var settings = new AppSettings
        {
            MenuBarAlwaysVisible = true,
            CloseBehavior = CloseBehavior.MinimizeToMenuBar,
            MiniPlayerAlwaysOnTop = false,
        };
        var data = JsonSerializer.SerializeToUtf8Bytes(settings, JsonDefaults.Options);
        var decoded = JsonSerializer.Deserialize<AppSettings>(data, JsonDefaults.Options);
        Assert.NotNull(decoded);
        Assert.True(decoded!.MenuBarAlwaysVisible);
        Assert.Equal(CloseBehavior.MinimizeToMenuBar, decoded.CloseBehavior);
        Assert.False(decoded.MiniPlayerAlwaysOnTop);
    }

    [Fact]
    public void TestCloseBehaviorDefaultKeepsPlaying()
    {
        Assert.Equal(CloseBehavior.KeepPlaying, new AppSettings().CloseBehavior);
        Assert.False(new AppSettings().MenuBarAlwaysVisible);
    }

    [Fact]
    public void TestEveryCloseBehaviorHasHelp()
    {
        foreach (var behavior in Enum.GetValues<CloseBehavior>())
        {
            Assert.False(string.IsNullOrEmpty(behavior.Help()));
            Assert.False(string.IsNullOrEmpty(behavior.DisplayName()));
        }
        Assert.Equal(3, Enum.GetValues<CloseBehavior>().Length);
    }

    [Fact(Skip = "Windows source has no PlaybackUtilitiesMenu.remainingLabel equivalent")]
    public void TestSleepRemainingLabel()
    {
    }

    [Fact(Skip = "Windows source has no MenuBarVisibilityPolicy equivalent")]
    public void TestMenuBarAlwaysVisibleWinsOverEveryCloseBehavior()
    {
    }

    [Fact(Skip = "Windows source has no MenuBarVisibilityPolicy equivalent")]
    public void TestMinimizeToMenuBarShowsIconOnlyWithoutWindow()
    {
    }

    [Fact(Skip = "Windows source has no MenuBarVisibilityPolicy equivalent")]
    public void TestNoIconForKeepPlayingOrQuit()
    {
    }
}
