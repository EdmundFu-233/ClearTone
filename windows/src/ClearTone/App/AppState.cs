using ClearTone.Core;
using ClearTone.Core.Logging;
using ClearTone.Core.Models;
using ClearTone.Core.Persistence;
using ClearTone.Core.Security;
using ClearTone.Playback;
using ClearTone.Providers.Netease;
using CommunityToolkit.Mvvm.ComponentModel;

namespace ClearTone.Shell;

public enum Page
{
    Discover,
    Search,
    TopList,
    Radio,
    PersonalFM,
    MyMusic,
    Liked,
    Local,
    Recent,
    Messages,
    Profile,
    PlaylistDetail,
    RadioDetail,
    AlbumDetail,
    ArtistDetail,
    SongComments,
    Settings,
}

public static class PageExtensions
{
    public static string DisplayName(this Page page) => page switch
    {
        Page.Discover => "发现音乐",
        Page.Search => "搜索",
        Page.TopList => "排行榜",
        Page.Radio => "电台",
        Page.PersonalFM => "私人FM",
        Page.MyMusic => "我的音乐",
        Page.Liked => "喜欢的音乐",
        Page.Local => "本地音乐",
        Page.Recent => "最近播放",
        Page.Messages => "消息",
        Page.Profile => "我的",
        Page.PlaylistDetail => "歌单详情",
        Page.RadioDetail => "电台详情",
        Page.AlbumDetail => "专辑详情",
        Page.ArtistDetail => "歌手详情",
        Page.SongComments => "歌曲评论",
        _ => "设置",
    };

    public static string Glyph(this Page page) => page switch
    {
        Page.Discover => "\uE8D6",
        Page.Search => "\uE721",
        Page.TopList => "\uE8FD",
        Page.Radio => "\uE704",
        Page.PersonalFM => "\uE720",
        Page.MyMusic => "\uE8A5",
        Page.Liked => "\uE734",
        Page.Local => "\uE8B7",
        Page.Recent => "\uE81C",
        Page.Messages => "\uE8BD",
        Page.Profile => "\uE77B",
        Page.PlaylistDetail => "\uE8A5",
        Page.RadioDetail => "\uE704",
        Page.AlbumDetail => "\uE8B9",
        Page.ArtistDetail => "\uE77B",
        Page.SongComments => "\uE90A",
        _ => "\uE713",
    };

    public static bool IsDetail(this Page page) => page is
        Page.PlaylistDetail or Page.RadioDetail or Page.AlbumDetail or Page.ArtistDetail or Page.SongComments;

    public static Page[] SidebarPages { get; } = new[]
    {
        Page.Discover, Page.Search, Page.TopList, Page.Radio, Page.PersonalFM,
        Page.MyMusic, Page.Liked, Page.Local, Page.Recent, Page.Messages,
    };
}

public class AppState : ObservableObject
{
    public static readonly AppState Shared = new();

    private readonly IMusicProvider _provider;
    private readonly NeteaseProvider _sessionOwner;

    private Page _currentPage = Page.Discover;
    private bool _isNowPlayingExpanded;
    private bool _showQueue;
    private AccountInfo? _account;
    private bool _isLoggedIn;
    private string? _selectedPlaylistID;
    private string? _selectedRadioID;
    private string? _selectedAlbumID;
    private string? _selectedArtistID;
    private Song? _commentSong;
    private string _searchQuery = "";
    private readonly List<Page> _pageHistory = new();
    private List<Song> _likedSongs = new();
    private int _likesVersion;
    private List<Playlist> _userPlaylists = new();
    private bool _isLoadingUserPlaylists;
    private Guid _userPlaylistsToken = Guid.NewGuid();
    private bool _needsReLogin;
    private bool _isLoginPresented;
    private HashSet<string> _likedIDs = new();
    private bool _hasLoadedLikes;
    private bool _hasLoadedLikedSongs;
    private readonly HashSet<string> _likeRequestsInFlight = new();
    private DateTimeOffset? _likeWriteCooldownUntil;
    private string? _likesWriteError;
    private string? _lastWriteError;
    private int _accountGeneration;

    public AppState(IMusicProvider? provider = null)
    {
        _provider = provider ?? NeteaseProvider.Shared;
        _sessionOwner = NeteaseProvider.Shared;
        _sessionOwner.SessionExpired += HandleSessionExpired;
    }

    public IMusicProvider Provider => _provider;
    public NeteaseProvider Social => _sessionOwner;

    public Page CurrentPage
    {
        get => _currentPage;
        set => SetProperty(ref _currentPage, value);
    }

