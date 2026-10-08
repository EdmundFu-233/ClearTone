using ClearTone.Core.Models;
using ClearTone.Providers.Netease;
using CommunityToolkit.Mvvm.ComponentModel;
using ArtistModel = ClearTone.Core.Models.Artist;

namespace ClearTone.Core.Search;

public sealed class SearchSession : ObservableObject
{
    private readonly object _gate = new();
    private readonly IMusicProvider _provider;
    private const int PageSize = 30;

    private string _draftQuery = "";
    private SearchResult? _result;
    private bool _isLoading;
    private string? _errorMessage;
    private bool _isLoadingMore;
    private string? _paginationError;
    private string? _activeQuery;
    private SearchType? _activeType;
    private int _currentPage = 1;

    private int _generation;
    private CancellationTokenSource? _searchCts;
    private CancellationTokenSource? _loadMoreCts;

    public SearchSession(IMusicProvider? provider = null)
    {
        _provider = provider ?? NeteaseProvider.Shared;
    }

    public string DraftQuery
    {
        get { lock (_gate) return _draftQuery; }
        set { lock (_gate) SetProperty(ref _draftQuery, value); }
    }

    public SearchResult? Result
    {
        get { lock (_gate) return _result; }
        private set { lock (_gate) SetProperty(ref _result, value); }
    }

    public bool IsLoading
    {
        get { lock (_gate) return _isLoading; }
        private set { lock (_gate) SetProperty(ref _isLoading, value); }
    }

    public string? ErrorMessage
    {
        get { lock (_gate) return _errorMessage; }
        private set { lock (_gate) SetProperty(ref _errorMessage, value); }
    }

    public bool IsLoadingMore
    {
        get { lock (_gate) return _isLoadingMore; }
        private set { lock (_gate) SetProperty(ref _isLoadingMore, value); }
    }

    public string? PaginationError
    {
        get { lock (_gate) return _paginationError; }
        private set { lock (_gate) SetProperty(ref _paginationError, value); }
    }

    public string? ActiveQuery
    {
        get { lock (_gate) return _activeQuery; }
        private set { lock (_gate) SetProperty(ref _activeQuery, value); }
    }

    public SearchType? ActiveType
    {
        get { lock (_gate) return _activeType; }
        private set { lock (_gate) SetProperty(ref _activeType, value); }
    }

    public int CurrentPage
    {
        get { lock (_gate) return _currentPage; }
        private set { lock (_gate) SetProperty(ref _currentPage, value); }
    }

    public SearchType DisplayType
    {
        get { lock (_gate) return _activeType ?? SearchType.Song; }
    }

    public bool HasActiveQuery
    {
        get { lock (_gate) return _activeQuery is not null; }
    }

    public void Submit(SearchType type)
    {
        string query;
        lock (_gate) query = _draftQuery.Trim();
        if (query.Length == 0) return;
        Start(query, type);
    }

    public void Retry(SearchType type)
    {
        string? query;
        SearchType? activeType;
        lock (_gate)
        {
            query = _activeQuery;
            activeType = _activeType;
        }
        if (query is null)
        {
            Submit(type);
            return;
        }
        Start(query, activeType ?? type);
    }

    public void RefreshDataContext(SearchType type)
    {
        string trimmed;
        string? query;
        SearchType? activeType;
        lock (_gate)
        {
            trimmed = _draftQuery.Trim();
            query = _activeQuery;
            activeType = _activeType;
        }
        if (trimmed.Length == 0)
        {
            if (query is null) return;
            Start(query, activeType ?? type);
            return;
        }
        Submit(type);
    }

    private void Start(string query, SearchType type)
    {
        int generation;
        CancellationToken token;
        lock (_gate)
        {
            _generation++;
            generation = _generation;
            _searchCts?.Cancel();
            _searchCts = new CancellationTokenSource();
            token = _searchCts.Token;
            _loadMoreCts?.Cancel();
            _loadMoreCts = null;
            ActiveQuery = query;
            ActiveType = type;
            CurrentPage = 1;
            IsLoading = true;
            ErrorMessage = null;
            IsLoadingMore = false;
            PaginationError = null;
        }
        _ = Task.Run(() => SearchPageAsync(query, type, 1, generation, token));
    }

