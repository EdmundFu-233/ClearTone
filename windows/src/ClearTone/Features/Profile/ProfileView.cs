using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using ClearTone.Controls;
using ClearTone.Core.Models;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Playback;
using ClearTone.Providers.Netease;
using ClearTone.Shell;
using AlbumModel = ClearTone.Core.Models.Album;
using ArtistModel = ClearTone.Core.Models.Artist;
using PlaylistModel = ClearTone.Core.Models.Playlist;

namespace ClearTone.Features.Profile;

[PageView(Page.Profile)]
public sealed class ProfileView : UserControl, IPageView
{
    private static AppState App => AppState.Shared;
    private static PlayerController Player => PlayerController.Shared;
    private static NeteaseProvider Provider => NeteaseProvider.Shared;

    private readonly Grid _root = new();
    private readonly StackPanel _body = new() { Spacing = CTSpacing.Xl };
    private readonly TextBlock _subtitle = new() { Classes = { "secondary" } };

    private UserLevelInfo? _level;
    private bool _loadingLevel;
    private string? _levelError;

    private SignInResult? _signIn;
    private bool _signingIn;

    private List<ListenRecord> _records = new();
    private bool _loadingRecords;
    private string? _recordsError;
    private bool _recordsWeekly;

    private Dictionary<string, int>? _counts;
    private bool _loadingCounts;
    private string? _countsError;

    private List<ArtistModel> _subArtists = new();
    private List<AlbumModel> _subAlbums = new();
    private List<RadioStation> _subRadios = new();
    private List<PlaylistModel> _subPlaylists = new();
    private bool _loadingSubscriptions;
    private string? _subscriptionsError;

    private Guid _loadToken;
    private bool _isAttached;
    private string _lastDataContextKey = "";

    public ProfileView()
    {
        var titleStack = new StackPanel { Spacing = CTSpacing.Xs };
        titleStack.Children.Add(new TextBlock { Text = "我的", Classes = { "pageTitle" } });
        titleStack.Children.Add(_subtitle);
        titleStack.Margin = new Thickness(CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Lg);

        var scroll = new ScrollViewer
        {
            Content = _body,
            Padding = new Thickness(CTSpacing.Xl, 0, CTSpacing.Xl, CTSpacing.Xl),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };

        _root.RowDefinitions = new RowDefinitions("Auto,*");
        _root.Background = CTColors.BackgroundBrush;
        _root.Children.Add(titleStack);
        Grid.SetRow(scroll, 1);
        _root.Children.Add(scroll);
        Content = _root;

        App.PropertyChanged += OnAppPropertyChanged;
        _lastDataContextKey = App.DataContextKey;
        _subtitle.Text = "听歌等级与记录。";
        Render();
    }