    public bool IsNowPlayingExpanded
    {
        get => _isNowPlayingExpanded;
        set => SetProperty(ref _isNowPlayingExpanded, value);
    }

    public bool ShowQueue
    {
        get => _showQueue;
        set => SetProperty(ref _showQueue, value);
    }

    public AccountInfo? Account
    {
        get => _account;
        private set => SetProperty(ref _account, value);
    }

    public bool IsLoggedIn
    {
        get => _isLoggedIn;
        private set => SetProperty(ref _isLoggedIn, value);
    }

    public string? SelectedPlaylistID
    {
        get => _selectedPlaylistID;
        set => SetProperty(ref _selectedPlaylistID, value);
    }

    public string? SelectedRadioID
    {
        get => _selectedRadioID;
        set => SetProperty(ref _selectedRadioID, value);
    }

    public string? SelectedAlbumID
    {
        get => _selectedAlbumID;
        set => SetProperty(ref _selectedAlbumID, value);
    }

    public string? SelectedArtistID
    {
        get => _selectedArtistID;
        set => SetProperty(ref _selectedArtistID, value);
    }

    public Song? CommentSong
    {
        get => _commentSong;
        set => SetProperty(ref _commentSong, value);
    }

    public string SearchQuery
    {
        get => _searchQuery;
        set => SetProperty(ref _searchQuery, value);
    }

    public IReadOnlyList<Page> PageHistory => _pageHistory;

    public bool CanGoBack => _pageHistory.Count > 0;

    public void GoBack()
    {
        if (_pageHistory.Count == 0) return;
        var previous = _pageHistory[^1];
        _pageHistory.RemoveAt(_pageHistory.Count - 1);
        OnPropertyChanged(nameof(CanGoBack));
        CurrentPage = previous;
    }

    public void SwitchToTopLevel(Page page)
    {
        _pageHistory.Clear();
        OnPropertyChanged(nameof(CanGoBack));
        CurrentPage = page;
    }

    public void NavigateToDetail(Page page)
    {
        if (page == CurrentPage) return;
        if (_pageHistory.Count > 0 && _pageHistory[^1] == page)
        {
            CurrentPage = page;
            return;
        }
        _pageHistory.Add(CurrentPage);
        OnPropertyChanged(nameof(CanGoBack));
        CurrentPage = page;
    }

    public void OpenPlaylist(string id)
    {
        SelectedPlaylistID = id;
        NavigateToDetail(Page.PlaylistDetail);
    }

    public void OpenRadio(string id)
    {
        SelectedRadioID = id;
        NavigateToDetail(Page.RadioDetail);
    }

    public void OpenAlbum(string id)
    {
        SelectedAlbumID = id;
        NavigateToDetail(Page.AlbumDetail);
    }

    public void OpenArtist(string id)
    {
        SelectedArtistID = id;
        NavigateToDetail(Page.ArtistDetail);
    }

    public void OpenComments(Song song)
    {
        CommentSong = song;
        NavigateToDetail(Page.SongComments);
    }

    public List<Song> LikedSongs => _likedSongs;

    public int LikesVersion => _likesVersion;

    public List<Playlist> UserPlaylists => _userPlaylists;

    public bool IsLoadingUserPlaylists
    {
        get => _isLoadingUserPlaylists;
        private set => SetProperty(ref _isLoadingUserPlaylists, value);
    }

    public bool NeedsReLogin
    {
        get => _needsReLogin;
        set => SetProperty(ref _needsReLogin, value);
    }

    public bool IsLoginPresented
    {
        get => _isLoginPresented;
        set => SetProperty(ref _isLoginPresented, value);
    }

    public string DataContextKey => $"{IsLoggedIn}-{Account?.UserID ?? "guest"}-{_accountGeneration}";

    private void NotifyDataContextChanged()
    {
        OnPropertyChanged(nameof(DataContextKey));
        OnPropertyChanged(nameof(CurrentAccountGeneration));
    }

    public bool CanPerformWrite => IsLoggedIn && !NeedsReLogin;

    public int CurrentAccountGeneration => _accountGeneration;

    private void HandleSessionExpired()
    {
        if (!IsLoggedIn && Account is null) return;
        CTLog.Security.Warn("登录状态已失效，请重新登录");
        ClearSession(clearLikedCache: false);
        NeedsReLogin = true;
        IsLoginPresented = true;
    }

    // MARK: - 登录态

