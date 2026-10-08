using System.Text.Json.Serialization;

namespace ClearTone.Core.Models;

public enum SongSource
{
    Netease,
    Local,
}

public record Song
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public List<Artist> Artists { get; set; } = new();
    public Album? Album { get; set; }
    public double Duration { get; set; }
    public string? CoverURL { get; set; }
    public bool IsPlayable { get; set; } = true;
    public string? UnavailableReason { get; set; }
    public List<AudioQuality> Qualities { get; set; } = new();
    public SongSource Source { get; set; } = SongSource.Netease;
    public string? LocalFileURL { get; set; }

    [JsonIgnore]
    public string ArtistNames => string.Join(" / ", Artists.Select(a => a.Name));
}

public record Artist
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string? AvatarURL { get; set; }
    public List<string> Alias { get; set; } = new();

    [JsonIgnore]
    public string DisplayNameWithAlias
    {
        get
        {
            var first = Alias.FirstOrDefault(a => !string.IsNullOrEmpty(a) && a != Name);
            return first is null ? Name : $"{Name} · {first}";
        }
    }
}

public record Album
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string? CoverURL { get; set; }
}

public enum QualityLevel
{
    Standard,
    Higher,
    ExHigh,
    Lossless,
    HiRes,
    Unknown,
}

public static class QualityLevelExtensions
{
    public static string DisplayName(this QualityLevel level) => level switch
    {
        QualityLevel.Standard => "标准",
        QualityLevel.Higher => "较高",
        QualityLevel.ExHigh => "极高",
        QualityLevel.Lossless => "无损",
        QualityLevel.HiRes => "Hi-Res",
        _ => "未知",
    };

    public static string PersistedName(this QualityLevel level) => level.DisplayName();

    public static QualityLevel? FromPersistedName(string? raw) => raw switch
    {
        "标准" => QualityLevel.Standard,
        "较高" => QualityLevel.Higher,
        "极高" => QualityLevel.ExHigh,
        "无损" => QualityLevel.Lossless,
        "Hi-Res" => QualityLevel.HiRes,
        "未知" => QualityLevel.Unknown,
        _ => null,
    };

    public static QualityLevel FromAPIValue(string? raw) => raw switch
    {
        "standard" => QualityLevel.Standard,
        "higher" => QualityLevel.Higher,
        "exhigh" => QualityLevel.ExHigh,
        "lossless" => QualityLevel.Lossless,
        "hires" => QualityLevel.HiRes,
        _ => QualityLevel.Unknown,
    };
}

public record AudioQuality
{
    public QualityLevel Level { get; set; } = QualityLevel.Unknown;
    public int? Bitrate { get; set; }
    public int? SampleRate { get; set; }
    public int? BitDepth { get; set; }
    public bool IsActual { get; set; }
    public string? Codec { get; set; }
}

public record Playlist
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string? CoverURL { get; set; }
    public int TrackCount { get; set; }
    public string? CreatorName { get; set; }
    public string? DescriptionText { get; set; }
    public bool IsSubscribed { get; set; }
    public SongSource Source { get; set; } = SongSource.Netease;
}

public record PlayableURL
{
    public Uri Url { get; set; } = null!;
    public AudioQuality Quality { get; set; } = new();
    public DateTimeOffset? ExpiresAt { get; set; }
    public bool IsPreview { get; set; }
    public bool IsCached { get; set; }
    public long? SizeBytes { get; set; }
}

public record LyricWord
{
    public double Time { get; set; }
    public double Duration { get; set; }
    public string Text { get; set; } = "";
}

public record LyricLine
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public double Time { get; set; }
    public string Text { get; set; } = "";
    public string? Translation { get; set; }
    public string? Romanization { get; set; }
    public List<LyricWord>? Words { get; set; }
}
