using ClearTone.Core.Comments;

namespace ClearTone.Core.Models;

public interface IMusicSocialProvider : ICommentProvider
{
    Task SubscribePlaylistAsync(string id, bool subscribe, CancellationToken ct = default);
    Task<Playlist> CreatePlaylistAsync(string name, bool isPrivate, CancellationToken ct = default);
    Task DeletePlaylistAsync(string id, CancellationToken ct = default);
    Task UpdatePlaylistNameAsync(string id, string name, CancellationToken ct = default);
    Task AddSongsToPlaylistAsync(string playlistID, IReadOnlyList<string> songIDs, CancellationToken ct = default);
    Task RemoveSongsFromPlaylistAsync(string playlistID, IReadOnlyList<string> songIDs, CancellationToken ct = default);

    Task SubscribeAlbumAsync(string id, bool subscribe, CancellationToken ct = default);
    Task SubscribeArtistAsync(string id, bool subscribe, CancellationToken ct = default);
    Task SubscribeRadioAsync(string id, bool subscribe, CancellationToken ct = default);

    Task<List<Playlist>> FetchSubscribedPlaylistsAsync(int limit = 50, CancellationToken ct = default);
    Task<List<Album>> FetchSubscribedAlbumsAsync(int limit = 50, CancellationToken ct = default);
    Task<List<Artist>> FetchSubscribedArtistsAsync(int limit = 50, CancellationToken ct = default);
    Task<List<RadioStation>> FetchSubscribedRadiosAsync(int limit = 30, CancellationToken ct = default);
    Task<RadioStation> FetchRadioStationDetailAsync(string radioID, CancellationToken ct = default);

    Task<List<TopList>> FetchTopListsAsync(CancellationToken ct = default);
    Task<List<Song>> FetchTopSongsAsync(TopSongArea area, CancellationToken ct = default);
    Task<List<Playlist>> FetchHotPlaylistsAsync(
        string? category,
        TopPlaylistOrder order,
        int limit,
        int offset,
        CancellationToken ct = default);
    Task<List<PlaylistCategoryGroup>> FetchPlaylistCategoriesAsync(CancellationToken ct = default);
    Task<List<string>> FetchHotPlaylistTagsAsync(CancellationToken ct = default);

    Task<List<Song>> FetchPersonalFMAsync(CancellationToken ct = default);
    Task<List<Playlist>> FetchDailyRecommendPlaylistsAsync(CancellationToken ct = default);
    Task<List<Song>> FetchNewSongsAsync(int limit = 30, CancellationToken ct = default);
    Task<List<Album>> FetchNewAlbumsAsync(int limit = 30, CancellationToken ct = default);
    Task<List<Song>> FetchSimilarSongsAsync(string songID, int limit = 30, CancellationToken ct = default);
    Task<List<Artist>> FetchSimilarArtistsAsync(string artistID, CancellationToken ct = default);
    Task<Song?> DislikeDailyRecommendAsync(string songID, CancellationToken ct = default);

    Task<List<SearchSuggestion>> FetchSearchSuggestionsAsync(string keyword, CancellationToken ct = default);
    Task<List<HotSearchTerm>> FetchHotSearchTermsAsync(CancellationToken ct = default);

    Task<List<UserNotice>> FetchNoticesAsync(int limit = 30, CancellationToken ct = default);
    Task<List<PrivateConversation>> FetchPrivateConversationsAsync(int limit = 30, int offset = 0, CancellationToken ct = default);
    Task<List<PrivateMessage>> FetchPrivateMessagesAsync(string userID, int limit = 30, CancellationToken ct = default);
    Task<List<MyComment>> FetchMyCommentsAsync(int limit = 30, CancellationToken ct = default);

    Task<UserLevelInfo> FetchUserLevelAsync(CancellationToken ct = default);
    Task<List<ListenRecord>> FetchListenRecordsAsync(bool weekly, CancellationToken ct = default);
    Task<SignInResult> DailySignInAsync(CancellationToken ct = default);
    Task<Dictionary<string, int>> FetchUserCountsAsync(CancellationToken ct = default);
}
