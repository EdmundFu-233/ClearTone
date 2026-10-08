using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using ClearTone.Controls;
using ClearTone.Core.Logging;
using ClearTone.Core.Models;
using ClearTone.DesignSystem;
using ClearTone.Features.Radio;
using ClearTone.Features.Shared;
using ClearTone.Playback;
using ClearTone.Providers.Netease;
using ClearTone.Shell;
using AlbumModel = ClearTone.Core.Models.Album;
using ArtistModel = ClearTone.Core.Models.Artist;
using PlaylistModel = ClearTone.Core.Models.Playlist;

namespace ClearTone.Features.Discover;

[PageView(Page.Discover)]
public sealed class DiscoverView : UserControl, IPageView
{
    private static AppState App => AppState.Shared;
    private static PlayerController Player => PlayerController.Shared;
    private static NeteaseProvider Provider => NeteaseProvider.Shared;

    private readonly ContentControl _dailyHost = new();
    private readonly ContentControl _playlistsHost = new();
    private readonly ContentControl _dailyPlaylistsHost = new();
    private readonly ContentControl _radiosHost = new();
    private readonly ContentControl _newSongsHost = new();
    private readonly ContentControl _newAlbumsHost = new();
    private readonly Button _dailyPlayAll;
    private readonly Button _newSongsPlayAll;

    private List<Song> _dailySongs = new();
    private readonly HashSet<string> _dailyDislikesInFlight = new();
    private bool _dailyLoading;
    private string? _dailyError;
    private List<PlaylistModel> _playlists = new();
    private bool _playlistsLoading;
    private string? _playlistsError;
    private List<PlaylistModel> _dailyPlaylists = new();
    private bool _dailyPlaylistsLoading;
    private string? _dailyPlaylistsError;
    private List<RadioStation> _radios = new();
    private bool _radiosLoading;
    private string? _radiosError;
    private List<Song> _newSongs = new();
    private bool _newSongsLoading;
    private string? _newSongsError;
    private List<AlbumModel> _newAlbums = new();
    private bool _newAlbumsLoading;
    private string? _newAlbumsError;

    private Guid _loadToken;
    private bool _hasLoaded;
    private string _lastDataContextKey = "";

    public DiscoverView()
    {
        _dailyPlayAll = new Button { Content = "播放全部", IsEnabled = false };
        _dailyPlayAll.Click += (_, _) =>
        {
            if (_dailySongs.Count > 0) Player.PlaySongs(_dailySongs, 0);
        };
        _newSongsPlayAll = new Button { Content = "播放全部", IsEnabled = false };
        _newSongsPlayAll.Click += (_, _) =>
        {
            if (_newSongs.Count > 0) Player.PlaySongs(_newSongs, 0);
        };

        var titleStack = new StackPanel { Spacing = CTSpacing.Xs };
        titleStack.Children.Add(new TextBlock { Text = "发现音乐", Classes = { "pageTitle" } });
        titleStack.Children.Add(new TextBlock { Text = "为今天，找到合适的旋律。", Classes = { "secondary" } });
        titleStack.Margin = new Thickness(CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Xl, 0);

        var body = new StackPanel { Spacing = CTSpacing.Xl };
        body.Children.Add(BuildSection("每日推荐", _dailyHost, _dailyPlayAll));
        body.Children.Add(BuildSection("推荐歌单", _playlistsHost));
        body.Children.Add(BuildSection("每日推荐歌单", _dailyPlaylistsHost));
        body.Children.Add(BuildSection("推荐电台", _radiosHost));
        body.Children.Add(BuildSection("新歌速递", _newSongsHost, _newSongsPlayAll));
        body.Children.Add(BuildSection("新专辑", _newAlbumsHost));

        var scroll = new ScrollViewer
        {
            Content = body,
            Padding = new Thickness(CTSpacing.Xl, CTSpacing.Lg, CTSpacing.Xl, CTSpacing.Xl),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };

        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*"), Background = CTColors.BackgroundBrush };
        root.Children.Add(titleStack);
        Grid.SetRow(scroll, 1);
        root.Children.Add(scroll);
        Content = root;

        App.PropertyChanged += OnAppPropertyChanged;
        _lastDataContextKey = App.DataContextKey;
        RenderAll();
    }