    public async Task RestoreLoginStateAsync()
    {
        if (IsLoggedIn) return;
        Account ??= PersistenceStore.Shared.LoadCachedAccount();
        PlayerController.Shared.SetAccountIsVIP(Account?.IsVIP ?? false);

        if (_likedSongs.Count == 0)
        {
            var cachedSongs = PersistenceStore.Shared.LoadCachedLikedSongs();
            var cachedIDs = PersistenceStore.Shared.LoadCachedLikedSongIDs();
            ApplyLikedSongs(cachedSongs, cachedIDs.Count > 0 ? cachedIDs : null);
        }

        var cookie = NeteaseProvider.LoadLoginCookie();
        if (string.IsNullOrEmpty(cookie))
        {
            ClearSession(clearLikedCache: false);
            return;
        }

        if (Account is not null)
        {
            IsLoggedIn = true;
        }

        try
        {
            var info = await _provider.FetchAccountInfoAsync().ConfigureAwait(true);
            if (info is not null)
            {
                ApplyAccount(info);
            }
            else
            {
                ClearSession(clearLikedCache: true);
                return;
            }
        }
        catch (Exception error)
        {
            CTLog.Security.Warn($"恢复登录态失败: {CTLog.Sanitize(error.Message)}");
            if (Account is null) IsLoggedIn = false;
        }

        if (IsLoggedIn)
        {
            await LoadLikedSongsAsync(force: true).ConfigureAwait(true);
            await LoadUserPlaylistsAsync().ConfigureAwait(true);
        }
    }

    public async Task DidLoginAsync(AccountInfo info)
    {
        ApplyAccount(info);
        _sessionOwner.ClearCache();
        _sessionOwner.ResetSessionGuard();
        await LoadLikedSongsAsync(force: true).ConfigureAwait(true);
        await LoadUserPlaylistsAsync().ConfigureAwait(true);
    }

    public async Task PerformLogoutAsync()
    {
        try
        {
            await _provider.LogoutAsync().ConfigureAwait(true);
        }
        catch
        {
        }
        _sessionOwner.ClearCache();
        ClearSession(clearLikedCache: true);
    }

    public void ApplyAccount(AccountInfo info)
    {
        Account = info;
        IsLoggedIn = true;
        _accountGeneration += 1;
        NeedsReLogin = false;
        NotifyDataContextChanged();
        PlayerController.Shared.SetAccountIsVIP(info.IsVIP);
        if (!string.IsNullOrEmpty(info.UserID))
        {
            CredentialStore.Shared.Save(info.UserID, CredentialKey.NeteaseUserID);
        }
        PersistenceStore.Shared.SaveCachedAccount(info);
    }

    private void ClearSession(bool clearLikedCache)
    {
        Account = null;
        IsLoggedIn = false;
        _likeWriteCooldownUntil = null;
        _likesWriteError = null;
        _likeRequestsInFlight.Clear();
        PlayerController.Shared.SetAccountIsVIP(false);
        _hasLoadedLikes = false;
        _hasLoadedLikedSongs = false;
        _likedIDs = new HashSet<string>();
        _likedSongs = new List<Song>();
        _likesVersion += 1;
        _accountGeneration += 1;
        _userPlaylistsToken = Guid.NewGuid();
        _userPlaylists = new List<Playlist>();
        IsLoadingUserPlaylists = false;
        NotifyDataContextChanged();
        PersistenceStore.Shared.ClearCachedAccount();
        if (clearLikedCache)
        {
            PersistenceStore.Shared.ClearCachedLikedSongs();
            PersistenceStore.Shared.ClearCachedUserPlaylists();
        }
    }

    // MARK: - 歌单写操作

    public async Task<Playlist?> CreatePlaylistAsync(string name, bool isPrivate)
    {
        if (!CanPerformWrite) return null;
        try
        {
            var created = await _sessionOwner.CreatePlaylistAsync(name, isPrivate).ConfigureAwait(true);
            _userPlaylists.Insert(0, created);
            OnPropertyChanged(nameof(UserPlaylists));
            PersistenceStore.Shared.SaveCachedUserPlaylists(_userPlaylists);
            return created;
        }
        catch (Exception error)
        {
            CTLog.General.Error($"创建歌单失败: {CTLog.Sanitize(error.Message)}");
            LastWriteError = error.CtUserMessage();
            return null;
        }
    }

    public async Task<bool> DeletePlaylistAsync(Playlist playlist)
    {
        if (!CanPerformWrite) return false;
        try
        {
            await _sessionOwner.DeletePlaylistAsync(playlist.Id).ConfigureAwait(true);
            _userPlaylists.RemoveAll(item => item.Id == playlist.Id);
            OnPropertyChanged(nameof(UserPlaylists));
            PersistenceStore.Shared.SaveCachedUserPlaylists(_userPlaylists);
            if (SelectedPlaylistID == playlist.Id) CurrentPage = Page.MyMusic;
            return true;
        }
        catch (Exception error)
        {
            CTLog.General.Error($"删除歌单失败: {CTLog.Sanitize(error.Message)}");
            LastWriteError = error.CtUserMessage();
            return false;
        }
    }

