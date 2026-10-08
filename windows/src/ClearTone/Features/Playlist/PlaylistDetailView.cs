using System.Collections.ObjectModel;
using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
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
using PlaylistModel = ClearTone.Core.Models.Playlist;

namespace ClearTone.Features.Playlist;

[PageView(Page.PlaylistDetail)]
public sealed class PlaylistDetailView : UserControl, IPageView
{
    private static AppState App => AppState.Shared;
    private static PlayerController Player => PlayerController.Shared;
    private static NeteaseProvider Provider => NeteaseProvider.Shared;

    private readonly Grid _root = new();
    private readonly ContentControl _headerHost = new();
    private readonly ContentControl _bodyHost = new();
    private readonly ContentControl _statusHost = new();
    private readonly ListBox _trackList = new();
    private readonly ObservableCollection<Song> _tracks = new();

    private PlaylistDetail? _detail;
    private string? _playlistID;
    private Guid _loadToken;
    private bool _isLoading;
    private bool _isAttached;
    private bool? _isSubscribed;
    private bool _isOwned;
    private string _lastDataContextKey = "";
    private string? _errorMessage;
    private CancellationTokenSource? _streamCts;

    public PlaylistDetailView()
    {
        _trackList.Background = Brushes.Transparent;
        _trackList.BorderThickness = new Thickness(0);
        _trackList.ItemsSource = _tracks;
        _trackList.ItemTemplate = new FuncDataTemplate<Song>((song, _) =>
            song is null ? new Control() : BuildTrackRow(song));
        _trackList.DoubleTapped += OnTrackDoubleTapped;

        _headerHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _bodyHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _bodyHost.VerticalContentAlignment = VerticalAlignment.Stretch;
        _statusHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _statusHost.VerticalContentAlignment = VerticalAlignment.Stretch;

        _root.RowDefinitions = new RowDefinitions("Auto,*");
        _root.Background = CTColors.BackgroundBrush;
        _root.Children.Add(_headerHost);
        Grid.SetRow(_bodyHost, 1);
        _root.Children.Add(_bodyHost);
        Grid.SetRowSpan(_statusHost, 2);
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
        _streamCts?.Cancel();
        _streamCts = null;
    }

