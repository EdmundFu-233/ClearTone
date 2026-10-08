using System.Text.Json;
using ClearTone.Core.Models;
using ClearTone.Core.Persistence;
using ClearTone.Playback;
using Xunit;

namespace ClearTone.Tests;

public class AppSettingsToleranceTests
{
    [Fact]
    public void NonFiniteLyricOffsetKeepsOtherFields()
    {
        var settings = new AppSettings
        {
            LyricOffset = double.NaN,
            AudioCacheEnabled = false,
            PreferredQuality = QualityLevel.Lossless,
        };

        var json = JsonSerializer.Serialize(settings, JsonDefaults.Options);
        var restored = JsonSerializer.Deserialize<AppSettings>(json, JsonDefaults.Options)!;

        Assert.True(double.IsNaN(restored.LyricOffset));
        Assert.False(restored.AudioCacheEnabled);
        Assert.Equal(QualityLevel.Lossless, restored.PreferredQuality);
    }

    [Fact]
    public void MissingKeysFallBackToDefaults()
    {
        var restored = JsonSerializer.Deserialize<AppSettings>("{}", JsonDefaults.Options)!;
        Assert.Equal(SongQualityPolicy.AutoLevel, restored.PreferredQuality);
        Assert.True(restored.AudioCacheEnabled);
        Assert.Equal(CTThemeMode.System, restored.ThemeMode);
    }

    [Fact]
    public void ExplicitQualityIsNotOverriddenByNewDefaults()
    {
        var restored = JsonSerializer.Deserialize<AppSettings>(
            "{\"preferredQuality\":\"exHigh\"}", JsonDefaults.Options)!;
        Assert.Equal(QualityLevel.ExHigh, restored.PreferredQuality);
    }

    [Fact]
    public void LegacyChineseQualityValueStillLoads()
    {
        var restored = JsonSerializer.Deserialize<AppSettings>(
            "{\"preferredQuality\":\"无损\"}", JsonDefaults.Options)!;
        Assert.Equal(QualityLevel.Lossless, restored.PreferredQuality);
    }
}
