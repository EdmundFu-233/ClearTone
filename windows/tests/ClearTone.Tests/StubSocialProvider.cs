using ClearTone.Core.Comments;
using ClearTone.Core.Models;

namespace ClearTone.Tests;

public sealed class StubSocialProvider : IMusicSocialProvider
{
    private readonly object _gate = new();
    private readonly List<string> _suggestionCalls = new();
    private int _topListCalls;
    private int _hotCallCount;

    public Func<CancellationToken, Task<List<TopList>>>? TopListsHandler { get; set; }
    public Func<string, CancellationToken, Task<List<SearchSuggestion>>>? SearchSuggestionsHandler { get; set; }
    public Func<CancellationToken, Task<List<HotSearchTerm>>>? HotSearchTermsHandler { get; set; }

    public int TopListCallCount
    {
        get { lock (_gate) return _topListCalls; }
    }

    public IReadOnlyList<string> SuggestionCalls
    {
        get { lock (_gate) return _suggestionCalls.ToList(); }
    }

    public int HotCallCount
    {
        get { lock (_gate) return _hotCallCount; }
    }

    public async Task<List<TopList>> FetchTopListsAsync(CancellationToken ct = default)
    {
        lock (_gate) _topListCalls += 1;
        if (TopListsHandler is { } handler) return await handler(ct).ConfigureAwait(false);
        return new List<TopList>();
    }

    public async Task<List<SearchSuggestion>> FetchSearchSuggestionsAsync(string keyword, CancellationToken ct = default)
    {
        lock (_gate) _suggestionCalls.Add(keyword);
        if (SearchSuggestionsHandler is { } handler) return await handler(keyword, ct).ConfigureAwait(false);
        return new List<SearchSuggestion>();
    }

    public async Task<List<HotSearchTerm>> FetchHotSearchTermsAsync(CancellationToken ct = default)
    {
        lock (_gate) _hotCallCount += 1;
        if (HotSearchTermsHandler is { } handler) return await handler(ct).ConfigureAwait(false);
        return new List<HotSearchTerm>();
    }

    public Task<CommentPage> FetchCommentsAsync(string songID, CommentSort sort, int page, int pageSize = 20, string? cursor = null, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchCommentsAsync");

    public Task LikeCommentAsync(string songID, string commentID, bool like, CancellationToken ct = default) =>
        throw new NotSupportedException("LikeCommentAsync");

    public Task SubscribePlaylistAsync(string id, bool subscribe, CancellationToken ct = default) =>
        throw new NotSupportedException("SubscribePlaylistAsync");

    public Task<Playlist> CreatePlaylistAsync(string name, bool isPrivate, CancellationToken ct = default) =>
        throw new NotSupportedException("CreatePlaylistAsync");

    public Task DeletePlaylistAsync(string id, CancellationToken ct = default) =>
        throw new NotSupportedException("DeletePlaylistAsync");

    public Task UpdatePlaylistNameAsync(string id, string name, CancellationToken ct = default) =>
        throw new NotSupportedException("UpdatePlaylistNameAsync");

    public Task AddSongsToPlaylistAsync(string playlistID, IReadOnlyList<string> songIDs, CancellationToken ct = default) =>
        throw new NotSupportedException("AddSongsToPlaylistAsync");

    public Task RemoveSongsFromPlaylistAsync(string playlistID, IReadOnlyList<string> songIDs, CancellationToken ct = default) =>
        throw new NotSupportedException("RemoveSongsFromPlaylistAsync");

    public Task SubscribeAlbumAsync(string id, bool subscribe, CancellationToken ct = default) =>
        throw new NotSupportedException("SubscribeAlbumAsync");

    public Task SubscribeArtistAsync(string id, bool subscribe, CancellationToken ct = default) =>
        throw new NotSupportedException("SubscribeArtistAsync");

    public Task SubscribeRadioAsync(string id, bool subscribe, CancellationToken ct = default) =>
        throw new NotSupportedException("SubscribeRadioAsync");

    public Task<List<Playlist>> FetchSubscribedPlaylistsAsync(int limit = 50, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchSubscribedPlaylistsAsync");

    public Task<List<Album>> FetchSubscribedAlbumsAsync(int limit = 50, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchSubscribedAlbumsAsync");

    public Task<List<Artist>> FetchSubscribedArtistsAsync(int limit = 50, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchSubscribedArtistsAsync");

    public Task<List<RadioStation>> FetchSubscribedRadiosAsync(int limit = 30, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchSubscribedRadiosAsync");

    public Task<RadioStation> FetchRadioStationDetailAsync(string radioID, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchRadioStationDetailAsync");

    public Task<List<Song>> FetchTopSongsAsync(TopSongArea area, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchTopSongsAsync");

    public Task<List<Playlist>> FetchHotPlaylistsAsync(string? category, TopPlaylistOrder order, int limit, int offset, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchHotPlaylistsAsync");

    public Task<List<PlaylistCategoryGroup>> FetchPlaylistCategoriesAsync(CancellationToken ct = default) =>
        throw new NotSupportedException("FetchPlaylistCategoriesAsync");

    public Task<List<string>> FetchHotPlaylistTagsAsync(CancellationToken ct = default) =>
        throw new NotSupportedException("FetchHotPlaylistTagsAsync");

    public Task<List<Song>> FetchPersonalFMAsync(CancellationToken ct = default) =>
        throw new NotSupportedException("FetchPersonalFMAsync");

    public Task<List<Playlist>> FetchDailyRecommendPlaylistsAsync(CancellationToken ct = default) =>
        throw new NotSupportedException("FetchDailyRecommendPlaylistsAsync");

    public Task<List<Song>> FetchNewSongsAsync(int limit = 30, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchNewSongsAsync");

    public Task<List<Album>> FetchNewAlbumsAsync(int limit = 30, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchNewAlbumsAsync");

    public Task<List<Song>> FetchSimilarSongsAsync(string songID, int limit = 30, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchSimilarSongsAsync");

    public Task<List<Artist>> FetchSimilarArtistsAsync(string artistID, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchSimilarArtistsAsync");

    public Task<Song?> DislikeDailyRecommendAsync(string songID, CancellationToken ct = default) =>
        throw new NotSupportedException("DislikeDailyRecommendAsync");

    public Task<List<UserNotice>> FetchNoticesAsync(int limit = 30, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchNoticesAsync");

    public Task<List<PrivateConversation>> FetchPrivateConversationsAsync(int limit = 30, int offset = 0, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchPrivateConversationsAsync");

    public Task<List<PrivateMessage>> FetchPrivateMessagesAsync(string userID, int limit = 30, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchPrivateMessagesAsync");

    public Task<List<MyComment>> FetchMyCommentsAsync(int limit = 30, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchMyCommentsAsync");

    public Task<UserLevelInfo> FetchUserLevelAsync(CancellationToken ct = default) =>
        throw new NotSupportedException("FetchUserLevelAsync");

    public Task<List<ListenRecord>> FetchListenRecordsAsync(bool weekly, CancellationToken ct = default) =>
        throw new NotSupportedException("FetchListenRecordsAsync");

    public Task<SignInResult> DailySignInAsync(CancellationToken ct = default) =>
        throw new NotSupportedException("DailySignInAsync");

    public Task<Dictionary<string, int>> FetchUserCountsAsync(CancellationToken ct = default) =>
        throw new NotSupportedException("FetchUserCountsAsync");
}
