using ClearTone.Core.Logging;
using ClearTone.Core.Models;
using ClearTone.Providers.Netease;
using CommunityToolkit.Mvvm.ComponentModel;

namespace ClearTone.Core.Comments;

public sealed class CommentsStore : ObservableObject
{
    private readonly object _gate = new();
    private readonly ICommentProvider _provider;
    private const int PageSize = 20;

    private List<Comment> _comments = new();
    private int _total;
    private bool _hasMore;
    private bool _isLoading;
    private bool _isLoadingMore;
    private string? _errorMessage;
    private string? _paginationError;
    private string? _likeError;
    private readonly HashSet<string> _pendingLikeIDs = new(StringComparer.Ordinal);
    private CommentSort _sort = CommentSort.Recommended;
    private Song? _song;

    private int _loadToken;
    private int _page = 1;
    private string? _cursor;
    private CommentSort _loadedSort = CommentSort.Recommended;
    private readonly Dictionary<string, int> _likeTokens = new(StringComparer.Ordinal);
    private int _likeTokenSeed;
    private CancellationTokenSource? _cts;

    public CommentsStore(ICommentProvider? provider = null)
    {
        _provider = provider ?? NeteaseProvider.Shared;
    }

    public IReadOnlyList<Comment> Comments
    {
        get { lock (_gate) return _comments; }
    }

    public int Total
    {
        get { lock (_gate) return _total; }
        private set { lock (_gate) SetProperty(ref _total, value); }
    }

    public bool HasMore
    {
        get { lock (_gate) return _hasMore; }
        private set { lock (_gate) SetProperty(ref _hasMore, value); }
    }

    public bool IsLoading
    {
        get { lock (_gate) return _isLoading; }
        private set { lock (_gate) SetProperty(ref _isLoading, value); }
    }

    public bool IsLoadingMore
    {
        get { lock (_gate) return _isLoadingMore; }
        private set { lock (_gate) SetProperty(ref _isLoadingMore, value); }
    }

    public string? ErrorMessage
    {
        get { lock (_gate) return _errorMessage; }
        private set { lock (_gate) SetProperty(ref _errorMessage, value); }
    }

    public string? PaginationError
    {
        get { lock (_gate) return _paginationError; }
        private set { lock (_gate) SetProperty(ref _paginationError, value); }
    }

    public string? LikeError
    {
        get { lock (_gate) return _likeError; }
        private set { lock (_gate) SetProperty(ref _likeError, value); }
    }

    public IReadOnlySet<string> PendingLikeIDs
    {
        get { lock (_gate) return new HashSet<string>(_pendingLikeIDs, StringComparer.Ordinal); }
    }

    public CommentSort Sort
    {
        get { lock (_gate) return _sort; }
        set { lock (_gate) SetProperty(ref _sort, value); }
    }

    public Song? Song
    {
        get { lock (_gate) return _song; }
        private set { lock (_gate) SetProperty(ref _song, value); }
    }

    public async Task LoadAsync(Song song, CommentSort? sort = null, CancellationToken ct = default)
    {
        int token;
        CancellationToken pageToken;
        lock (_gate)
        {
            _loadToken++;
            token = _loadToken;
            _cts?.Cancel();
            _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            pageToken = _cts.Token;
            Song = song;
            if (sort.HasValue) Sort = sort.Value;
            _loadedSort = _sort;
            _page = 1;
            _cursor = null;
            _comments = new List<Comment>();
            OnPropertyChanged(nameof(Comments));
            Total = 0;
            HasMore = false;
            IsLoadingMore = false;
            ErrorMessage = null;
            PaginationError = null;
            LikeError = null;
            _pendingLikeIDs.Clear();
            OnPropertyChanged(nameof(PendingLikeIDs));
            _likeTokens.Clear();
            IsLoading = true;
        }
        try
        {
            await FetchPageAsync(token, 1, reset: true, pageToken).ConfigureAwait(false);
        }
        finally
        {
            lock (_gate)
            {
                if (_loadToken == token)
                {
                    IsLoading = false;
                }
            }
        }
    }

    public async Task ReloadAsync(CancellationToken ct = default)
    {
        Song? song;
        CommentSort sort;
        lock (_gate)
        {
            song = _song;
            sort = _sort;
        }
        if (song is null) return;
        await LoadAsync(song, sort, ct).ConfigureAwait(false);
    }