    public async Task<bool> RenamePlaylistAsync(Playlist playlist, string name)
    {
        if (!CanPerformWrite) return false;
        try
        {
            await _sessionOwner.UpdatePlaylistNameAsync(playlist.Id, name).ConfigureAwait(true);
            var index = _userPlaylists.FindIndex(item => item.Id == playlist.Id);
            if (index >= 0)
            {
                _userPlaylists[index].Name = name;
                OnPropertyChanged(nameof(UserPlaylists));
            }
            PersistenceStore.Shared.SaveCachedUserPlaylists(_userPlaylists);
            return true;
        }
        catch (Exception error)
        {
            CTLog.General.Error($"重命名歌单失败: {CTLog.Sanitize(error.Message)}");
            LastWriteError = error.CtUserMessage();
            return false;
        }
    }

    public async Task<bool> ModifyPlaylistAsync(Playlist playlist, IReadOnlyList<string> songIDs, bool add)
    {
        if (!CanPerformWrite || songIDs.Count == 0) return false;
        try
        {
            if (add)
            {
                await _sessionOwner.AddSongsToPlaylistAsync(playlist.Id, songIDs).ConfigureAwait(true);
            }
            else
            {
                await _sessionOwner.RemoveSongsFromPlaylistAsync(playlist.Id, songIDs).ConfigureAwait(true);
            }
            _sessionOwner.ClearCache();
            var index = _userPlaylists.FindIndex(item => item.Id == playlist.Id);
            if (index >= 0)
            {
                _userPlaylists[index].TrackCount = Math.Max(
                    0,
                    _userPlaylists[index].TrackCount + (add ? songIDs.Count : -songIDs.Count));
                OnPropertyChanged(nameof(UserPlaylists));
                PersistenceStore.Shared.SaveCachedUserPlaylists(_userPlaylists);
            }
            return true;
        }
        catch (Exception error)
        {
            CTLog.General.Error($"{(add ? "添加" : "移除")}歌曲失败: {CTLog.Sanitize(error.Message)}");
            LastWriteError = error.CtUserMessage();
            return false;
        }
    }

    public string? LastWriteError
    {
        get => _lastWriteError;
        set => SetProperty(ref _lastWriteError, value);
    }

    public void ClearWriteError() => LastWriteError = null;

    public void PublishWriteError(Exception error)
    {
        CTLog.General.Error($"写操作失败: {CTLog.Sanitize(error.Message)}");
        LastWriteError = error.CtUserMessage();
    }

    // MARK: - 收藏

    public bool IsLiked(string songID) => _likedIDs.Contains(songID);

    public async Task LoadLikedSongsAsync(bool force = false)
    {
        if (!IsLoggedIn) return;
        if (_hasLoadedLikes && _hasLoadedLikedSongs && !force) return;
        var generation = _accountGeneration;
        var dataContext = DataContextKey;
        try
        {
            var ids = await _provider.FetchLikedSongIDsAsync().ConfigureAwait(true);
            if (generation != _accountGeneration || dataContext != DataContextKey) return;
            ApplyLikedSongs(PersistenceStore.Shared.LoadCachedLikedSongs(), ids);
            PersistenceStore.Shared.SaveCachedLikedSongIDs(ids);
            _hasLoadedLikes = true;

            var songs = await _provider.FetchLikedSongsAsync().ConfigureAwait(true);
            if (generation != _accountGeneration || dataContext != DataContextKey) return;
            ApplyLikedSongs(songs, ids);
            PersistenceStore.Shared.SaveCachedLikedSongs(songs);
            _hasLoadedLikedSongs = true;
        }
        catch (Exception error)
        {
            CTLog.General.Error($"加载喜欢的歌曲失败: {CTLog.Sanitize(error.Message)}");
        }
    }