    private async Task SearchPageAsync(string query, SearchType type, int page, int generation, CancellationToken ct)
    {
        try
        {
            var found = await _provider.SearchAsync(query, type, page, PageSize, ct).ConfigureAwait(false);
            lock (_gate)
            {
                if (generation != _generation || ct.IsCancellationRequested) return;
                Result = found;
            }
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (generation != _generation || ct.IsCancellationRequested) return;
                ErrorMessage = error.CtUserMessage();
                Result = null;
            }
        }
        finally
        {
            lock (_gate)
            {
                if (generation == _generation)
                {
                    IsLoading = false;
                }
            }
        }
    }

    public void LoadMore()
    {
        int generation;
        int page;
        string query;
        SearchType type;
        CancellationToken token;
        lock (_gate)
        {
            if (_result is null || !_result.HasMore || _isLoading || _isLoadingMore || _loadMoreCts is not null) return;
            if (_activeQuery is null || _activeType is null) return;
            generation = _generation;
            page = _currentPage + 1;
            query = _activeQuery;
            type = _activeType.Value;
            CurrentPage = page;
            IsLoadingMore = true;
            PaginationError = null;
            _loadMoreCts = new CancellationTokenSource();
            token = _loadMoreCts.Token;
        }
        _ = Task.Run(() => LoadMorePageAsync(query, type, page, generation, token));
    }

    private async Task LoadMorePageAsync(string query, SearchType type, int page, int generation, CancellationToken ct)
    {
        try
        {
            var more = await _provider.SearchAsync(query, type, page, PageSize, ct).ConfigureAwait(false);
            lock (_gate)
            {
                if (generation != _generation || ct.IsCancellationRequested) return;
                var merged = _result is null
                    ? new SearchResult()
                    : new SearchResult
                    {
                        Songs = new List<Song>(_result.Songs),
                        Artists = new List<ArtistModel>(_result.Artists),
                        Albums = new List<Album>(_result.Albums),
                        Playlists = new List<Playlist>(_result.Playlists),
                        TotalCount = _result.TotalCount,
                        HasMore = _result.HasMore,
                    };
                switch (type)
                {
                    case SearchType.Song:
                        merged.Songs.AddRange(more.Songs);
                        break;
                    case SearchType.Artist:
                        merged.Artists.AddRange(more.Artists);
                        break;
                    case SearchType.Album:
                        merged.Albums.AddRange(more.Albums);
                        break;
                    case SearchType.Playlist:
                        merged.Playlists.AddRange(more.Playlists);
                        break;
                }
                merged.TotalCount = more.TotalCount;
                merged.HasMore = more.HasMore;
                Result = merged;
            }
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (generation != _generation || ct.IsCancellationRequested) return;
                CurrentPage = page - 1;
                PaginationError = error.CtUserMessage();
            }
        }
        finally
        {
            lock (_gate)
            {
                if (generation == _generation)
                {
                    _loadMoreCts = null;
                    IsLoadingMore = false;
                }
            }
        }
    }

    public void Reset()
    {
        lock (_gate)
        {
            _generation++;
            _searchCts?.Cancel();
            _searchCts = null;
            _loadMoreCts?.Cancel();
            _loadMoreCts = null;
            ActiveQuery = null;
            ActiveType = null;
            Result = null;
            CurrentPage = 1;
            IsLoading = false;
            IsLoadingMore = false;
            ErrorMessage = null;
            PaginationError = null;
            DraftQuery = "";
        }
    }

    public void CancelInFlight()
    {
        lock (_gate)
        {
            var hadInFlightPagination = _loadMoreCts is not null;
            var hadInFlightSearch = _isLoading;
            _generation++;
            _searchCts?.Cancel();
            _searchCts = null;
            _loadMoreCts?.Cancel();
            _loadMoreCts = null;
            if (hadInFlightSearch)
            {
                ActiveQuery = null;
                ActiveType = null;
                Result = null;
                CurrentPage = 1;
                ErrorMessage = null;
                PaginationError = null;
            }
            if (hadInFlightPagination) CurrentPage = Math.Max(1, _currentPage - 1);
            IsLoading = false;
            IsLoadingMore = false;
        }
    }
}