    public void OnActivated()
    {
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        _isAttached = true;
        _ = LoadAllAsync();
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
            case nameof(AppState.DataContextKey):
            case nameof(AppState.Account):
            case nameof(AppState.IsLoggedIn):
            case nameof(AppState.CurrentAccountGeneration):
                RefreshForDataContext();
                break;
            case nameof(AppState.NeedsReLogin):
                RefreshForDataContext();
                Post(Render);
                break;
        }
    }

    private void RefreshForDataContext()
    {
        var key = App.DataContextKey;
        if (key == _lastDataContextKey) return;
        _lastDataContextKey = key;
        if (_isAttached) Post(() => _ = LoadAllAsync());
    }

    private void ResetState()
    {
        _level = null;
        _loadingLevel = false;
        _levelError = null;
        _signIn = null;
        _signingIn = false;
        _records = new List<ListenRecord>();
        _loadingRecords = false;
        _recordsError = null;
        _counts = null;
        _loadingCounts = false;
        _countsError = null;
        _subArtists = new List<ArtistModel>();
        _subAlbums = new List<AlbumModel>();
        _subRadios = new List<RadioStation>();
        _subPlaylists = new List<PlaylistModel>();
        _loadingSubscriptions = false;
        _subscriptionsError = null;
    }

    private async Task LoadAllAsync()
    {
        if (!App.CanPerformWrite)
        {
            Render();
            return;
        }
        var token = Guid.NewGuid();
        _loadToken = token;
        ResetState();
        Render();
        await Task.WhenAll(
            LoadLevelAsync(token),
            LoadCountsAsync(token),
            LoadRecordsAsync(token),
            LoadSubscriptionsAsync(token)).ConfigureAwait(true);
    }

    private async Task LoadLevelAsync(Guid token)
    {
        _loadingLevel = _level is null;
        _levelError = null;
        Post(Render);
        try
        {
            var loaded = await Provider.FetchUserLevelAsync().ConfigureAwait(true);
            if (_loadToken != token) return;
            _level = loaded;
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            _levelError = error.CtUserMessage();
        }
        finally
        {
            if (_loadToken == token)
            {
                _loadingLevel = false;
                Post(Render);
            }
        }
    }

    private async Task LoadCountsAsync(Guid token)
    {
        _loadingCounts = _counts is null;
        _countsError = null;
        Post(Render);
        try
        {
            var loaded = await Provider.FetchUserCountsAsync().ConfigureAwait(true);
            if (_loadToken != token) return;
            _counts = loaded;
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            _countsError = error.CtUserMessage();
        }
        finally
        {
            if (_loadToken == token)
            {
                _loadingCounts = false;
                Post(Render);
            }
        }
    }

    private async Task LoadRecordsAsync(Guid token)
    {
        _loadingRecords = _records.Count == 0;
        _recordsError = null;
        Post(Render);
        try
        {
            var loaded = await Provider.FetchListenRecordsAsync(_recordsWeekly).ConfigureAwait(true);
            if (_loadToken != token) return;
            _records = loaded;
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            _recordsError = error.CtUserMessage();
        }
        finally
        {
            if (_loadToken == token)
            {
                _loadingRecords = false;
                Post(Render);
            }
        }
    }

    private async Task LoadSubscriptionsAsync(Guid token)
    {
        _loadingSubscriptions = true;
        _subscriptionsError = null;
        Post(Render);

        var artistsTask = Provider.FetchSubscribedArtistsAsync();
        var albumsTask = Provider.FetchSubscribedAlbumsAsync();
        var radiosTask = Provider.FetchSubscribedRadiosAsync();
        var playlistsTask = Provider.FetchSubscribedPlaylistsAsync();

        List<ArtistModel>? artists = null;
        List<AlbumModel>? albums = null;
        List<RadioStation>? radios = null;
        List<PlaylistModel>? playlists = null;
        string? error = null;

        try
        {
            artists = await artistsTask.ConfigureAwait(true);
        }
        catch (Exception exception)
        {
            error ??= exception.CtUserMessage();
        }
        try
        {
            albums = await albumsTask.ConfigureAwait(true);
        }
        catch (Exception exception)
        {
            error ??= exception.CtUserMessage();
        }
        try
        {
            radios = await radiosTask.ConfigureAwait(true);
        }
        catch (Exception exception)
        {
            error ??= exception.CtUserMessage();
        }
        try
        {
            playlists = await playlistsTask.ConfigureAwait(true);
        }
        catch (Exception exception)
        {
            error ??= exception.CtUserMessage();
        }

        if (_loadToken != token) return;
        _subArtists = artists ?? new List<ArtistModel>();
        _subAlbums = albums ?? new List<AlbumModel>();
        _subRadios = radios ?? new List<RadioStation>();
        _subPlaylists = playlists ?? new List<PlaylistModel>();
        _subscriptionsError = error;
        _loadingSubscriptions = false;
        Post(Render);
    }

    private void Render()
    {
        _subtitle.Text = App.IsLoggedIn
            ? (App.Account?.Nickname ?? "已登录")
            : "听歌等级与记录。";
        _body.Children.Clear();

        if (!App.CanPerformWrite)
        {
            _body.Children.Add(BuildLoginRequired());
            return;
        }

        _body.Children.Add(BuildAccountCard());
        _body.Children.Add(BuildLevelCard());
        _body.Children.Add(BuildSignInCard());
        _body.Children.Add(BuildCountsCard());
        _body.Children.Add(BuildRecordsSection());
        _body.Children.Add(BuildSubscriptionsSection());
    }

    private Control BuildLoginRequired()
    {
        var panel = new StackPanel
        {
            Spacing = CTSpacing.Md,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 60, 0, 60),
        };
        panel.Children.Add(new TextBlock
        {
            Text = "登录后查看听歌等级与记录",
            Foreground = CTColors.TextSecondaryBrush,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        var login = new Button
        {
            Content = "去登录",
            Classes = { "accent" },
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        login.Click += (_, _) => App.IsLoginPresented = true;
        panel.Children.Add(login);
        return panel;
    }

    private Control BuildAccountCard()
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        grid.Children.Add(new CoverImage
        {
            Width = 64,
            Height = 64,
            CornerRadius = new CornerRadius(32),
            CoverUrl = App.Account?.AvatarURL,
            DecodeWidth = 128,
        });

        var info = new StackPanel
        {
            Spacing = 2,
            Margin = new Thickness(CTSpacing.Lg, 0, CTSpacing.Md, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(info, 1);
        var nameRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Sm };
        nameRow.Children.Add(new TextBlock
        {
            Text = App.Account?.Nickname ?? "已登录",
            FontWeight = FontWeight.SemiBold,
        });
        if (App.Account?.IsVIP == true)
        {
            nameRow.Children.Add(new TextBlock
            {
                Text = "VIP",
                Foreground = CTColors.AccentBrush,
                Classes = { "secondary" },
            });
        }
        info.Children.Add(nameRow);
        info.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(App.Account?.UserID) ? "" : $"ID：{App.Account!.UserID}",
            Classes = { "secondary" },
        });
        grid.Children.Add(info);

        var logout = new Button
        {
            Content = "退出登录",
            VerticalAlignment = VerticalAlignment.Center,
        };
        logout.Click += (_, _) => _ = LogoutAsync();
        Grid.SetColumn(logout, 2);
        grid.Children.Add(logout);

        return Card(grid);
    }

    private async Task LogoutAsync()
    {
        await App.PerformLogoutAsync().ConfigureAwait(true);
        ResetState();
        _lastDataContextKey = App.DataContextKey;
        Render();
    }

    private Control BuildLevelCard()
    {
        var panel = new StackPanel { Spacing = CTSpacing.Md };

        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        header.Children.Add(new TextBlock { Text = "听歌等级", Classes = { "sectionTitle" } });
        if (_loadingLevel)
        {
            var progress = new ProgressBar
            {
                IsIndeterminate = true,
                Width = 80,
                Height = 4,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(progress, 1);
            header.Children.Add(progress);
        }
        else if (_level is { } level)
        {
            var label = new TextBlock
            {
                Text = $"Lv.{level.Level}",
                FontSize = 22,
                Foreground = CTColors.AccentBrush,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(label, 1);
            header.Children.Add(label);
        }
        panel.Children.Add(header);

        if (_level is { } info)
        {
            panel.Children.Add(new ProgressBar
            {
                Minimum = 0,
                Maximum = 1,
                Value = Math.Clamp(info.ProgressFraction, 0, 1),
                Height = 4,
            });

            var stats = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,Auto,*,Auto") };
            stats.Children.Add(StatBlock("累计听歌", $"{info.ListenSongs} 首"));
            var days = StatBlock("累计天数", $"{info.ListenDays} 天");
            Grid.SetColumn(days, 1);
            days.Margin = new Thickness(CTSpacing.Xl, 0, 0, 0);
            stats.Children.Add(days);
            var hint = new TextBlock
            {
                Text = info.NextLevelNeedLoginDays > 0 ? $"再听 {info.RemainingLoginDays} 天升级" : "已是最高等级",
                Classes = { "secondary" },
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(hint, 3);
            stats.Children.Add(hint);
            panel.Children.Add(stats);
        }
        else if (_levelError is { } error)
        {
            panel.Children.Add(new TextBlock
            {
                Text = error,
                Classes = { "secondary" },
                TextWrapping = TextWrapping.Wrap,
            });
            panel.Children.Add(UIComponents.LinkButton("重试", () => _ = LoadLevelAsync(_loadToken)));
        }

        return Card(panel);
    }

    private static Control StatBlock(string label, string value)
    {
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(new TextBlock { Text = value, FontWeight = FontWeight.Medium });
        panel.Children.Add(new TextBlock { Text = label, Classes = { "secondary" } });
        return panel;
    }

    private Control BuildSignInCard()
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        grid.Children.Add(new TextBlock
        {
            Text = "\uE8FB",
            FontFamily = new FontFamily("Segoe MDL2 Assets, Segoe Fluent Icons"),
            FontSize = 28,
            Foreground = CTColors.AccentBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var info = new StackPanel
        {
            Spacing = 3,
            Margin = new Thickness(CTSpacing.Lg, 0, CTSpacing.Md, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(info, 1);
        info.Children.Add(new TextBlock { Text = "每日打卡", FontWeight = FontWeight.Medium });
        info.Children.Add(new TextBlock
        {
            Text = SignInSubtitle(),
            Classes = { "secondary" },
        });
        grid.Children.Add(info);

        var action = BuildSignInButton();
        Grid.SetColumn(action, 2);
        action.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(action);

        return Card(grid);
    }

    private string SignInSubtitle() => _signIn switch
    {
        SignInResult.Success success => $"打卡成功，获得 {success.Point} 成长值",
        SignInResult.AlreadySigned => "今天已经打过卡了",
        SignInResult.Failed failed => failed.Reason,
        _ => "连续登录可提升听歌等级",
    };

    private Control BuildSignInButton()
    {
        switch (_signIn)
        {
            case SignInResult.Success:
                return new TextBlock
                {
                    Text = "已打卡",
                    Foreground = CTColors.AccentBrush,
                    VerticalAlignment = VerticalAlignment.Center,
                };
            case SignInResult.AlreadySigned:
                var reload = new Button { Content = "重新加载" };
                reload.Click += (_, _) => _ = LoadLevelAsync(_loadToken);
                return reload;
            default:
                var button = new Button
                {
                    Content = _signingIn ? "打卡中…" : "打卡",
                    Classes = { "accent" },
                    IsEnabled = !_signingIn && App.CanPerformWrite,
                };
                button.Click += (_, _) => _ = SignInAsync();
                return button;
        }
    }

    private async Task SignInAsync()
    {
        if (_signingIn || _signIn is not null) return;
        _signingIn = true;
        Render();
        try
        {
            var result = await Provider.DailySignInAsync().ConfigureAwait(true);
            _signIn = result;
            if (result.IsSuccess) await LoadLevelAsync(_loadToken).ConfigureAwait(true);
        }
        catch (Exception error)
        {
            _signIn = new SignInResult.Failed(error.CtUserMessage());
        }
        _signingIn = false;
        Render();
    }

    private Control BuildCountsCard()
    {
        var panel = new StackPanel { Spacing = CTSpacing.Md };
        panel.Children.Add(new TextBlock { Text = "收藏数量", Classes = { "sectionTitle" } });

        if (_counts is { } counts)
        {
            var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
            foreach (var pair in counts)
            {
                var chip = new StackPanel
                {
                    Spacing = 2,
                    Width = 96,
                    Margin = new Thickness(0, 0, CTSpacing.Md, CTSpacing.Sm),
                };
                chip.Children.Add(new TextBlock { Text = pair.Value.ToString(), FontWeight = FontWeight.SemiBold });
                chip.Children.Add(new TextBlock { Text = pair.Key, Classes = { "secondary" } });
                wrap.Children.Add(chip);
            }
            panel.Children.Add(wrap);
        }
        else if (_loadingCounts)
        {
            panel.Children.Add(new ProgressBar { IsIndeterminate = true, Width = 160, Height = 4 });
        }
        else if (_countsError is { } error)
        {
            panel.Children.Add(new TextBlock
            {
                Text = error,
                Classes = { "secondary" },
                TextWrapping = TextWrapping.Wrap,
            });
            panel.Children.Add(UIComponents.LinkButton("重试", () => _ = LoadCountsAsync(_loadToken)));
        }

        return Card(panel);
    }

    private Control BuildRecordsSection()
    {
        var section = new StackPanel { Spacing = CTSpacing.Md };

        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        header.Children.Add(new TextBlock { Text = "听歌排行", Classes = { "sectionTitle" } });

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Sm,
            VerticalAlignment = VerticalAlignment.Center,
        };
        actions.Children.Add(RangeButton("全部", weekly: false));
        actions.Children.Add(RangeButton("最近一周", weekly: true));
        if (_records.Count > 0)
        {
            var playAll = new Button { Content = "播放全部" };
            playAll.Click += (_, _) => Player.PlaySongs(_records.Select(record => record.Song).ToList(), 0);
            actions.Children.Add(playAll);
        }
        Grid.SetColumn(actions, 1);
        header.Children.Add(actions);
        section.Children.Add(header);

        if (_loadingRecords && _records.Count == 0)
        {
            section.Children.Add(UIComponents.StatusPanel("加载中…", showSpinner: true));
        }
        else if (_recordsError is { } error)
        {
            section.Children.Add(UIComponents.ErrorPanel(error, () => _ = LoadRecordsAsync(_loadToken)));
        }
        else if (_records.Count == 0)
        {
            section.Children.Add(UIComponents.StatusPanel("暂无内容"));
        }
        else
        {
            section.Children.Add(BuildRecordList());
        }

        return section;
    }

    private Button RangeButton(string text, bool weekly)
    {
        var button = new Button { Content = text };
        if (_recordsWeekly == weekly) button.Classes.Add("accent");
        button.Click += (_, _) => _ = ChangeRangeAsync(weekly);
        return button;
    }

    private async Task ChangeRangeAsync(bool weekly)
    {
        if (_recordsWeekly == weekly) return;
        _recordsWeekly = weekly;
        _records = new List<ListenRecord>();
        Render();
        await LoadRecordsAsync(_loadToken).ConfigureAwait(true);
    }

    private Control BuildRecordList()
    {
        var records = _records;
        var list = new ListBox { Background = Brushes.Transparent, BorderThickness = new Thickness(0) };
        list.ItemsSource = records.ToList();
        list.ItemTemplate = new FuncDataTemplate<ListenRecord>((record, _) =>
        {
            if (record is null) return new Control();
            var index = records.FindIndex(item => item.Song.Id == record.Song.Id);
            var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("48,*"), VerticalAlignment = VerticalAlignment.Center };
            grid.Children.Add(new TextBlock
            {
                Text = record.PlayCount.ToString(),
                Classes = { "secondary" },
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, CTSpacing.Sm, 0),
            });
            var song = UIComponents.SongRowContent(
                record.Song,
                Math.Max(0, index),
                App.IsLiked(record.Song.Id),
                Player.CurrentSong?.Id == record.Song.Id);
            Grid.SetColumn(song, 1);
            grid.Children.Add(song);
            return new Border { Padding = new Thickness(0, 4), Child = grid };
        });
        list.DoubleTapped += (_, _) =>
        {
            if (list.SelectedItem is not ListenRecord record) return;
            var songs = records.Select(item => item.Song).ToList();
            if (songs.Count == 0) return;
            Player.PlaySongs(songs, Math.Max(0, songs.FindIndex(song => song.Id == record.Song.Id)));
        };
        return list;
    }

    private Control BuildSubscriptionsSection()
    {
        var section = new StackPanel { Spacing = CTSpacing.Lg };
        section.Children.Add(new TextBlock { Text = "我的收藏", Classes = { "sectionTitle" } });

        var empty = _subArtists.Count == 0 && _subAlbums.Count == 0 && _subRadios.Count == 0 && _subPlaylists.Count == 0;
        if (_loadingSubscriptions && empty)
        {
            section.Children.Add(UIComponents.StatusPanel("加载中…", showSpinner: true));
            return section;
        }
        if (empty)
        {
            section.Children.Add(_subscriptionsError is { } error
                ? UIComponents.ErrorPanel(error, () => _ = LoadSubscriptionsAsync(_loadToken))
                : UIComponents.StatusPanel("暂无内容"));
            return section;
        }

        if (_subArtists.Count > 0) section.Children.Add(BuildSubscriptionGroup("关注的歌手", ArtistCards()));
        if (_subAlbums.Count > 0) section.Children.Add(BuildSubscriptionGroup("收藏的专辑", AlbumCards()));
        if (_subRadios.Count > 0) section.Children.Add(BuildSubscriptionGroup("收藏的电台", RadioCards()));
        if (_subPlaylists.Count > 0) section.Children.Add(BuildSubscriptionGroup("收藏的歌单", PlaylistCards()));

        if (_subscriptionsError is { } partialError)
        {
            section.Children.Add(new TextBlock
            {
                Text = partialError,
                Classes = { "secondary" },
                TextWrapping = TextWrapping.Wrap,
            });
        }
        return section;
    }

    private static Control BuildSubscriptionGroup(string title, Control content)
    {
        var panel = new StackPanel { Spacing = CTSpacing.Md };
        panel.Children.Add(new TextBlock { Text = title, FontWeight = FontWeight.Medium });
        panel.Children.Add(content);
        return Card(panel);
    }

    private Control ArtistCards()
    {
        var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var artist in _subArtists)
        {
            var card = UIComponents.ArtistCard(artist, item => App.OpenArtist(item.Id));
            card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
            wrap.Children.Add(card);
        }
        return wrap;
    }

    private Control AlbumCards()
    {
        var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var album in _subAlbums)
        {
            var card = UIComponents.AlbumCard(album, item => App.OpenAlbum(item.Id));
            card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
            wrap.Children.Add(card);
        }
        return wrap;
    }

    private Control RadioCards()
    {
        var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var radio in _subRadios)
        {
            var stack = new StackPanel { Spacing = 6, Width = 160 };
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
            stack.Children.Add(new TextBlock
            {
                Text = $"{radio.ProgramCount} 节目",
                Classes = { "secondary" },
            });
            var button = new Button
            {
                Content = stack,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Padding = new Thickness(0),
                Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg),
            };
            var id = radio.Id;
            button.Click += (_, _) => App.OpenRadio(id);
            wrap.Children.Add(button);
        }
        return wrap;
    }

    private Control PlaylistCards()
    {
        var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var playlist in _subPlaylists)
        {
            var card = UIComponents.PlaylistCard(playlist, item => App.OpenPlaylist(item.Id));
            card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
            wrap.Children.Add(card);
        }
        return wrap;
    }

    private static Control Card(Control content) => new Border
    {
        Background = CTColors.PanelBrush,
        CornerRadius = new CornerRadius(CTRadius.Large),
        Padding = new Thickness(CTSpacing.Lg),
        Child = content,
    };

    private static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }
}