    public async Task LoadUserPlaylistsAsync()
    {
        var token = Guid.NewGuid();
        _userPlaylistsToken = token;
        var generation = _accountGeneration;
        if (!IsLoggedIn)
        {
            _userPlaylists = new List<Playlist>();
            OnPropertyChanged(nameof(UserPlaylists));
            return;
        }
        if (_userPlaylists.Count == 0)
        {
            var cached = PersistenceStore.Shared.LoadCachedUserPlaylists();
            if (_userPlaylistsToken != token) return;
            _userPlaylists = cached;
            OnPropertyChanged(nameof(UserPlaylists));
        }
        IsLoadingUserPlaylists = _userPlaylists.Count == 0;
        try
        {
            var loaded = await _provider.FetchUserPlaylistsAsync().ConfigureAwait(true);
            if (_userPlaylistsToken != token || generation != _accountGeneration) return;
            _userPlaylists = loaded;
            OnPropertyChanged(nameof(UserPlaylists));
            PersistenceStore.Shared.SaveCachedUserPlaylists(loaded);
        }
        catch (Exception error)
        {
            if (_userPlaylistsToken != token) return;
            CTLog.General.Error($"加载歌单失败: {CTLog.Sanitize(error.Message)}");
        }
        finally
        {
            if (_userPlaylistsToken == token) IsLoadingUserPlaylists = false;
        }
    }

    public async Task<bool> ToggleLikeAsync(Song song)
    {
        if (song.Source != SongSource.Netease || !IsLoggedIn) return false;
        if (IsLikeWriteCoolingDown) return _likedIDs.Contains(song.Id);
        if (_likeRequestsInFlight.Contains(song.Id)) return _likedIDs.Contains(song.Id);
        _likeRequestsInFlight.Add(song.Id);

        var wasLiked = _likedIDs.Contains(song.Id);
        UpdateLikedID(song.Id, !wasLiked);
        var optimistic = _likedSongs.Where(item => item.Id != song.Id).ToList();
        if (!wasLiked) optimistic.Insert(0, song);
        _likedSongs = optimistic;
        OnPropertyChanged(nameof(LikedSongs));

        try
        {
            await _provider.LikeSongAsync(song.Id, !wasLiked).ConfigureAwait(true);
            PersistenceStore.Shared.SaveCachedLikedSongIDs(_likedIDs.ToList());
            PersistenceStore.Shared.SaveCachedLikedSongs(_likedSongs);
            LikesWriteError = null;
            return !wasLiked;
        }
        catch (Exception error)
        {
            CTLog.General.Error($"收藏操作失败: {CTLog.Sanitize(error.Message)}");
            UpdateLikedID(song.Id, wasLiked);
            var reverted = _likedSongs.Where(item => item.Id != song.Id).ToList();
            if (wasLiked) reverted.Insert(0, song);
            _likedSongs = reverted;
            OnPropertyChanged(nameof(LikedSongs));
            PersistenceStore.Shared.SaveCachedLikedSongIDs(_likedIDs.ToList());
            PersistenceStore.Shared.SaveCachedLikedSongs(_likedSongs);
            LastWriteError = error.CtUserMessage();
            if (IsWriteThrottled(error))
            {
                EnterLikeWriteCooldown();
            }
            return wasLiked;
        }
        finally
        {
            _likeRequestsInFlight.Remove(song.Id);
        }
    }

    public string? LikesWriteError
    {
        get => _likesWriteError;
        private set => SetProperty(ref _likesWriteError, value);
    }

    public int LikeCooldownRemaining
    {
        get
        {
            if (_likeWriteCooldownUntil is not { } until) return 0;
            var remaining = (until - DateTimeOffset.Now).TotalSeconds;
            return remaining > 0 ? (int)Math.Ceiling(remaining) : 0;
        }
    }

    public bool IsLikeWriteCoolingDown => LikeCooldownRemaining > 0;

    private void EnterLikeWriteCooldown()
    {
        _likeWriteCooldownUntil = DateTimeOffset.Now.AddSeconds(ClearToneConstants.LikeWriteCooldownSeconds);
        LikesWriteError = "已触发限流，请稍后再试";
    }

    public static bool IsWriteThrottled(Exception error)
    {
        if (error is not MusicException music) return false;
        return music.Kind switch
        {
            MusicErrorKind.ApiError => music.Code == 405 || music.Code == 524,
            MusicErrorKind.RateLimited => true,
            _ => false,
        };
    }

    private void ApplyLikedSongs(IReadOnlyList<Song> songs, IReadOnlyList<string>? ids)
    {
        _likedSongs = songs.ToList();
        _likedIDs = ids is null
            ? songs.Select(song => song.Id).ToHashSet()
            : ids.ToHashSet();
        _likesVersion += 1;
        OnPropertyChanged(nameof(LikedSongs));
        OnPropertyChanged(nameof(LikesVersion));
    }

    private void UpdateLikedID(string songID, bool isLiked)
    {
        if (isLiked) _likedIDs.Add(songID);
        else _likedIDs.Remove(songID);
        _likesVersion += 1;
        OnPropertyChanged(nameof(LikesVersion));
    }
}
