using ClearTone.Core.Models;
using ClearTone.Providers.Netease;
using CommunityToolkit.Mvvm.ComponentModel;
using ArtistModel = ClearTone.Core.Models.Artist;

namespace ClearTone.Core.Artist;

public sealed class ArtistProfileSession : ObservableObject
{
    private readonly object _gate = new();
    private readonly IArtistProfileProvider _provider;
    private const int SongPageSize = 50;
    private const int AlbumPageSize = 30;
    private const int MVPageSize = 30;

    private string _artistID;
    private int _generation;

    private ArtistProfile? _profile;
    private bool _isLoadingProfile;
    private string? _profileError;

    private ArtistIntro? _intro;
    private bool _isLoadingIntro;
    private string? _introError;

    private List<Song> _hotSongs = new();
    private bool _isLoadingHighlights;

    private List<Song> _songs = new();
    private int _songsTotal;
    private bool _isLoadingSongs;
    private bool _isLoadingMoreSongs;
    private string? _songsError;
    private bool _songsHasMore = true;

    private List<Album> _albums = new();
    private bool _isLoadingAlbums;
    private bool _isLoadingMoreAlbums;
    private string? _albumsError;
    private bool _albumsHasMore = true;
    private bool? _isFollowed;

    private List<ArtistMV> _mvs = new();
    private bool _isLoadingMVs;
    private bool _isLoadingMoreMVs;
    private string? _mvsError;
    private bool _mvsHasMore = true;

    private List<ArtistModel> _similarArtists = new();

    public ArtistProfileSession(string artistID, IArtistProfileProvider? provider = null)
    {
        _artistID = artistID;
        _provider = provider ?? (IArtistProfileProvider)NeteaseProvider.Shared;
    }

    public string ArtistID
    {
        get { lock (_gate) return _artistID; }
        private set { lock (_gate) SetProperty(ref _artistID, value); }
    }

    public ArtistProfile? Profile
    {
        get { lock (_gate) return _profile; }
        private set { lock (_gate) SetProperty(ref _profile, value); }
    }

    public bool IsLoadingProfile
    {
        get { lock (_gate) return _isLoadingProfile; }
        private set { lock (_gate) SetProperty(ref _isLoadingProfile, value); }
    }

    public string? ProfileError
    {
        get { lock (_gate) return _profileError; }
        private set { lock (_gate) SetProperty(ref _profileError, value); }
    }

    public ArtistIntro? Intro
    {
        get { lock (_gate) return _intro; }
        private set { lock (_gate) SetProperty(ref _intro, value); }
    }

    public bool IsLoadingIntro
    {
        get { lock (_gate) return _isLoadingIntro; }
        private set { lock (_gate) SetProperty(ref _isLoadingIntro, value); }
    }

    public string? IntroError
    {
        get { lock (_gate) return _introError; }
        private set { lock (_gate) SetProperty(ref _introError, value); }
    }

    public IReadOnlyList<Song> HotSongs
    {
        get { lock (_gate) return _hotSongs; }
    }

    public bool IsLoadingHighlights
    {
        get { lock (_gate) return _isLoadingHighlights; }
        private set { lock (_gate) SetProperty(ref _isLoadingHighlights, value); }
    }

    public IReadOnlyList<Song> Songs
    {
        get { lock (_gate) return _songs; }
    }

    public int SongsTotal
    {
        get { lock (_gate) return _songsTotal; }
        private set { lock (_gate) SetProperty(ref _songsTotal, value); }
    }

    public bool IsLoadingSongs
    {
        get { lock (_gate) return _isLoadingSongs; }
        private set { lock (_gate) SetProperty(ref _isLoadingSongs, value); }
    }

    public bool IsLoadingMoreSongs
    {
        get { lock (_gate) return _isLoadingMoreSongs; }
        private set { lock (_gate) SetProperty(ref _isLoadingMoreSongs, value); }
    }

    public string? SongsError
    {
        get { lock (_gate) return _songsError; }
        private set { lock (_gate) SetProperty(ref _songsError, value); }
    }