    public async Task LoadMoreAsync(CancellationToken ct = default)
    {
        int token;
        int requestedPage;
        CancellationTokenSource linked;
        lock (_gate)
        {
            if (!_hasMore || _isLoadingMore || _isLoading) return;
            IsLoadingMore = true;
            PaginationError = null;
            token = _loadToken;
            requestedPage = _page + 1;
            var baseToken = _cts?.Token ?? CancellationToken.None;
            linked = CancellationTokenSource.CreateLinkedTokenSource(baseToken, ct);
        }
        try
        {
            await FetchPageAsync(token, requestedPage, reset: false, linked.Token).ConfigureAwait(false);
        }
        finally
        {
            lock (_gate)
            {
                if (_loadToken == token)
                {
                    IsLoadingMore = false;
                }
            }
        }
    }

    private async Task FetchPageAsync(int token, int requestedPage, bool reset, CancellationToken ct)
    {
        string songID;
        CommentSort sort;
        string? cursor;
        lock (_gate)
        {
            if (_song is null) return;
            songID = _song.Id;
            sort = _loadedSort;
            cursor = _cursor;
        }
        try
        {
            var result = await _provider.FetchCommentsAsync(songID, sort, requestedPage, PageSize, cursor, ct).ConfigureAwait(false);
            lock (_gate)
            {
                if (_loadToken != token || ct.IsCancellationRequested) return;
                var seen = reset
                    ? new HashSet<string>(StringComparer.Ordinal)
                    : new HashSet<string>(_comments.Select(c => c.Id), StringComparer.Ordinal);
                var fresh = result.Comments.Where(c => seen.Add(c.Id)).ToList();
                _comments = reset ? fresh : _comments.Concat(fresh).ToList();
                OnPropertyChanged(nameof(Comments));
                _page = requestedPage;
                Total = result.Total;
                HasMore = result.HasMore && result.Comments.Count > 0
                    && (sort != CommentSort.Newest
                        || (result.NextCursor is not null && !string.Equals(result.NextCursor, cursor, StringComparison.Ordinal)));
                _cursor = result.NextCursor;
            }
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (_loadToken != token || ct.IsCancellationRequested) return;
                if (reset)
                {
                    ErrorMessage = error.CtUserMessage();
                    _comments = new List<Comment>();
                    OnPropertyChanged(nameof(Comments));
                }
                else
                {
                    PaginationError = error.CtUserMessage();
                }
            }
        }
    }

    public async Task ToggleLikeAsync(Comment comment, CancellationToken ct = default)
    {
        int token;
        int writeToken;
        Song song;
        bool target;
        Comment previous;
        lock (_gate)
        {
            if (_song is null || _pendingLikeIDs.Contains(comment.Id)) return;
            var index = _comments.FindIndex(c => c.Id == comment.Id);
            if (index < 0) return;
            song = _song;
            token = _loadToken;
            writeToken = ++_likeTokenSeed;
            _likeTokens[comment.Id] = writeToken;
            _pendingLikeIDs.Add(comment.Id);
            OnPropertyChanged(nameof(PendingLikeIDs));
            LikeError = null;
            previous = _comments[index];
            target = !previous.IsLiked;
            _comments[index] = previous with
            {
                IsLiked = target,
                LikedCount = Math.Max(0, previous.LikedCount + (target ? 1 : -1)),
            };
            OnPropertyChanged(nameof(Comments));
        }
        try
        {
            await _provider.LikeCommentAsync(song.Id, comment.Id, target, ct).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (_loadToken != token || !_likeTokens.TryGetValue(comment.Id, out var current) || current != writeToken) return;
                var currentIndex = _comments.FindIndex(c => c.Id == previous.Id);
                if (currentIndex < 0) return;
                _comments[currentIndex] = previous;
                OnPropertyChanged(nameof(Comments));
                LikeError = error.CtUserMessage();
                CTLog.General.Error($"评论点赞失败: {CTLog.Sanitize(error.Message)}");
            }
        }
        finally
        {
            lock (_gate)
            {
                if (_loadToken == token && _likeTokens.TryGetValue(comment.Id, out var current) && current == writeToken)
                {
                    _likeTokens.Remove(comment.Id);
                    _pendingLikeIDs.Remove(comment.Id);
                    OnPropertyChanged(nameof(PendingLikeIDs));
                }
            }
        }
    }
}
