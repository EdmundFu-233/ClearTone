using ClearTone.Core.Models;

namespace ClearTone.Tests;

public record SearchCall(string Query, SearchType Type, int Page);

public sealed class StubMusicProvider : IMusicProvider
{
    private readonly object _gate = new();
    private readonly List<SearchCall> _searchCalls = new();
    private readonly List<string> _lyricRequests = new();

    public string Identifier { get; set; } = "stub";
    public string DisplayName { get; set; } = "桩";

    public int SearchTotalPages { get; set; } = 1;

    public Func<string, SearchType, int, int, CancellationToken, Task<SearchResult>>? SearchHandler { get; set; }
    public Func<string, CancellationToken, Task<LyricResult>>? LyricsHandler { get; set; }
    public Func<CancellationToken, Task<AccountInfo?>>? AccountInfoHandler { get; set; }
    public Func<CancellationToken, Task<List<Playlist>>>? UserPlaylistsHandler { get; set; }
    public Func<CancellationToken, Task<List<Song>>>? LikedSongsHandler { get; set; }
    public Func<CancellationToken, Task<List<string>>>? LikedSongIDsHandler { get; set; }
    public Func<string, bool, CancellationToken, Task>? LikeSongHandler { get; set; }
    public Func<CancellationToken, Task>? LogoutHandler { get; set; }

    public IReadOnlyList<SearchCall> SearchCalls
    {
        get { lock (_gate) return _searchCalls.ToList(); }
    }

    public IReadOnlyList<string> LyricRequests
    {
        get { lock (_gate) return _lyricRequests.ToList(); }
    }

    public static SearchResult Page(string query, SearchType type, int page, bool hasMore)
    {
        var result = new SearchResult { TotalCount = 100, HasMore = hasMore };
        switch (type)
        {
            case SearchType.Song:
                result.Songs.Add(new Song
                {
                    Id = $"{query}-p{page}",
                    Title = $"{query} 第{page}页",
                    Artists = { new Artist { Id = "a1", Name = "Artist" } },
                    Source = SongSource.Netease,
                });
                break;
            case SearchType.Artist:
                result.Artists.Add(new Artist { Id = $"{query}-p{page}", Name = $"{query} 歌手{page}" });
                break;
            case SearchType.Album:
                result.Albums.Add(new Album { Id = $"{query}-p{page}", Name = $"{query} 专辑{page}" });
                break;
            default:
                result.Playlists.Add(new Playlist { Id = $"{query}-p{page}", Name = $"{query} 歌单{page}", Source = SongSource.Netease });
                break;
        }
        return result;
    }

    public async Task<SearchResult> SearchAsync(string query, SearchType type, int page, int limit, CancellationToken ct = default)
    {
        lock (_gate) _searchCalls.Add(new SearchCall(query, type, page));
        if (SearchHandler is { } handler) return await handler(query, type, page, limit, ct).ConfigureAwait(false);
        return Page(query, type, page, page < SearchTotalPages);
    }

    public async Task<LyricResult> FetchLyricsAsync(string songID, CancellationToken ct = default)
    {
        lock (_gate) _lyricRequests.Add(songID);
        if (LyricsHandler is { } handler) return await handler(songID, ct).ConfigureAwait(false);
        throw new NotSupportedException("FetchLyricsAsync");
    }

    public Task<string> FetchQRCodeKeyAsync(CancellationToken ct = default) => throw new NotSupportedException("FetchQRCodeKeyAsync");

    public Task<string> FetchQRCodeImageAsync(string key, CancellationToken ct = default) => throw new NotSupportedException("FetchQRCodeImageAsync");

    public Task<QRLoginStatus> CheckQRCodeStatusAsync(string key, CancellationToken ct = default) => throw new NotSupportedException("CheckQRCodeStatusAsync");

    public Task LogoutAsync(CancellationToken ct = default) => LogoutHandler?.Invoke(ct) ?? Task.CompletedTask;

    public Task<AccountInfo?> FetchAccountInfoAsync(CancellationToken ct = default) =>
        AccountInfoHandler?.Invoke(ct) ?? Task.FromResult<AccountInfo?>(null);

    public Task<PlaylistDetail> FetchPlaylistDetailAsync(string id, CancellationToken ct = default) => throw new NotSupportedException("FetchPlaylistDetailAsync");

    public Task<List<Song>> FetchPlaylistTracksAsync(string id, int page, int limit, CancellationToken ct = default) => throw new NotSupportedException("FetchPlaylistTracksAsync");

    public Task<PlaylistDetail> FetchAlbumDetailAsync(string id, CancellationToken ct = default) => throw new NotSupportedException("FetchAlbumDetailAsync");

    public Task<ArtistDetail> FetchArtistDetailAsync(string id, CancellationToken ct = default) => throw new NotSupportedException("FetchArtistDetailAsync");

    public Task<PlayableURL> FetchPlayableURLAsync(string songID, QualityLevel quality, CancellationToken ct = default) => throw new NotSupportedException("FetchPlayableURLAsync");

    public Task<List<Playlist>> FetchUserPlaylistsAsync(CancellationToken ct = default) =>
        UserPlaylistsHandler?.Invoke(ct) ?? Task.FromResult(new List<Playlist>());

    public Task<List<Song>> FetchLikedSongsAsync(CancellationToken ct = default) =>
        LikedSongsHandler?.Invoke(ct) ?? Task.FromResult(new List<Song>());

    public Task LikeSongAsync(string id, bool like, CancellationToken ct = default) =>
        LikeSongHandler?.Invoke(id, like, ct) ?? Task.CompletedTask;

    public Task<List<Playlist>> FetchRecommendPlaylistsAsync(CancellationToken ct = default) => Task.FromResult(new List<Playlist>());

    public Task<List<Song>> FetchDailyRecommendSongsAsync(CancellationToken ct = default) => Task.FromResult(new List<Song>());

    public Task<List<string>> FetchLikedSongIDsAsync(CancellationToken ct = default) =>
        LikedSongIDsHandler?.Invoke(ct) ?? Task.FromResult(new List<string>());
}
