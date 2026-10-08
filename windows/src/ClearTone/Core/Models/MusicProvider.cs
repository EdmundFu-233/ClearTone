namespace ClearTone.Core.Models;

public interface IMusicProvider
{
    string Identifier { get; }
    string DisplayName { get; }

    Task<string> FetchQRCodeKeyAsync(CancellationToken ct = default);
    Task<string> FetchQRCodeImageAsync(string key, CancellationToken ct = default);
    Task<QRLoginStatus> CheckQRCodeStatusAsync(string key, CancellationToken ct = default);
    Task LogoutAsync(CancellationToken ct = default);
    Task<AccountInfo?> FetchAccountInfoAsync(CancellationToken ct = default);

    Task<SearchResult> SearchAsync(string query, SearchType type, int page, int limit, CancellationToken ct = default);
    Task<PlaylistDetail> FetchPlaylistDetailAsync(string id, CancellationToken ct = default);
    Task<List<Song>> FetchPlaylistTracksAsync(string id, int page, int limit, CancellationToken ct = default);
    Task<PlaylistDetail> FetchAlbumDetailAsync(string id, CancellationToken ct = default);
    Task<ArtistDetail> FetchArtistDetailAsync(string id, CancellationToken ct = default);
    Task<PlayableURL> FetchPlayableURLAsync(string songID, QualityLevel quality, CancellationToken ct = default);
    Task<LyricResult> FetchLyricsAsync(string songID, CancellationToken ct = default);
    Task<List<Playlist>> FetchUserPlaylistsAsync(CancellationToken ct = default);
    Task<List<Song>> FetchLikedSongsAsync(CancellationToken ct = default);
    Task LikeSongAsync(string id, bool like, CancellationToken ct = default);
    Task<List<Playlist>> FetchRecommendPlaylistsAsync(CancellationToken ct = default);
    Task<List<Song>> FetchDailyRecommendSongsAsync(CancellationToken ct = default);
    Task<List<string>> FetchLikedSongIDsAsync(CancellationToken ct = default);
}

public abstract record QRLoginStatus
{
    public sealed record WaitingScan : QRLoginStatus;
    public sealed record ScannedWaitingConfirm : QRLoginStatus;
    public sealed record Success(string Cookie) : QRLoginStatus;
    public sealed record Expired : QRLoginStatus;
    public sealed record Failed(string Reason) : QRLoginStatus;
}

public record AccountInfo
{
    public string UserID { get; set; } = "";
    public string Nickname { get; set; } = "";
    public string? AvatarURL { get; set; }
    public bool IsVIP { get; set; }
}

public enum SearchType
{
    Song,
    Artist,
    Album,
    Playlist,
}

public static class SearchTypeExtensions
{
    public static string DisplayName(this SearchType type) => type switch
    {
        SearchType.Song => "单曲",
        SearchType.Artist => "歌手",
        SearchType.Album => "专辑",
        _ => "歌单",
    };

    public static SearchType[] All => new[] { SearchType.Song, SearchType.Artist, SearchType.Album, SearchType.Playlist };
}

public record SearchResult
{
    public List<Song> Songs { get; set; } = new();
    public List<Artist> Artists { get; set; } = new();
    public List<Album> Albums { get; set; } = new();
    public List<Playlist> Playlists { get; set; } = new();
    public int TotalCount { get; set; }
    public bool HasMore { get; set; }

    public bool IsEmpty => Songs.Count == 0 && Artists.Count == 0 && Albums.Count == 0 && Playlists.Count == 0;
}

public record PlaylistDetail
{
    public Playlist Playlist { get; set; } = new();
    public List<Song> Tracks { get; set; } = new();
    public int TotalTrackCount { get; set; }
    public string? ArtistID { get; set; }
}

public record ArtistDetail
{
    public Artist Artist { get; set; } = new();
    public List<Song> HotSongs { get; set; } = new();
    public List<Album> Albums { get; set; } = new();
}

public record LyricResult
{
    public List<LyricLine> Lines { get; set; } = new();
    public bool HasWordTiming { get; set; }
    public bool IsPureMusic { get; set; }
}