    public void OnActivated()
    {
        if (_hasLoaded) return;
        _hasLoaded = true;
        _ = LoadAllAsync();
    }

    private void OnAppPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(AppState.DataContextKey)) Post(RefreshForDataContext);
    }

    private void RefreshForDataContext()
    {
        var key = App.DataContextKey;
        if (key == _lastDataContextKey) return;
        _lastDataContextKey = key;
        _hasLoaded = true;
        _ = LoadAllAsync();
    }

    private static StackPanel BuildSection(string title, ContentControl host, Control? trailing = null)
    {
        host.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        var section = new StackPanel { Spacing = CTSpacing.Md };
        section.Children.Add(UIComponents.HeaderRow(title, trailing));
        section.Children.Add(host);
        return section;
    }

    private void RenderAll()
    {
        RenderDaily();
        RenderPlaylists();
        RenderDailyPlaylists();
        RenderRadios();
        RenderNewSongs();
        RenderNewAlbums();
    }

    private async Task LoadAllAsync()
    {
        var token = Guid.NewGuid();
        _loadToken = token;
        await Task.WhenAll(
            LoadDailySongsAsync(token),
            LoadPlaylistsAsync(token),
            LoadDailyPlaylistsAsync(token),
            LoadRadiosAsync(token),
            LoadNewSongsAsync(token),
            LoadNewAlbumsAsync(token));
    }

    private async Task LoadDailySongsAsync(Guid token)
    {
        _dailyLoading = true;
        _dailyError = null;
        RenderDaily();
        if (!App.IsLoggedIn)
        {
            _dailySongs = new List<Song>();
            _dailyLoading = false;
            RenderDaily();
            return;
        }
        try
        {
            var loaded = await Provider.FetchDailyRecommendSongsAsync();
            if (_loadToken != token) return;
            _dailySongs = loaded;
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            _dailySongs = new List<Song>();
            _dailyError = error.CtUserMessage();
        }
        if (_loadToken != token) return;
        _dailyLoading = false;
        RenderDaily();
    }

    private async Task DislikeDailyAsync(Song song)
    {
        if (!App.CanPerformWrite) return;
        if (!_dailyDislikesInFlight.Add(song.Id)) return;
        var token = _loadToken;
        RenderDaily();
        try
        {
            var replacement = await Provider.DislikeDailyRecommendAsync(song.Id);
            if (_loadToken != token) return;
            var index = _dailySongs.FindIndex(item => item.Id == song.Id);
            if (index < 0) return;
            if (replacement is null)
            {
                _dailySongs.RemoveAt(index);
            }
            else
            {
                _dailySongs[index] = replacement;
            }
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            CTLog.General.Error($"反馈不喜欢失败: {CTLog.Sanitize(error.Message)}");
        }
        finally
        {
            _dailyDislikesInFlight.Remove(song.Id);
            if (_loadToken == token) RenderDaily();
        }
    }

    private async Task LoadPlaylistsAsync(Guid token)
    {
        _playlistsLoading = true;
        _playlistsError = null;
        RenderPlaylists();
        try
        {
            var loaded = await Provider.FetchRecommendPlaylistsAsync();
            if (_loadToken != token) return;
            _playlists = loaded;
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            _playlists = new List<PlaylistModel>();
            _playlistsError = error.CtUserMessage();
        }
        if (_loadToken != token) return;
        _playlistsLoading = false;
        RenderPlaylists();
    }

    private async Task LoadDailyPlaylistsAsync(Guid token)
    {
        _dailyPlaylistsLoading = true;
        _dailyPlaylistsError = null;
        RenderDailyPlaylists();
        if (!App.IsLoggedIn)
        {
            _dailyPlaylists = new List<PlaylistModel>();
            _dailyPlaylistsLoading = false;
            RenderDailyPlaylists();
            return;
        }
        try
        {
            var loaded = await Provider.FetchDailyRecommendPlaylistsAsync();
            if (_loadToken != token) return;
            _dailyPlaylists = loaded;
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            _dailyPlaylists = new List<PlaylistModel>();
            _dailyPlaylistsError = error.CtUserMessage();
        }
        if (_loadToken != token) return;
        _dailyPlaylistsLoading = false;
        RenderDailyPlaylists();
    }

    private async Task LoadRadiosAsync(Guid token)
    {
        _radiosLoading = true;
        _radiosError = null;
        RenderRadios();
        try
        {
            var loaded = await Provider.FetchRecommendedRadiosAsync(30);
            if (_loadToken != token) return;
            if (loaded.Count == 0)
            {
                loaded = await Provider.FetchHotRadiosAsync(limit: 30);
                if (_loadToken != token) return;
            }
            _radios = loaded;
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            _radios = new List<RadioStation>();
            _radiosError = error.CtUserMessage();
        }
        if (_loadToken != token) return;
        _radiosLoading = false;
        RenderRadios();
    }

    private async Task LoadNewSongsAsync(Guid token)
    {
        _newSongsLoading = true;
        _newSongsError = null;
        RenderNewSongs();
        try
        {
            var loaded = await Provider.FetchNewSongsAsync(30);
            if (_loadToken != token) return;
            _newSongs = loaded;
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            _newSongs = new List<Song>();
            _newSongsError = error.CtUserMessage();
        }
        if (_loadToken != token) return;
        _newSongsLoading = false;
        RenderNewSongs();
    }

    private async Task LoadNewAlbumsAsync(Guid token)
    {
        _newAlbumsLoading = true;
        _newAlbumsError = null;
        RenderNewAlbums();
        try
        {
            var loaded = await Provider.FetchNewAlbumsAsync(30);
            if (_loadToken != token) return;
            _newAlbums = loaded;
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            _newAlbums = new List<AlbumModel>();
            _newAlbumsError = error.CtUserMessage();
        }
        if (_loadToken != token) return;
        _newAlbumsLoading = false;
        RenderNewAlbums();
    }

    private void RenderDaily()
    {
        _dailyPlayAll.IsEnabled = _dailySongs.Count > 0;
        _dailyPlayAll.Content = _dailySongs.Count > 0 ? $"播放全部 ({_dailySongs.Count})" : "播放全部";
        if (!App.IsLoggedIn)
        {
            _dailyHost.Content = UIComponents.StatusPanel("登录后查看每日推荐");
            return;
        }
        if (_dailyLoading && _dailySongs.Count == 0)
        {
            _dailyHost.Content = UIComponents.StatusPanel("加载中…", showSpinner: true);
            return;
        }
        if (_dailyError is { } error && _dailySongs.Count == 0)
        {
            _dailyHost.Content = UIComponents.ErrorPanel(error, () => _ = LoadDailySongsAsync(_loadToken));
            return;
        }
        if (_dailySongs.Count == 0)
        {
            _dailyHost.Content = UIComponents.StatusPanel("暂无每日推荐");
            return;
        }
        _dailyHost.Content = BuildSongStrip(_dailySongs, DislikeDailyAsync);
    }

    private void RenderPlaylists()
    {
        _playlistsHost.Content = BuildPlaylistGrid(_playlists, _playlistsLoading, _playlistsError, "暂无推荐歌单",
            () => _ = LoadPlaylistsAsync(_loadToken));
    }

    private void RenderDailyPlaylists()
    {
        if (!App.IsLoggedIn)
        {
            _dailyPlaylistsHost.Content = UIComponents.StatusPanel("登录后查看每日推荐歌单");
            return;
        }
        _dailyPlaylistsHost.Content = BuildPlaylistGrid(_dailyPlaylists, _dailyPlaylistsLoading, _dailyPlaylistsError,
            "暂无每日推荐歌单", () => _ = LoadDailyPlaylistsAsync(_loadToken));
    }

    private Control BuildPlaylistGrid(
        IReadOnlyList<PlaylistModel> playlists,
        bool isLoading,
        string? error,
        string emptyText,
        Action retry)
    {
        if (isLoading && playlists.Count == 0) return UIComponents.StatusPanel("加载中…", showSpinner: true);
        if (error is not null && playlists.Count == 0) return UIComponents.ErrorPanel(error, retry);
        if (playlists.Count == 0) return UIComponents.StatusPanel(emptyText);
        var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var playlist in playlists)
        {
            var card = UIComponents.PlaylistCard(playlist, item => App.OpenPlaylist(item.Id));
            card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
            wrap.Children.Add(card);
        }
        return wrap;
    }

    private void RenderRadios()
    {
        if (_radiosLoading && _radios.Count == 0)
        {
            _radiosHost.Content = UIComponents.StatusPanel("加载中…", showSpinner: true);
            return;
        }
        if (_radiosError is { } error && _radios.Count == 0)
        {
            _radiosHost.Content = UIComponents.ErrorPanel(error, () => _ = LoadRadiosAsync(_loadToken));
            return;
        }
        if (_radios.Count == 0)
        {
            _radiosHost.Content = UIComponents.StatusPanel("暂无推荐电台");
            return;
        }
        var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var radio in _radios)
        {
            var card = BuildRadioCard(radio);
            card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
            wrap.Children.Add(card);
        }
        _radiosHost.Content = wrap;
    }

    private void RenderNewSongs()
    {
        _newSongsPlayAll.IsEnabled = _newSongs.Count > 0;
        _newSongsPlayAll.Content = _newSongs.Count > 0 ? $"播放全部 ({_newSongs.Count})" : "播放全部";
        if (_newSongsLoading && _newSongs.Count == 0)
        {
            _newSongsHost.Content = UIComponents.StatusPanel("加载中…", showSpinner: true);
            return;
        }
        if (_newSongsError is { } error && _newSongs.Count == 0)
        {
            _newSongsHost.Content = UIComponents.ErrorPanel(error, () => _ = LoadNewSongsAsync(_loadToken));
            return;
        }
        if (_newSongs.Count == 0)
        {
            _newSongsHost.Content = UIComponents.StatusPanel("暂无新歌");
            return;
        }
        _newSongsHost.Content = BuildSongStrip(_newSongs);
    }

    private void RenderNewAlbums()
    {
        if (_newAlbumsLoading && _newAlbums.Count == 0)
        {
            _newAlbumsHost.Content = UIComponents.StatusPanel("加载中…", showSpinner: true);
            return;
        }
        if (_newAlbumsError is { } error && _newAlbums.Count == 0)
        {
            _newAlbumsHost.Content = UIComponents.ErrorPanel(error, () => _ = LoadNewAlbumsAsync(_loadToken));
            return;
        }
        if (_newAlbums.Count == 0)
        {
            _newAlbumsHost.Content = UIComponents.StatusPanel("暂无新专辑");
            return;
        }
        var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var album in _newAlbums)
        {
            var card = UIComponents.AlbumCard(album, item => App.OpenAlbum(item.Id));
            card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
            wrap.Children.Add(card);
        }
        _newAlbumsHost.Content = wrap;
    }

    private Control BuildSongStrip(IReadOnlyList<Song> songs, Func<Song, Task>? onDislike = null)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Md, Margin = new Thickness(0, 0, 0, CTSpacing.Sm) };
        foreach (var song in songs)
        {
            panel.Children.Add(BuildSongCard(song, onDislike));
        }
        return new ScrollViewer
        {
            Content = panel,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
    }

    private Control BuildSongCard(Song song, Func<Song, Task>? onDislike)
    {
        var stack = new StackPanel { Spacing = CTSpacing.Sm, Width = 150 };
        stack.Children.Add(new CoverImage
        {
            Width = 150,
            Height = 150,
            CornerRadius = new CornerRadius(CTRadius.Medium),
            CoverUrl = song.CoverURL,
            DecodeWidth = 300,
        });
        stack.Children.Add(new TextBlock
        {
            Text = song.Title,
            FontWeight = FontWeight.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 150,
        });
        stack.Children.Add(BuildArtistLinks(song.Artists));
        var meta = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Sm };
        meta.Children.Add(new TextBlock { Text = CTFormatting.Time(song.Duration), Classes = { "secondary" } });
        if (!song.IsPlayable)
        {
            meta.Children.Add(new TextBlock
            {
                Text = song.UnavailableReason ?? "不可播放",
                Classes = { "secondary" },
            });
        }
        if (onDislike is not null && song.Source == SongSource.Netease)
        {
            var dislike = new Button
            {
                Content = "✕",
                FontSize = 11,
                Padding = new Thickness(6, 1),
                MinWidth = 0,
                MinHeight = 0,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                IsEnabled = App.CanPerformWrite && !_dailyDislikesInFlight.Contains(song.Id),
                VerticalAlignment = VerticalAlignment.Center,
            };
            ToolTip.SetTip(dislike, "不喜欢这首歌");
            dislike.Click += (_, _) => _ = onDislike(song);
            meta.Children.Add(dislike);
        }
        stack.Children.Add(meta);

        var card = new Border
        {
            Child = stack,
            Padding = new Thickness(CTSpacing.Sm),
            CornerRadius = new CornerRadius(CTRadius.Medium),
            Background = Brushes.Transparent,
        };
        card.DoubleTapped += (_, _) =>
        {
            if (song.IsPlayable) Player.PlaySong(song);
        };
        return card;
    }

    private static Control BuildArtistLinks(IReadOnlyList<ArtistModel> artists)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
        if (artists.Count == 0)
        {
            row.Children.Add(new TextBlock { Text = "未知歌手", Classes = { "secondary" } });
            return row;
        }
        for (var index = 0; index < artists.Count; index++)
        {
            if (index > 0)
            {
                row.Children.Add(new TextBlock { Text = " / ", Classes = { "secondary" } });
            }
            var artist = artists[index];
            if (long.TryParse(artist.Id, out _))
            {
                row.Children.Add(UIComponents.LinkButton(artist.Name, () => App.OpenArtist(artist.Id)));
            }
            else
            {
                row.Children.Add(new TextBlock { Text = artist.Name, Classes = { "secondary" } });
            }
        }
        return row;
    }

    private static Control BuildRadioCard(RadioStation radio)
    {
        var stack = new StackPanel { Spacing = CTSpacing.Sm, Width = 160 };
        stack.Children.Add(new CoverImage
        {
            Width = 160,
            Height = 160,
            CornerRadius = new CornerRadius(CTRadius.Medium),
            CoverUrl = radio.CoverURL,
            DecodeWidth = 320,
        });
        stack.Children.Add(new TextBlock
        {
            Text = radio.Name,
            FontWeight = FontWeight.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 160,
        });
        var parts = new List<string>();
        if (!string.IsNullOrEmpty(radio.CreatorName)) parts.Add(radio.CreatorName);
        if (radio.ProgramCount > 0) parts.Add($"{radio.ProgramCount} 期");
        stack.Children.Add(new TextBlock
        {
            Text = parts.Count > 0 ? string.Join(" · ", parts) : "电台",
            Classes = { "secondary" },
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 160,
        });

        var button = new Button
        {
            Content = stack,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
        };
        button.Click += (_, _) =>
        {
            RadioView.PendingStationID = radio.Id;
            App.SwitchToTopLevel(Page.Radio);
        };
        return button;
    }

    private static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }
}
