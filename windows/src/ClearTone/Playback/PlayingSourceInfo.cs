using ClearTone.Core.Models;

namespace ClearTone.Playback;

public abstract record CacheHint
{
    public sealed record None : CacheHint;

    public sealed record Caching : CacheHint;

    public sealed record Cached(string Format, int BitrateKbps) : CacheHint;

    public bool IsPresent => this is not None;
}

public sealed record PlayingSourceInfo(
    string Text,
    string ShortText,
    bool IsFromCache,
    CacheHint Cache,
    string Detail);

public static class PlayingSourceFormatter
{
    public static PlayingSourceInfo? Describe(
        AudioQuality? actualQuality,
        QualityLevel requestedLevel,
        bool isFromCache,
        string? cacheFormat = null,
        int? cacheBitrateKbps = null,
        bool isCaching = false)
    {
        CacheHint cache;
        if (cacheFormat is not null && cacheBitrateKbps is > 0)
        {
            cache = new CacheHint.Cached(cacheFormat, cacheBitrateKbps.Value);
        }
        else if (isCaching)
        {
            cache = new CacheHint.Caching();
        }
        else
        {
            cache = new CacheHint.None();
        }

        if (isFromCache && cache is CacheHint.Cached cached)
        {
            var cachedText = $"{cached.Format} {cached.BitrateKbps}k";
            return new PlayingSourceInfo(
                cachedText,
                cachedText,
                true,
                cache,
                $"正在播放本地缓存：{cached.Format} {cached.BitrateKbps}kbps\n本地缓存优先于在线流");
        }

        if (actualQuality is null) return null;
        var level = actualQuality.Level;
        var bitrate = actualQuality.Bitrate;
        var text = PrimaryText(level, bitrate, actualQuality.Codec);
        if (text is null) return null;

        var actualLine = bitrate is { } rate ? $"{level.DisplayName()} {rate}kbps" : level.DisplayName();
        var codecLine = actualQuality.Codec is { } codec ? $"\n编码：{codec}" : "";
        var cacheLine = cache switch
        {
            CacheHint.Caching => "本地缓存：正在写入（本次播放仍为在线流）",
            CacheHint.Cached cachedHint => $"本地缓存：{cachedHint.Format} {cachedHint.BitrateKbps}kbps（下次播放优先使用）",
            _ => "本地缓存：无",
        };
        return new PlayingSourceInfo(
            text,
            bitrate is { } shortRate ? $"{shortRate}k" : text,
            false,
            cache,
            $"请求音质：{requestedLevel.DisplayName()}\n实际返回：{actualLine}{codecLine}{cacheLine}");
    }

    private static string? PrimaryText(QualityLevel level, int? bitrate, string? codec)
    {
        var cleanCodec = codec?.Trim().ToUpperInvariant();
        var hasCodec = !string.IsNullOrEmpty(cleanCodec);
        var rate = bitrate is > 0 ? $"{bitrate.Value}k" : null;
        if (hasCodec && rate is not null) return $"{cleanCodec} {rate}";
        if (hasCodec) return cleanCodec;
        if (rate is not null) return level == QualityLevel.Unknown ? rate : $"{level.DisplayName()} {rate}";
        if (level == QualityLevel.Unknown) return null;
        return level.DisplayName();
    }
}
