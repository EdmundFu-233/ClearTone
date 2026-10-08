using System.Collections.ObjectModel;
using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using ClearTone.Controls;
using ClearTone.Core.Artist;
using ClearTone.Core.Models;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Playback;
using ClearTone.Providers.Netease;
using ClearTone.Shell;
using AlbumModel = ClearTone.Core.Models.Album;
using ArtistModel = ClearTone.Core.Models.Artist;

namespace ClearTone.Features.Artist;

[PageView(Page.ArtistDetail)]
public sealed class ArtistDetailView : UserControl, IPageView
{
    private enum ArtistTab
    {
        Hot,
        Songs,
        Albums,
        MVs,
        About,
    }

    private static AppState App => AppState.Shared;
    private static PlayerController Player => PlayerController.Shared;

    private readonly Grid _root = new();
    private readonly ContentControl _headerHost = new();
    private readonly ContentControl _tabsHost = new();
    private readonly ContentControl _contentHost = new();
    private readonly ContentControl _statusHost = new();

    private readonly ListBox _hotList;
    private readonly ObservableCollection<Song> _hotSongs = new();

    private readonly Grid _songsPanel = new();
    private readonly TextBlock _songsHeader = new();
    private readonly ListBox _songsList;
    private readonly ContentControl _songsFooter = new();
    private readonly ObservableCollection<Song> _songs = new();

    private readonly Grid _albumsPanel = new();
    private readonly ItemsControl _albumsList;
    private readonly ContentControl _albumsFooter = new();
    private readonly ObservableCollection<AlbumModel> _albums = new();

    private readonly Grid _mvsPanel = new();
    private readonly ListBox _mvsList;
    private readonly ContentControl _mvsFooter = new();
    private readonly ObservableCollection<ArtistMV> _mvs = new();

    private readonly StackPanel _aboutBody = new() { Spacing = CTSpacing.Xl };

    private readonly ArtistProfileSession _session = new("", NeteaseProvider.Shared);

    private ArtistTab _tab = ArtistTab.Hot;
    private string? _activeArtistID;
    private Guid _loadToken;
    private bool _isAttached;
    private bool _isSubscribing;
    private string _lastDataContextKey = "";
    private string? _actionError;

