using ClearTone.Core.Models;
using ClearTone.Playback;
using Xunit;

namespace ClearTone.Tests;

public class PlayingSourceFormatterTests
{
    private static PlayingSourceInfo? Describe(
        AudioQuality? quality,
        QualityLevel requested = QualityLevel.ExHigh,
        bool fromCache = false,
        string? cacheFormat = null,
        int? cacheBitrate = null,
        bool caching = false)
    {
        return PlayingSourceFormatter.Describe(quality, requested, fromCache, cacheFormat, cacheBitrate, caching);
    }

    [Fact]
    public void TestFreshSongShowsStreamBitrateNotCache()
    {
        var info = Describe(new AudioQuality { Level = QualityLevel.ExHigh, Bitrate = 320, IsActual = true, Codec = "mp3" });
        Assert.NotNull(info);
        Assert.Equal("MP3 320k", info!.Text);
        Assert.Equal("320k", info.ShortText);
        Assert.False(info.IsFromCache);
        Assert.IsType<CacheHint.None>(info.Cache);
    }

    [Fact]
    public void TestCachingDoesNotReplaceStreamBitrate()
    {
        var info = Describe(
            new AudioQuality { Level = QualityLevel.ExHigh, Bitrate = 320, IsActual = true, Codec = "MP3" },
            caching: true);
        Assert.NotNull(info);
        Assert.Equal("MP3 320k", info!.Text);
        Assert.IsType<CacheHint.Caching>(info.Cache);
        Assert.Contains("正在写入", info.Detail);
    }

    [Fact]
    public void TestCachedButStreamingOnlineKeepsStreamBitrate()
    {
        var info = Describe(
            new AudioQuality { Level = QualityLevel.Lossless, Bitrate = 1411, IsActual = true, Codec = "flac" },
            cacheFormat: "OPUS",
            cacheBitrate: 128);
        Assert.NotNull(info);
        Assert.Equal("FLAC 1411k", info!.Text);
        Assert.False(info.IsFromCache);
        var cached = Assert.IsType<CacheHint.Cached>(info.Cache);
        Assert.Equal("OPUS", cached.Format);
        Assert.Equal(128, cached.BitrateKbps);
        Assert.Contains("下次播放优先使用", info.Detail);
    }

    [Fact]
    public void TestPlayingFromCacheShowsCacheFormat()
    {
        var info = Describe(
            new AudioQuality { Level = QualityLevel.Unknown, Bitrate = 128, IsActual = true },
            fromCache: true,
            cacheFormat: "OPUS",
            cacheBitrate: 128);
        Assert.NotNull(info);
        Assert.Equal("OPUS 128k", info!.Text);
        Assert.Equal("OPUS 128k", info.ShortText);
        Assert.True(info.IsFromCache);
        Assert.Contains("正在播放本地缓存", info.Detail);
    }

    [Fact]
    public void TestFromCacheWithoutMetaFallsBackToOnlineInfo()
    {
        var info = Describe(
            new AudioQuality { Level = QualityLevel.ExHigh, Bitrate = 320, IsActual = true },
            fromCache: true);
        Assert.NotNull(info);
        Assert.Equal("极高 320k", info!.Text);
        Assert.False(info.IsFromCache);
    }

    [Fact]
    public void TestLevelWithoutBitrateShowsLevelOnly()
    {
        var info = Describe(new AudioQuality { Level = QualityLevel.Standard, IsActual = true });
        Assert.NotNull(info);
        Assert.Equal("标准", info!.Text);
        Assert.Equal("标准", info.ShortText);
    }

    [Fact]
    public void TestCodecWithoutBitrateShowsCodec()
    {
        var info = Describe(new AudioQuality { Level = QualityLevel.Unknown, IsActual = true, Codec = "flac" });
        Assert.NotNull(info);
        Assert.Equal("FLAC", info!.Text);
    }

    [Fact]
    public void TestCodecIsNormalized()
    {
        var info = Describe(new AudioQuality { Level = QualityLevel.ExHigh, Bitrate = 320, IsActual = true, Codec = " mp3 " });
        Assert.NotNull(info);
        Assert.Equal("MP3 320k", info!.Text);

        var blank = Describe(new AudioQuality { Level = QualityLevel.ExHigh, Bitrate = 320, IsActual = true, Codec = "  " });
        Assert.NotNull(blank);
        Assert.Equal("极高 320k", blank!.Text);
    }

    [Fact]
    public void TestUnknownQualityWithoutBitrateIsHidden()
    {
        Assert.Null(Describe(new AudioQuality { Level = QualityLevel.Unknown, IsActual = true }));
        Assert.Null(Describe(null));
    }

    [Fact]
    public void TestNonPositiveBitrateIsIgnored()
    {
        Assert.Null(Describe(new AudioQuality { Level = QualityLevel.Unknown, Bitrate = 0, IsActual = true }));
    }

    [Fact]
    public void TestDetailContainsRequestedAndActualQuality()
    {
        var info = Describe(
            new AudioQuality { Level = QualityLevel.Higher, Bitrate = 192, IsActual = true, Codec = "AAC" },
            requested: QualityLevel.ExHigh);
        Assert.NotNull(info);
        Assert.Contains("编码：AAC", info!.Detail);
        Assert.Contains("请求音质：极高", info.Detail);
        Assert.Contains("实际返回：较高 192kbps", info.Detail);
        Assert.Contains("本地缓存：无", info.Detail);
    }
}