    public bool CanLoadMoreSongs
    {
        get { lock (_gate) return _songsHasMore && _songs.Count > 0 && !_isLoadingMoreSongs; }
    }

    public IReadOnlyList<Album> Albums
    {
        get { lock (_gate) return _albums; }
    }

    public bool IsLoadingAlbums
    {
        get { lock (_gate) return _isLoadingAlbums; }
        private set { lock (_gate) SetProperty(ref _isLoadingAlbums, value); }
    }

    public bool IsLoadingMoreAlbums
    {
        get { lock (_gate) return _isLoadingMoreAlbums; }
        private set { lock (_gate) SetProperty(ref _isLoadingMoreAlbums, value); }
    }

    public string? AlbumsError
    {
        get { lock (_gate) return _albumsError; }
        private set { lock (_gate) SetProperty(ref _albumsError, value); }
    }

    public bool? IsFollowed
    {
        get { lock (_gate) return _isFollowed; }
        private set { lock (_gate) SetProperty(ref _isFollowed, value); }
    }

    public bool CanLoadMoreAlbums
    {
        get { lock (_gate) return _albumsHasMore && _albums.Count > 0 && !_isLoadingMoreAlbums; }
    }

    public IReadOnlyList<ArtistMV> MVs
    {
        get { lock (_gate) return _mvs; }
    }

    public bool IsLoadingMVs
    {
        get { lock (_gate) return _isLoadingMVs; }
        private set { lock (_gate) SetProperty(ref _isLoadingMVs, value); }
    }

    public bool IsLoadingMoreMVs
    {
        get { lock (_gate) return _isLoadingMoreMVs; }
        private set { lock (_gate) SetProperty(ref _isLoadingMoreMVs, value); }
    }

    public string? MVsError
    {
        get { lock (_gate) return _mvsError; }
        private set { lock (_gate) SetProperty(ref _mvsError, value); }
    }

    public bool CanLoadMoreMVs
    {
        get { lock (_gate) return _mvsHasMore && _mvs.Count > 0 && !_isLoadingMoreMVs; }
    }

    public IReadOnlyList<ArtistModel> SimilarArtists
    {
        get { lock (_gate) return _similarArtists; }
    }

    public void SwitchTo(string artistID)
    {
        lock (_gate)
        {
            if (string.Equals(artistID, _artistID, StringComparison.Ordinal)) return;
            ResetLocked();
            ArtistID = artistID;
        }
    }

    public void ReloadForDataContext()
    {
        lock (_gate) ResetLocked();
    }

    public void Reset()
    {
        lock (_gate) ResetLocked();
    }

    private void ResetLocked()
    {
        _generation++;
        Profile = null;
        IsLoadingProfile = false;
        ProfileError = null;
        Intro = null;
        IsLoadingIntro = false;
        IntroError = null;
        _hotSongs = new List<Song>();
        OnPropertyChanged(nameof(HotSongs));
        IsLoadingHighlights = false;
        _songs = new List<Song>();
        OnPropertyChanged(nameof(Songs));
        SongsTotal = 0;
        IsLoadingSongs = false;
        IsLoadingMoreSongs = false;
        SongsError = null;
        _songsHasMore = true;
        _albums = new List<Album>();
        OnPropertyChanged(nameof(Albums));
        IsLoadingAlbums = false;
        IsLoadingMoreAlbums = false;
        AlbumsError = null;
        _albumsHasMore = true;
        IsFollowed = null;
        _mvs = new List<ArtistMV>();
        OnPropertyChanged(nameof(MVs));
        IsLoadingMVs = false;
        IsLoadingMoreMVs = false;
        MVsError = null;
        _mvsHasMore = true;
        _similarArtists = new List<ArtistModel>();
        OnPropertyChanged(nameof(SimilarArtists));
    }