    public ArtistDetailView()
    {
        _hotList = CreateSongList(() => _session.HotSongs);
        _hotList.ItemsSource = _hotSongs;

        _songsList = CreateSongList(() => _session.Songs);
        _songsList.ItemsSource = _songs;

        _mvsList = new ListBox { Background = Brushes.Transparent, BorderThickness = new Thickness(0) };
        _mvsList.ItemsSource = _mvs;
        _mvsList.ItemTemplate = new FuncDataTemplate<ArtistMV>((mv, _) => mv is null ? new Control() : BuildMvRow(mv));

        _albumsList = new ItemsControl { ItemsSource = _albums };
        _albumsList.ItemsPanel = new FuncTemplate<Panel?>(() => new WrapPanel { Orientation = Orientation.Horizontal });
        _albumsList.ItemTemplate = new FuncDataTemplate<AlbumModel>((album, _) => album is null ? new Control() : BuildAlbumCard(album));

        _songsHeader.Classes.Add("secondary");
        _songsPanel.RowDefinitions = new RowDefinitions("Auto,*,Auto");
        _songsPanel.Children.Add(_songsHeader);
        Grid.SetRow(_songsList, 1);
        _songsPanel.Children.Add(_songsList);
        Grid.SetRow(_songsFooter, 2);
        _songsPanel.Children.Add(_songsFooter);

        _albumsPanel.RowDefinitions = new RowDefinitions("*,Auto");
        var albumsScroll = new ScrollViewer
        {
            Content = _albumsList,
            Padding = new Thickness(CTSpacing.Xl, 0, CTSpacing.Xl, 0),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        _albumsPanel.Children.Add(albumsScroll);
        Grid.SetRow(_albumsFooter, 1);
        _albumsPanel.Children.Add(_albumsFooter);

        _mvsPanel.RowDefinitions = new RowDefinitions("*,Auto");
        _mvsPanel.Children.Add(_mvsList);
        Grid.SetRow(_mvsFooter, 1);
        _mvsPanel.Children.Add(_mvsFooter);

        _headerHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _tabsHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _contentHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _contentHost.VerticalContentAlignment = VerticalAlignment.Stretch;
        _statusHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _statusHost.VerticalContentAlignment = VerticalAlignment.Stretch;

        _root.RowDefinitions = new RowDefinitions("Auto,Auto,*");
        _root.Background = CTColors.BackgroundBrush;
        _root.Children.Add(_headerHost);
        Grid.SetRow(_tabsHost, 1);
        _root.Children.Add(_tabsHost);
        Grid.SetRow(_contentHost, 2);
        _root.Children.Add(_contentHost);
        Grid.SetRowSpan(_statusHost, 3);
        _root.Children.Add(_statusHost);
        _statusHost.IsVisible = false;
        Content = _root;

        App.PropertyChanged += OnAppPropertyChanged;
        Player.PropertyChanged += OnPlayerPropertyChanged;
        _lastDataContextKey = App.DataContextKey;
        Render();
    }

    public void OnActivated()
    {
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        _isAttached = true;
        _ = LoadAsync();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        _isAttached = false;
    }

    private void OnAppPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppState.SelectedArtistID):
                if (_isAttached) Post(() => _ = LoadAsync());
                break;
            case nameof(AppState.DataContextKey):
            case nameof(AppState.Account):
            case nameof(AppState.IsLoggedIn):
            case nameof(AppState.CurrentAccountGeneration):
                RefreshForDataContext();
                break;
            case nameof(AppState.LikesVersion):
                Post(() =>
                {
                    if (_isAttached) RefreshListViews();
                });
                break;
        }
    }

    private void OnPlayerPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PlayerController.CurrentSong))
        {
            Post(() =>
            {
                if (_isAttached) RefreshListViews();
            });
        }
    }

    private void RefreshForDataContext()
    {
        var key = App.DataContextKey;
        if (key == _lastDataContextKey) return;
        _lastDataContextKey = key;
        if (_isAttached) Post(() => _ = LoadAsync());
    }

    private async Task LoadAsync()
    {
        var id = App.SelectedArtistID;
        if (string.IsNullOrEmpty(id))
        {
            _activeArtistID = null;
            _session.SwitchTo("");
            ResetCollections();
            Render();
            return;
        }

        var dataContextChanged = _lastDataContextKey != App.DataContextKey;
        _lastDataContextKey = App.DataContextKey;
        if (_activeArtistID != id)
        {
            _activeArtistID = id;
            _tab = ArtistTab.Hot;
            _actionError = null;
            _session.SwitchTo(id);
            ResetCollections();
        }
        else if (dataContextChanged)
        {
            _session.ReloadForDataContext();
            ResetCollections();
        }

        var token = Guid.NewGuid();
        _loadToken = token;
        Render();

        try
        {
            await _session.LoadProfileAsync().ConfigureAwait(true);
            if (_loadToken != token) return;
            Render();
            await _session.LoadHighlightsAsync().ConfigureAwait(true);
            if (_loadToken != token) return;
            SyncCollection(_hotSongs, _session.HotSongs, song => song.Id);
            Render();
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            _actionError = error.CtUserMessage();
            Render();
        }
    }

    private void ResetCollections()
    {
        _hotSongs.Clear();
        _songs.Clear();
        _albums.Clear();
        _mvs.Clear();
    }

    private void Render()
    {
        if (_session.Profile is null)
        {
            if (_session.IsLoadingProfile)
            {
                ShowStatus(UIComponents.StatusPanel("加载中…", showSpinner: true));
            }
            else if (_session.ProfileError is { } error)
            {
                ShowStatus(UIComponents.ErrorPanel(error, () => _ = LoadAsync()));
            }
            else
            {
                ShowStatus(UIComponents.StatusPanel("暂无内容"));
            }
            return;
        }

        _statusHost.IsVisible = false;
        _headerHost.IsVisible = true;
        _tabsHost.IsVisible = true;
        _contentHost.IsVisible = true;
        RenderHeader();
        RenderTabs();
        RenderTabContent();
    }

    private void ShowStatus(Control status)
    {
        _statusHost.Content = status;
        _statusHost.IsVisible = true;
        _headerHost.IsVisible = false;
        _tabsHost.IsVisible = false;
        _contentHost.IsVisible = false;
    }

    private void RenderHeader()
    {
        var profile = _session.Profile;
        if (profile is null)
        {
            _headerHost.Content = null;
            return;
        }

        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*"),
            Margin = new Thickness(CTSpacing.Xl),
        };
        grid.Children.Add(new CoverImage
        {
            Width = 140,
            Height = 140,
            CornerRadius = new CornerRadius(70),
            CoverUrl = profile.Artist.AvatarURL,
            DecodeWidth = 280,
            VerticalAlignment = VerticalAlignment.Top,
        });

        var info = new StackPanel { Spacing = CTSpacing.Sm, Margin = new Thickness(CTSpacing.Lg, 0, 0, 0) };
        Grid.SetColumn(info, 1);
        info.Children.Add(new TextBlock
        {
            Text = profile.Artist.DisplayNameWithAlias,
            Classes = { "pageTitle" },
            TextWrapping = TextWrapping.Wrap,
        });

        var stats = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Lg };
        stats.Children.Add(StatText("单曲", profile.SongCount));
        stats.Children.Add(StatText("专辑", profile.AlbumCount));
        stats.Children.Add(StatText("MV", profile.MvCount));
        info.Children.Add(stats);

        if (!string.IsNullOrEmpty(profile.BriefDescription))
        {
            info.Children.Add(new TextBlock
            {
                Text = profile.BriefDescription,
                Classes = { "secondary" },
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 520,
            });
        }

        if (profile.IdentifyTags.Count > 0)
        {
            var tags = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Xs };
            foreach (var tag in profile.IdentifyTags)
            {
                tags.Children.Add(new Border
                {
                    CornerRadius = new CornerRadius(10),
                    Background = CTColors.OverlayBrush,
                    Padding = new Thickness(CTSpacing.Sm, 2),
                    Child = new TextBlock { Text = tag, Classes = { "secondary" } },
                });
            }
            info.Children.Add(tags);
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Md };
        var playHot = new Button
        {
            Content = "播放热门",
            Classes = { "accent" },
            IsEnabled = _hotSongs.Count > 0,
        };
        playHot.Click += (_, _) => Player.PlaySongs(_hotSongs.ToList(), 0);
        actions.Children.Add(playHot);

        var playAll = new Button
        {
            Content = "播放全部",
            IsEnabled = _songs.Count > 0 && !_session.CanLoadMoreSongs,
        };
        playAll.Click += (_, _) => Player.PlaySongs(_songs.ToList(), 0);
        actions.Children.Add(playAll);

        if (App.CanPerformWrite)
        {
            var followed = _session.IsFollowed == true;
            var subscribe = new Button
            {
                Content = followed ? "取消关注" : "关注歌手",
                IsEnabled = !_isSubscribing,
            };
            subscribe.Click += (_, _) => _ = ToggleFollowAsync(!followed);
            actions.Children.Add(subscribe);
        }
        info.Children.Add(actions);

        if (_actionError is { } actionError)
        {
            info.Children.Add(new TextBlock
            {
                Text = actionError,
                Foreground = CTColors.AccentBrush,
                TextWrapping = TextWrapping.Wrap,
            });
        }

        grid.Children.Add(info);
        _headerHost.Content = grid;
    }

    private static Control StatText(string label, int value)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3 };
        panel.Children.Add(new TextBlock { Text = value.ToString(), FontWeight = FontWeight.SemiBold });
        panel.Children.Add(new TextBlock { Text = label, Classes = { "secondary" } });
        return panel;
    }

    private void RenderTabs()
    {
        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Sm,
            Margin = new Thickness(CTSpacing.Xl, 0, CTSpacing.Xl, CTSpacing.Md),
        };
        foreach (var tab in Enum.GetValues<ArtistTab>())
        {
            var button = new Button { Content = TabName(tab) };
            if (tab == _tab) button.Classes.Add("accent");
            var captured = tab;
            button.Click += (_, _) => _ = SwitchTabAsync(captured);
            panel.Children.Add(button);
        }
        _tabsHost.Content = panel;
    }

    private static string TabName(ArtistTab tab) => tab switch
    {
        ArtistTab.Hot => "热门",
        ArtistTab.Songs => "全部歌曲",
        ArtistTab.Albums => "专辑",
        ArtistTab.MVs => "MV",
        _ => "歌手详情",
    };

    private async Task SwitchTabAsync(ArtistTab tab)
    {
        if (_tab == tab) return;
        _tab = tab;
        RenderTabs();
        RenderTabContent();
        await LoadTabIfNeededAsync(tab).ConfigureAwait(true);
    }

    private async Task LoadTabIfNeededAsync(ArtistTab tab)
    {
        try
        {
            switch (tab)
            {
                case ArtistTab.Hot:
                    if (_session.HotSongs.Count == 0) await _session.LoadHighlightsAsync().ConfigureAwait(true);
                    SyncCollection(_hotSongs, _session.HotSongs, song => song.Id);
                    break;
                case ArtistTab.Songs:
                    if (_session.Songs.Count == 0) await _session.LoadSongsAsync().ConfigureAwait(true);
                    SyncCollection(_songs, _session.Songs, song => song.Id);
                    break;
                case ArtistTab.Albums:
                    if (_session.Albums.Count == 0) await _session.LoadAlbumsAsync().ConfigureAwait(true);
                    SyncCollection(_albums, _session.Albums, album => album.Id);
                    break;
                case ArtistTab.MVs:
                    if (_session.MVs.Count == 0) await _session.LoadMVsAsync().ConfigureAwait(true);
                    SyncCollection(_mvs, _session.MVs, mv => mv.Id);
                    break;
                case ArtistTab.About:
                    if (_session.Intro is null) await _session.LoadIntroAsync().ConfigureAwait(true);
                    break;
            }
        }
        catch (Exception error)
        {
            _actionError = error.CtUserMessage();
        }
        if (_tab == tab) Render();
    }

    private void RenderTabContent()
    {
        switch (_tab)
        {
            case ArtistTab.Hot:
                RenderHot();
                break;
            case ArtistTab.Songs:
                RenderSongs();
                break;
            case ArtistTab.Albums:
                RenderAlbums();
                break;
            case ArtistTab.MVs:
                RenderMVs();
                break;
            default:
                RenderAbout();
                break;
        }
    }

    private void RenderHot()
    {
        if (_hotSongs.Count == 0 && _session.IsLoadingHighlights)
        {
            ShowContent(UIComponents.StatusPanel("加载中…", showSpinner: true));
            return;
        }
        if (_hotSongs.Count == 0)
        {
            ShowContent(UIComponents.StatusPanel("暂无内容"));
            return;
        }
        ShowContent(_hotList);
    }

    private void RenderSongs()
    {
        if (_songs.Count == 0)
        {
            if (_session.SongsError is { } error)
            {
                ShowContent(UIComponents.ErrorPanel(error, () => _ = LoadTabIfNeededAsync(ArtistTab.Songs)));
            }
            else if (_session.IsLoadingSongs)
            {
                ShowContent(UIComponents.StatusPanel("加载中…", showSpinner: true));
            }
            else
            {
                ShowContent(UIComponents.StatusPanel("暂无内容"));
            }
            return;
        }

        _songsHeader.Text = _session.SongsTotal > _songs.Count
            ? $"已加载 {_songs.Count} / {_session.SongsTotal} 首"
            : $"共 {_songs.Count} 首";
        _songsFooter.Content = BuildPaginationFooter(
            _session.IsLoadingMoreSongs,
            _session.CanLoadMoreSongs,
            _session.SongsError,
            () => _ = LoadMoreSongsAsync());
        ShowContent(_songsPanel);
    }

    private void RenderAlbums()
    {
        if (_albums.Count == 0)
        {
            if (_session.AlbumsError is { } error)
            {
                ShowContent(UIComponents.ErrorPanel(error, () => _ = LoadTabIfNeededAsync(ArtistTab.Albums)));
            }
            else if (_session.IsLoadingAlbums)
            {
                ShowContent(UIComponents.StatusPanel("加载中…", showSpinner: true));
            }
            else
            {
                ShowContent(UIComponents.StatusPanel("暂无内容"));
            }
            return;
        }

        _albumsFooter.Content = BuildPaginationFooter(
            _session.IsLoadingMoreAlbums,
            _session.CanLoadMoreAlbums,
            _session.AlbumsError,
            () => _ = LoadMoreAlbumsAsync());
        ShowContent(_albumsPanel);
    }

    private void RenderMVs()
    {
        if (_mvs.Count == 0)
        {
            if (_session.MVsError is { } error)
            {
                ShowContent(UIComponents.ErrorPanel(error, () => _ = LoadTabIfNeededAsync(ArtistTab.MVs)));
            }
            else if (_session.IsLoadingMVs)
            {
                ShowContent(UIComponents.StatusPanel("加载中…", showSpinner: true));
            }
            else
            {
                ShowContent(UIComponents.StatusPanel("暂无内容"));
            }
            return;
        }

        _mvsFooter.Content = BuildPaginationFooter(
            _session.IsLoadingMoreMVs,
            _session.CanLoadMoreMVs,
            _session.MVsError,
            () => _ = LoadMoreMVsAsync());
        ShowContent(_mvsPanel);
    }

    private void RenderAbout()
    {
        _aboutBody.Children.Clear();
        if (_session.Intro is { } intro)
        {
            if (!string.IsNullOrEmpty(intro.BriefDescription))
            {
                _aboutBody.Children.Add(BuildAboutSection("简介", new TextBlock
                {
                    Text = intro.BriefDescription,
                    Classes = { "secondary" },
                    TextWrapping = TextWrapping.Wrap,
                }));
            }
            foreach (var section in intro.Sections)
            {
                _aboutBody.Children.Add(BuildAboutSection(
                    string.IsNullOrEmpty(section.Title) ? null : section.Title,
                    new TextBlock
                    {
                        Text = section.Body,
                        Classes = { "secondary" },
                        TextWrapping = TextWrapping.Wrap,
                    }));
            }
        }
        else if (_session.IsLoadingIntro)
        {
            _aboutBody.Children.Add(UIComponents.StatusPanel("加载中…", showSpinner: true));
        }
        else if (_session.IntroError is { } introError)
        {
            _aboutBody.Children.Add(UIComponents.ErrorPanel(introError, () => _ = LoadTabIfNeededAsync(ArtistTab.About)));
        }
        else
        {
            _aboutBody.Children.Add(UIComponents.StatusPanel("暂无内容"));
        }

        if (_session.SimilarArtists.Count > 0)
        {
            var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
            foreach (var similar in _session.SimilarArtists)
            {
                var card = UIComponents.ArtistCard(similar, item => App.OpenArtist(item.Id));
                card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
                wrap.Children.Add(card);
            }
            _aboutBody.Children.Add(BuildAboutSection("相似歌手", wrap));
        }

        ShowContent(new ScrollViewer
        {
            Content = _aboutBody,
            Padding = new Thickness(CTSpacing.Xl, 0, CTSpacing.Xl, CTSpacing.Xl),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        });
    }

    private static Control BuildAboutSection(string? title, Control content)
    {
        var panel = new StackPanel { Spacing = CTSpacing.Sm };
        if (!string.IsNullOrEmpty(title))
        {
            panel.Children.Add(new TextBlock { Text = title, Classes = { "sectionTitle" } });
        }
        panel.Children.Add(content);
        return panel;
    }

    private void ShowContent(Control content)
    {
        if (!ReferenceEquals(_contentHost.Content, content)) _contentHost.Content = content;
    }

    private async Task LoadMoreSongsAsync()
    {
        try
        {
            await _session.LoadMoreSongsAsync().ConfigureAwait(true);
        }
        catch (Exception error)
        {
            _actionError = error.CtUserMessage();
        }
        SyncCollection(_songs, _session.Songs, song => song.Id);
        RenderSongs();
        RenderHeader();
    }

    private async Task LoadMoreAlbumsAsync()
    {
        try
        {
            await _session.LoadMoreAlbumsAsync().ConfigureAwait(true);
        }
        catch (Exception error)
        {
            _actionError = error.CtUserMessage();
        }
        SyncCollection(_albums, _session.Albums, album => album.Id);
        RenderAlbums();
    }

    private async Task LoadMoreMVsAsync()
    {
        try
        {
            await _session.LoadMoreMVsAsync().ConfigureAwait(true);
        }
        catch (Exception error)
        {
            _actionError = error.CtUserMessage();
        }
        SyncCollection(_mvs, _session.MVs, mv => mv.Id);
        RenderMVs();
    }

    private async Task ToggleFollowAsync(bool follow)
    {
        if (_activeArtistID is null || _isSubscribing) return;
        var token = _loadToken;
        _isSubscribing = true;
        RenderHeader();
        try
        {
            await App.Social.SubscribeArtistAsync(_activeArtistID, follow).ConfigureAwait(true);
            if (_loadToken != token) return;
            _session.SetFollowed(follow);
            _actionError = null;
        }
        catch (Exception error)
        {
            App.PublishWriteError(error);
            if (_loadToken != token) return;
            _actionError = error.CtUserMessage();
        }
        finally
        {
            _isSubscribing = false;
            if (_loadToken == token) RenderHeader();
        }
    }

    private Control BuildPaginationFooter(bool isLoading, bool canLoadMore, string? error, Action retry)
    {
        var panel = new StackPanel
        {
            Spacing = CTSpacing.Sm,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, CTSpacing.Md),
        };
        if (isLoading)
        {
            panel.Children.Add(new ProgressBar
            {
                IsIndeterminate = true,
                Width = 160,
                Height = 4,
                HorizontalAlignment = HorizontalAlignment.Center,
            });
        }
        else if (error is not null && canLoadMore)
        {
            panel.Children.Add(new TextBlock
            {
                Text = error,
                Classes = { "secondary" },
                TextWrapping = TextWrapping.Wrap,
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            panel.Children.Add(UIComponents.LinkButton("重试", retry));
        }
        else if (canLoadMore)
        {
            var button = new Button { Content = "加载更多", HorizontalAlignment = HorizontalAlignment.Center };
            button.Click += (_, _) => retry();
            panel.Children.Add(button);
        }
        else if (error is not null)
        {
            panel.Children.Add(new TextBlock
            {
                Text = error,
                Classes = { "secondary" },
                HorizontalAlignment = HorizontalAlignment.Center,
            });
        }
        return panel;
    }

    private ListBox CreateSongList(Func<IReadOnlyList<Song>> source)
    {
        var list = new ListBox { Background = Brushes.Transparent, BorderThickness = new Thickness(0) };
        list.ItemTemplate = new FuncDataTemplate<Song>((song, _) =>
        {
            if (song is null) return new Control();
            var songs = source();
            var index = songs.ToList().FindIndex(item => item.Id == song.Id);
            return UIComponents.SongRowContent(
                song,
                Math.Max(0, index),
                App.IsLiked(song.Id),
                Player.CurrentSong?.Id == song.Id);
        });
        list.DoubleTapped += (_, _) =>
        {
            if (list.SelectedItem is not Song song) return;
            var songs = source().ToList();
            if (songs.Count == 0) return;
            Player.PlaySongs(songs, Math.Max(0, songs.FindIndex(item => item.Id == song.Id)));
        };
        return list;
    }

    private Button BuildAlbumCard(AlbumModel album)
    {
        var card = UIComponents.AlbumCard(album, item => App.OpenAlbum(item.Id), 140);
        card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
        return card;
    }

    private static Control BuildMvRow(ArtistMV mv)
    {
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*"),
            Margin = new Thickness(0, CTSpacing.Xs),
        };
        grid.Children.Add(new CoverImage
        {
            Width = 64,
            Height = 64,
            CornerRadius = new CornerRadius(CTRadius.Small),
            CoverUrl = mv.CoverURL,
            DecodeWidth = 128,
        });

        var info = new StackPanel
        {
            Spacing = 2,
            Margin = new Thickness(CTSpacing.Md, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        info.Children.Add(new TextBlock
        {
            Text = mv.Name,
            FontWeight = FontWeight.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });

        var sub = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Sm };
        if (!string.IsNullOrEmpty(mv.ArtistName))
        {
            sub.Children.Add(new TextBlock { Text = mv.ArtistName, Classes = { "secondary" } });
        }
        if (mv.PlayCount > 0)
        {
            sub.Children.Add(new TextBlock { Text = $"播放 {CTFormatting.Count(mv.PlayCount)}", Classes = { "secondary" } });
        }
        if (mv.Duration > 0)
        {
            sub.Children.Add(new TextBlock { Text = CTFormatting.Time(mv.Duration), Classes = { "secondary" } });
        }
        info.Children.Add(sub);

        Grid.SetColumn(info, 1);
        grid.Children.Add(info);
        return new Border { Padding = new Thickness(6, 6), Child = grid };
    }

    private static void SyncCollection<T>(
        ObservableCollection<T> target,
        IReadOnlyList<T> source,
        Func<T, string> keySelector)
    {
        var keys = target.Select(keySelector).ToHashSet(StringComparer.Ordinal);
        if (target.Count > source.Count)
        {
            target.Clear();
            keys.Clear();
        }
        foreach (var item in source)
        {
            if (keys.Add(keySelector(item))) target.Add(item);
        }
    }

    private void RefreshListViews()
    {
        _hotList.ItemsSource = null;
        _hotList.ItemsSource = _hotSongs;
        _songsList.ItemsSource = null;
        _songsList.ItemsSource = _songs;
    }

    private static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }
}