    private void OnAppPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppState.SelectedPlaylistID):
                if (_isAttached) Post(() => _ = LoadAsync());
                break;
            case nameof(AppState.DataContextKey):
            case nameof(AppState.Account):
            case nameof(AppState.IsLoggedIn):
            case nameof(AppState.CurrentAccountGeneration):
                RefreshForDataContext();
                break;
            case nameof(AppState.UserPlaylists):
                Post(() =>
                {
                    _isOwned = IsOwned();
                    RenderHeader();
                    RefreshTrackRows();
                });
                break;
            case nameof(AppState.LikesVersion):
                Post(RefreshTrackRows);
                break;
        }
    }

    private void RefreshForDataContext()
    {
        var key = App.DataContextKey;
        if (key == _lastDataContextKey) return;
        _lastDataContextKey = key;
        if (_isAttached) Post(() => _ = LoadAsync());
    }

    private void OnPlayerPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PlayerController.CurrentSong))
        {
            Post(RefreshTrackRows);
        }
    }

    private async Task LoadAsync()
    {
        var id = App.SelectedPlaylistID;
        if (string.IsNullOrEmpty(id))
        {
            _playlistID = null;
            _detail = null;
            _isLoading = false;
            _errorMessage = null;
            _tracks.Clear();
            Render();
            return;
        }

        var token = Guid.NewGuid();
        _loadToken = token;
        _streamCts?.Cancel();
        _streamCts = null;
        _playlistID = id;
        _isLoading = true;
        _errorMessage = null;
        _detail = null;
        _isSubscribed = null;
        _tracks.Clear();
        Render();

        try
        {
            var cached = Provider.CachedPlaylistTracks(id);
            var loaded = await Provider.FetchPlaylistDetailAsync(id);
            if (_loadToken != token) return;

            if (cached is not null)
            {
                loaded.Tracks = cached;
                _detail = loaded;
                ReplaceTracks(cached);
                _isLoading = false;
                Render();
                return;
            }

            _detail = loaded;
            ReplaceTracks(loaded.Tracks);
            _isLoading = false;
            Render();

            if (loaded.TotalTrackCount <= loaded.Tracks.Count || loaded.TotalTrackCount <= 0) return;

            var cts = new CancellationTokenSource();
            _streamCts = cts;
            var seen = new HashSet<string>(loaded.Tracks.Select(song => song.Id));
            try
            {
                await foreach (var batch in Provider.StreamPlaylistTracksAsync(id, loaded.TotalTrackCount, ct: cts.Token))
                {
                    if (_loadToken != token) return;
                    foreach (var song in batch)
                    {
                        if (!seen.Add(song.Id)) continue;
                        _tracks.Add(song);
                    }
                    RenderHeader();
                }
            }
            catch (MusicException error) when (error.Kind == MusicErrorKind.Cancelled)
            {
            }
            catch (OperationCanceledException)
            {
            }
        }
        catch (MusicException error) when (error.Kind == MusicErrorKind.Cancelled)
        {
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            _errorMessage = error.CtUserMessage();
            _isLoading = false;
            Render();
        }
    }

    private void ReplaceTracks(IEnumerable<Song> songs)
    {
        _tracks.Clear();
        foreach (var song in songs)
        {
            _tracks.Add(song);
        }
    }

    private void RefreshTrackRows()
    {
        if (_detail is null) return;
        _trackList.ItemsSource = null;
        _trackList.ItemsSource = _tracks;
    }

    private bool IsOwned() =>
        _playlistID is not null && App.UserPlaylists.Any(playlist => playlist.Id == _playlistID);

    private void Render()
    {
        _isOwned = IsOwned();
        if (_isLoading && _detail is null)
        {
            ShowStatus(UIComponents.StatusPanel("加载中…", showSpinner: true));
            return;
        }
        if (_errorMessage is { } error)
        {
            ShowStatus(UIComponents.ErrorPanel(error, () => _ = LoadAsync()));
            return;
        }
        if (_detail is null)
        {
            ShowStatus(string.IsNullOrEmpty(App.SelectedPlaylistID)
                ? UIComponents.StatusPanel("歌单不存在")
                : UIComponents.StatusPanel("加载中…", showSpinner: true));
            return;
        }

        _statusHost.IsVisible = false;
        _headerHost.IsVisible = true;
        _bodyHost.IsVisible = true;
        RenderHeader();
        if (!ReferenceEquals(_bodyHost.Content, _trackList)) _bodyHost.Content = _trackList;
    }

    private void ShowStatus(Control status)
    {
        _statusHost.Content = status;
        _statusHost.IsVisible = true;
        _headerHost.IsVisible = false;
        _bodyHost.IsVisible = false;
    }

    private void RenderHeader()
    {
        if (_detail is null)
        {
            _headerHost.Content = null;
            return;
        }

        var playlist = _detail.Playlist;
        var isSubscribed = _isSubscribed ?? playlist.IsSubscribed;

        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*"),
            Margin = new Thickness(CTSpacing.Xl),
        };
        grid.Children.Add(new CoverImage
        {
            Width = 160,
            Height = 160,
            CornerRadius = new CornerRadius(CTRadius.Medium),
            CoverUrl = playlist.CoverURL,
            DecodeWidth = 320,
            VerticalAlignment = VerticalAlignment.Top,
        });

        var info = new StackPanel { Spacing = CTSpacing.Sm, Margin = new Thickness(CTSpacing.Lg, 0, 0, 0) };
        Grid.SetColumn(info, 1);
        info.Children.Add(new TextBlock
        {
            Text = playlist.Name,
            Classes = { "pageTitle" },
            TextWrapping = TextWrapping.Wrap,
        });
        if (!string.IsNullOrEmpty(playlist.CreatorName))
        {
            info.Children.Add(new TextBlock
            {
                Text = $"创建者：{playlist.CreatorName}",
                Classes = { "secondary" },
            });
        }

        var countRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Sm };
        countRow.Children.Add(new TextBlock
        {
            Text = $"{_detail.TotalTrackCount} 首歌曲",
            Classes = { "secondary" },
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (_tracks.Count < _detail.TotalTrackCount)
        {
            countRow.Children.Add(new ProgressBar
            {
                IsIndeterminate = true,
                Width = 60,
                Height = 4,
                VerticalAlignment = VerticalAlignment.Center,
            });
            countRow.Children.Add(new TextBlock
            {
                Text = $"已加载 {_tracks.Count} 首",
                Classes = { "secondary" },
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        info.Children.Add(countRow);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Md };
        var playAll = new Button
        {
            Content = "播放全部",
            Classes = { "accent" },
            IsEnabled = _tracks.Count > 0,
        };
        playAll.Click += (_, _) => Player.PlaySongs(_tracks.ToList(), 0);
        actions.Children.Add(playAll);

        var append = new Button { Content = "添加到队列", IsEnabled = _tracks.Count > 0 };
        append.Click += (_, _) => Player.AppendToQueue(_tracks.ToList());
        actions.Children.Add(append);

        if (App.CanPerformWrite)
        {
            var subscribe = new Button { Content = isSubscribed ? "取消收藏" : "收藏歌单" };
            subscribe.Click += (_, _) => _ = SubscribeAsync(!isSubscribed);
            actions.Children.Add(subscribe);
        }
        if (_isOwned)
        {
            var rename = new Button { Content = "重命名" };
            rename.Click += (_, _) => ShowRenameDialog(playlist);
            actions.Children.Add(rename);

            var delete = new Button { Content = "删除歌单" };
            delete.Click += (_, _) => ShowDeleteDialog(playlist);
            actions.Children.Add(delete);
        }
        info.Children.Add(actions);

        grid.Children.Add(info);
        _headerHost.Content = grid;
    }

    private async Task SubscribeAsync(bool subscribe)
    {
        if (_playlistID is null || _detail is null) return;
        var token = _loadToken;
        try
        {
            await Provider.SubscribePlaylistAsync(_playlistID, subscribe);
            if (_loadToken != token) return;
            _isSubscribed = subscribe;
            _detail.Playlist.IsSubscribed = subscribe;
            RenderHeader();
        }
        catch (Exception error)
        {
            App.PublishWriteError(error);
            if (_loadToken != token) return;
            _errorMessage = error.CtUserMessage();
            Render();
        }
    }

    private Control BuildTrackRow(Song song)
    {
        var index = _tracks.IndexOf(song);
        var content = UIComponents.SongRowContent(
            song,
            Math.Max(0, index),
            App.IsLiked(song.Id),
            Player.CurrentSong?.Id == song.Id);
        var menu = new ContextMenu();
        menu.Items.Add(MenuItem("立即播放", () => PlaySong(song)));
        menu.Items.Add(MenuItem("下一首播放", () => Player.InsertNext(song)));
        menu.Items.Add(MenuItem("添加到队列", () => Player.AppendToQueue(song)));
        menu.Items.Add(MenuItem("喜欢/取消喜欢", () => _ = App.ToggleLikeAsync(song)));
        if (_isOwned && song.Source == SongSource.Netease)
        {
            menu.Items.Add(MenuItem("从这个歌单移除", () => ShowRemoveDialog(song)));
        }
        content.ContextMenu = menu;
        return content;
    }

    private void OnTrackDoubleTapped(object? sender, TappedEventArgs e)
    {
        if (_trackList.SelectedItem is not Song song) return;
        PlaySong(song);
    }

    private void PlaySong(Song song)
    {
        if (!song.IsPlayable) return;
        var index = Math.Max(0, _tracks.IndexOf(song));
        Player.PlaySongs(_tracks.ToList(), index);
    }

    private void ShowRenameDialog(PlaylistModel playlist)
    {
        _ = ShowNameDialogAsync("重命名歌单", playlist.Name, async name =>
        {
            var ok = await App.RenamePlaylistAsync(playlist, name);
            if (ok)
            {
                playlist.Name = name;
                RenderHeader();
            }
            return ok;
        });
    }

    private void ShowDeleteDialog(PlaylistModel playlist)
    {
        _ = ShowConfirmDialogAsync("删除歌单", $"确定要删除「{playlist.Name}」吗？此操作不可撤销。", "删除",
            async () => await App.DeletePlaylistAsync(playlist));
    }

    private void ShowRemoveDialog(Song song)
    {
        _ = ShowConfirmDialogAsync("从歌单移除", $"确定要从这个歌单移除「{song.Title}」吗？", "移除", async () =>
        {
            if (_detail is null) return false;
            var token = _loadToken;
            var ok = await App.ModifyPlaylistAsync(_detail.Playlist, new[] { song.Id }, add: false);
            if (ok && _loadToken == token)
            {
                _tracks.Remove(song);
                RenderHeader();
            }
            return ok;
        });
    }

    private Task ShowNameDialogAsync(string title, string initial, Func<string, Task<bool>> onSubmit)
    {
        var panel = new StackPanel { Spacing = CTSpacing.Lg, Width = 380 };
        panel.Children.Add(new TextBlock { Text = title, Classes = { "sectionTitle" } });

        var box = new TextBox { Text = initial, Watermark = "歌单名称", MaxLength = 40 };
        panel.Children.Add(box);

        var error = new TextBlock
        {
            Foreground = CTColors.AccentBrush,
            TextWrapping = TextWrapping.Wrap,
            IsVisible = false,
        };
        panel.Children.Add(error);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Sm,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        var cancel = new Button { Content = L10n.Common.Cancel };
        var confirm = new Button { Content = title, Classes = { "accent" } };
        buttons.Children.Add(cancel);
        buttons.Children.Add(confirm);
        panel.Children.Add(buttons);

        var scrim = BuildScrim(panel);
        Grid.SetRowSpan(scrim, 2);
        _root.Children.Add(scrim);
        App.ClearWriteError();

        var working = false;

        void Close()
        {
            _root.Children.Remove(scrim);
            App.ClearWriteError();
        }

        async Task SubmitAsync()
        {
            var name = (box.Text ?? "").Trim();
            if (name.Length == 0 || working) return;
            working = true;
            confirm.IsEnabled = false;
            error.IsVisible = false;
            var ok = await onSubmit(name);
            working = false;
            confirm.IsEnabled = true;
            if (ok)
            {
                Close();
            }
            else
            {
                error.Text = App.LastWriteError ?? "操作失败";
                error.IsVisible = true;
            }
        }

        cancel.Click += (_, _) => Close();
        confirm.Click += async (_, _) => await SubmitAsync();
        box.KeyDown += async (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            e.Handled = true;
            await SubmitAsync();
        };
        box.AttachedToVisualTree += (_, _) => Dispatcher.UIThread.Post(() => box.Focus());
        return Task.CompletedTask;
    }

    private Task ShowConfirmDialogAsync(string title, string message, string confirmText, Func<Task<bool>> onConfirm)
    {
        var panel = new StackPanel { Spacing = CTSpacing.Lg, Width = 360 };
        panel.Children.Add(new TextBlock { Text = title, Classes = { "sectionTitle" } });
        panel.Children.Add(new TextBlock
        {
            Text = message,
            TextWrapping = TextWrapping.Wrap,
            Foreground = CTColors.TextSecondaryBrush,
        });

        var error = new TextBlock
        {
            Foreground = CTColors.AccentBrush,
            TextWrapping = TextWrapping.Wrap,
            IsVisible = false,
        };
        panel.Children.Add(error);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Sm,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        var cancel = new Button { Content = L10n.Common.Cancel };
        var confirm = new Button { Content = confirmText };
        buttons.Children.Add(cancel);
        buttons.Children.Add(confirm);
        panel.Children.Add(buttons);

        var scrim = BuildScrim(panel);
        Grid.SetRowSpan(scrim, 2);
        _root.Children.Add(scrim);
        App.ClearWriteError();

        var working = false;

        void Close()
        {
            _root.Children.Remove(scrim);
            App.ClearWriteError();
        }

        async Task SubmitAsync()
        {
            if (working) return;
            working = true;
            confirm.IsEnabled = false;
            error.IsVisible = false;
            var ok = await onConfirm();
            working = false;
            confirm.IsEnabled = true;
            if (ok)
            {
                Close();
            }
            else
            {
                error.Text = App.LastWriteError ?? "操作失败";
                error.IsVisible = true;
            }
        }

        cancel.Click += (_, _) => Close();
        confirm.Click += async (_, _) => await SubmitAsync();
        return Task.CompletedTask;
    }

    private static Border BuildScrim(Control card) => new()
    {
        Background = new SolidColorBrush(Color.Parse("#88000000")),
        Child = new Border
        {
            Background = CTColors.PanelBrush,
            CornerRadius = new CornerRadius(CTRadius.Large),
            Padding = new Thickness(CTSpacing.Xl),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Child = card,
        },
        ZIndex = 100,
    };

    private static MenuItem MenuItem(string header, Action action)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => action();
        return item;
    }

    private static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }
}