    public async Task LoadProfileAsync(CancellationToken ct = default)
    {
        int token;
        string id;
        lock (_gate)
        {
            token = _generation;
            id = _artistID;
            IsLoadingProfile = true;
            ProfileError = null;
        }
        try
        {
            var loaded = await _provider.FetchArtistProfileAsync(id, ct).ConfigureAwait(false);
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                Profile = loaded;
                IsFollowed = loaded.IsFollowed;
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                ProfileError = error.CtUserMessage();
            }
        }
        finally
        {
            lock (_gate)
            {
                if (token == _generation) IsLoadingProfile = false;
            }
        }
    }

    public async Task LoadHighlightsAsync(CancellationToken ct = default)
    {
        int token;
        string id;
        lock (_gate)
        {
            if (_isLoadingHighlights) return;
            IsLoadingHighlights = true;
            token = _generation;
            id = _artistID;
        }
        try
        {
            var hotTask = _provider.FetchHotArtistSongsAsync(id, ct);
            var similarTask = _provider.FetchSimilarArtistsAsync(id, ct);

            List<Song>? hot = null;
            List<ArtistModel>? similar = null;
            try
            {
                hot = await hotTask.ConfigureAwait(false);
            }
            catch (Exception)
            {
            }
            lock (_gate)
            {
                if (token == _generation && !ct.IsCancellationRequested && hot is not null)
                {
                    _hotSongs = hot;
                    OnPropertyChanged(nameof(HotSongs));
                }
            }
            try
            {
                similar = await similarTask.ConfigureAwait(false);
            }
            catch (Exception)
            {
            }
            lock (_gate)
            {
                if (token == _generation && !ct.IsCancellationRequested && similar is not null)
                {
                    _similarArtists = similar.Where(a => !string.Equals(a.Id, id, StringComparison.Ordinal)).Take(12).ToList();
                    OnPropertyChanged(nameof(SimilarArtists));
                }
            }
        }
        finally
        {
            lock (_gate)
            {
                IsLoadingHighlights = false;
            }
        }
    }

    public async Task LoadIntroAsync(CancellationToken ct = default)
    {
        int token;
        string id;
        lock (_gate)
        {
            token = _generation;
            id = _artistID;
            IsLoadingIntro = true;
            IntroError = null;
        }
        try
        {
            var loaded = await _provider.FetchArtistIntroAsync(id, ct).ConfigureAwait(false);
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                Intro = loaded;
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                IntroError = error.CtUserMessage();
            }
        }
        finally
        {
            lock (_gate)
            {
                if (token == _generation) IsLoadingIntro = false;
            }
        }
    }

    public async Task LoadSongsAsync(CancellationToken ct = default)
    {
        int token;
        string id;
        lock (_gate)
        {
            if (_isLoadingSongs) return;
            IsLoadingSongs = true;
            SongsError = null;
            token = _generation;
            id = _artistID;
        }
        try
        {
            var page = await _provider.FetchArtistSongsAsync(id, 0, SongPageSize, "hot", ct).ConfigureAwait(false);
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                _songs = page.Songs;
                OnPropertyChanged(nameof(Songs));
                SongsTotal = page.Total;
                _songsHasMore = page.HasMore;
            }
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                SongsError = error.CtUserMessage();
            }
        }
        finally
        {
            lock (_gate)
            {
                if (token == _generation) IsLoadingSongs = false;
            }
        }
    }

    public async Task LoadMoreSongsAsync(CancellationToken ct = default)
    {
        int token;
        string id;
        int offset;
        lock (_gate)
        {
            if (!_songsHasMore || _songs.Count == 0 || _isLoadingMoreSongs) return;
            IsLoadingMoreSongs = true;
            SongsError = null;
            token = _generation;
            id = _artistID;
            offset = _songs.Count;
        }
        try
        {
            var page = await _provider.FetchArtistSongsAsync(id, offset, SongPageSize, "hot", ct).ConfigureAwait(false);
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                var existing = new HashSet<string>(_songs.Select(s => s.Id), StringComparer.Ordinal);
                _songs = _songs.Concat(page.Songs.Where(s => !existing.Contains(s.Id))).ToList();
                OnPropertyChanged(nameof(Songs));
                SongsTotal = Math.Max(_songsTotal, page.Total);
                _songsHasMore = page.HasMore;
            }
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                SongsError = error.CtUserMessage();
            }
        }
        finally
        {
            lock (_gate)
            {
                if (token == _generation) IsLoadingMoreSongs = false;
            }
        }
    }

    public async Task LoadAlbumsAsync(CancellationToken ct = default)
    {
        int token;
        string id;
        lock (_gate)
        {
            if (_isLoadingAlbums) return;
            IsLoadingAlbums = true;
            AlbumsError = null;
            token = _generation;
            id = _artistID;
        }
        try
        {
            var page = await _provider.FetchArtistAlbumsAsync(id, 0, AlbumPageSize, ct).ConfigureAwait(false);
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                _albums = page.Albums;
                OnPropertyChanged(nameof(Albums));
                _albumsHasMore = page.HasMore;
                if (page.IsFollowed.HasValue) IsFollowed = page.IsFollowed.Value;
            }
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                AlbumsError = error.CtUserMessage();
            }
        }
        finally
        {
            lock (_gate)
            {
                if (token == _generation) IsLoadingAlbums = false;
            }
        }
    }

    public async Task LoadMoreAlbumsAsync(CancellationToken ct = default)
    {
        int token;
        string id;
        int offset;
        lock (_gate)
        {
            if (!_albumsHasMore || _albums.Count == 0 || _isLoadingMoreAlbums) return;
            IsLoadingMoreAlbums = true;
            AlbumsError = null;
            token = _generation;
            id = _artistID;
            offset = _albums.Count;
        }
        try
        {
            var page = await _provider.FetchArtistAlbumsAsync(id, offset, AlbumPageSize, ct).ConfigureAwait(false);
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                var existing = new HashSet<string>(_albums.Select(a => a.Id), StringComparer.Ordinal);
                _albums = _albums.Concat(page.Albums.Where(a => !existing.Contains(a.Id))).ToList();
                OnPropertyChanged(nameof(Albums));
                _albumsHasMore = page.HasMore;
            }
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                AlbumsError = error.CtUserMessage();
            }
        }
        finally
        {
            lock (_gate)
            {
                if (token == _generation) IsLoadingMoreAlbums = false;
            }
        }
    }

    public async Task LoadMVsAsync(CancellationToken ct = default)
    {
        int token;
        string id;
        lock (_gate)
        {
            if (_isLoadingMVs) return;
            IsLoadingMVs = true;
            MVsError = null;
            token = _generation;
            id = _artistID;
        }
        try
        {
            var page = await _provider.FetchArtistMVsAsync(id, 0, MVPageSize, ct).ConfigureAwait(false);
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                _mvs = page.Mvs;
                OnPropertyChanged(nameof(MVs));
                _mvsHasMore = page.HasMore;
            }
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                MVsError = error.CtUserMessage();
            }
        }
        finally
        {
            lock (_gate)
            {
                if (token == _generation) IsLoadingMVs = false;
            }
        }
    }

    public async Task LoadMoreMVsAsync(CancellationToken ct = default)
    {
        int token;
        string id;
        int offset;
        lock (_gate)
        {
            if (!_mvsHasMore || _mvs.Count == 0 || _isLoadingMoreMVs) return;
            IsLoadingMoreMVs = true;
            MVsError = null;
            token = _generation;
            id = _artistID;
            offset = _mvs.Count;
        }
        try
        {
            var page = await _provider.FetchArtistMVsAsync(id, offset, MVPageSize, ct).ConfigureAwait(false);
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                var existing = new HashSet<string>(_mvs.Select(m => m.Id), StringComparer.Ordinal);
                _mvs = _mvs.Concat(page.Mvs.Where(m => !existing.Contains(m.Id))).ToList();
                OnPropertyChanged(nameof(MVs));
                _mvsHasMore = page.HasMore;
            }
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (token != _generation || ct.IsCancellationRequested) return;
                MVsError = error.CtUserMessage();
            }
        }
        finally
        {
            lock (_gate)
            {
                if (token == _generation) IsLoadingMoreMVs = false;
            }
        }
    }

    public void SetFollowed(bool value)
    {
        lock (_gate) IsFollowed = value;
    }
}
