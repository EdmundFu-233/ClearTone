namespace ClearTone.Core.Models;

public record TopList
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string? CoverURL { get; set; }
    public string? UpdateFrequency { get; set; }
    public int TrackCount { get; set; }
    public int PlayCount { get; set; }
    public string? DescriptionText { get; set; }
    public string? IconURL { get; set; }
}

public enum TopSongArea
{
    All,
    Chinese,
    Western,
    Japan,
    Korea,
}

public static class TopSongAreaExtensions
{
    public static string DisplayName(this TopSongArea area) => area switch
    {
        TopSongArea.All => "全部",
        TopSongArea.Chinese => "华语",
        TopSongArea.Western => "欧美",
        TopSongArea.Japan => "日本",
        _ => "韩国",
    };

    public static int AreaID(this TopSongArea area) => area switch
    {
        TopSongArea.All => 0,
        TopSongArea.Chinese => 7,
        TopSongArea.Western => 96,
        TopSongArea.Japan => 8,
        _ => 16,
    };
}

public enum TopPlaylistOrder
{
    Hot,
    New,
}

public static class TopPlaylistOrderExtensions
{
    public static string DisplayName(this TopPlaylistOrder order) =>
        order == TopPlaylistOrder.Hot ? "最热" : "最新";

    public static string ApiValue(this TopPlaylistOrder order) =>
        order == TopPlaylistOrder.Hot ? "hot" : "new";
}

public record PlaylistCategoryGroup
{
    public string Name { get; set; } = "";
    public List<string> Categories { get; set; } = new();
}

public record SearchSuggestion
{
    public enum Kind
    {
        Song,
        Artist,
        Album,
        Playlist,
    }

    public Kind SuggestionKind { get; set; } = Kind.Song;
    public string Title { get; set; } = "";
    public string? Subtitle { get; set; }
    public string? CoverURL { get; set; }
    public string TargetID { get; set; } = "";

    public string Id => $"{SuggestionKind.ToString().ToLowerInvariant()}-{TargetID}";
}

public record HotSearchTerm
{
    public string Keyword { get; set; } = "";
    public int Score { get; set; }
    public string? DisplayPrefix { get; set; }
    public string? Icon { get; set; }

    public string Id => Keyword;
}

public record UserLevelInfo
{
    public int Level { get; set; }
    public int ListenSongs { get; set; }
    public int ListenDays { get; set; }
    public int CurrentLoginDays { get; set; }
    public int NextLevelNeedLoginDays { get; set; }
    public int NextLevelNeedListenSongs { get; set; }
    public int CurrentProgress { get; set; }

    public int RemainingLoginDays => Math.Max(0, NextLevelNeedLoginDays);

    public double ProgressFraction =>
        NextLevelNeedLoginDays > 0
            ? Math.Min(1, Math.Max(0, (double)CurrentLoginDays / NextLevelNeedLoginDays))
            : 0;
}

public record ListenRecord
{
    public Song Song { get; set; } = new();
    public int PlayCount { get; set; }
    public DateTimeOffset? LastPlayedAt { get; set; }

    public string Id => Song.Id;
}

public abstract record SignInResult
{
    public sealed record Success(int Point) : SignInResult;
    public sealed record AlreadySigned : SignInResult;
    public sealed record Failed(string Reason) : SignInResult;

    public bool IsSuccess => this is Success;
}

public abstract record SubscribeTarget
{
    public sealed record PlaylistTarget(string Value) : SubscribeTarget;
    public sealed record AlbumTarget(string Value) : SubscribeTarget;
    public sealed record ArtistTarget(string Value) : SubscribeTarget;
    public sealed record RadioTarget(string Value) : SubscribeTarget;

    public string Id => this switch
    {
        PlaylistTarget p => p.Value,
        AlbumTarget a => a.Value,
        ArtistTarget a => a.Value,
        RadioTarget r => r.Value,
        _ => "",
    };

    public string DisplayName => this switch
    {
        PlaylistTarget => "歌单",
        AlbumTarget => "专辑",
        ArtistTarget => "歌手",
        _ => "电台",
    };

    public string? CountKey => this switch
    {
        PlaylistTarget => "收藏歌单",
        AlbumTarget => null,
        ArtistTarget => "关注歌手",
        _ => "收藏电台",
    };
}
