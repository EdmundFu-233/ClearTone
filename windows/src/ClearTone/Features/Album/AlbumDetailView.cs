using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
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

namespace ClearTone.Features.Album;

[PageView(Page.AlbumDetail)]
public sealed class AlbumDetailView : UserControl, IPageView
{
    private static AppState App => AppState.Shared;
    private static PlayerController Player => PlayerController.Shared;
    private static NeteaseProvider Provider => NeteaseProvider.Shared;

    private readonly Grid _root = new();
    private readonly ContentControl _headerHost = new();
    private readonly ContentControl _bodyHost = new();
    private readonly ContentControl _statusHost = new();
    private readonly SongListView _trackList = new();
    private readonly SongListView _similarList = new();
    private readonly StackPanel _bodyPanel = new();
    private readonly ScrollViewer _bodyScroll = new();
    private readonly TextBlock _similarHeader = new() { Text = "相似歌曲", Classes = { "sectionTitle" } };

    private PlaylistDetail? _detail;
    private string? _albumID;
    private Guid _loadToken;
    private bool _isLoading;
    private bool _isAttached;
    private bool? _isSubscribed;
    private bool _isSubscribing;
    private string? _actionError;
    private string _lastDataContextKey = "";
    private string? _errorMessage;

    public AlbumDetailView()
    {
        _headerHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _bodyHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _bodyHost.VerticalContentAlignment = VerticalAlignment.Stretch;
        _statusHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _statusHost.VerticalContentAlignment = VerticalAlignment.Stretch;

        _similarHeader.Margin = new Thickness(CTSpacing.Xl, CTSpacing.Lg, CTSpacing.Xl, CTSpacing.Sm);
        _similarHeader.IsVisible = false;
        _similarList.IsVisible = false;
        _bodyPanel.Spacing = CTSpacing.Sm;
        _bodyPanel.Children.Add(_trackList);
        _bodyPanel.Children.Add(_similarHeader);
        _bodyPanel.Children.Add(_similarList);
        _bodyScroll.Content = _bodyPanel;
        _bodyScroll.Padding = new Thickness(0, 0, 0, CTSpacing.Xl);
        _bodyScroll.HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;

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
            case nameof(AppState.SelectedAlbumID):
                if (_isAttached) Post(() => _ = LoadAsync());
                break;
            case nameof(AppState.DataContextKey):
            case nameof(AppState.Account):
            case nameof(AppState.IsLoggedIn):
            case nameof(AppState.CurrentAccountGeneration):
                RefreshForDataContext();
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

    private async Task LoadAsync()
    {
        var id = App.SelectedAlbumID;
        if (string.IsNullOrEmpty(id))
        {
            _albumID = null;
            _detail = null;
            _isLoading = false;
            _errorMessage = null;
            _isSubscribed = null;
            _actionError = null;
            _trackList.SetSongs(Array.Empty<Song>());
            ResetSimilar();
            Render();
            return;
        }

        var token = Guid.NewGuid();
        _loadToken = token;
        _albumID = id;
        _isLoading = true;
        _errorMessage = null;
        _actionError = null;
        _detail = null;
        _isSubscribed = null;
        _trackList.SetSongs(Array.Empty<Song>());
        ResetSimilar();
        Render();

        try
        {
            var loaded = await Provider.FetchAlbumDetailAsync(id).ConfigureAwait(true);
            if (_loadToken != token) return;
            _detail = loaded;
            _trackList.SetSongs(loaded.Tracks);
            _isLoading = false;
            Render();
            await LoadSimilarAsync(token, id, loaded.Tracks).ConfigureAwait(true);
        }
        catch (OperationCanceledException)
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

    private void ResetSimilar()
    {
        _similarList.SetSongs(Array.Empty<Song>());
        _similarHeader.IsVisible = false;
        _similarList.IsVisible = false;
    }

    private async Task LoadSimilarAsync(Guid token, string albumID, IReadOnlyList<Song> tracks)
    {
        if (tracks.Count == 0) return;
        var first = tracks[0];
        if (first.Source != SongSource.Netease) return;
        try
        {
            var loaded = await Provider.FetchSimilarSongsAsync(first.Id, 20).ConfigureAwait(true);
            if (_loadToken != token || _albumID != albumID) return;
            var similar = loaded.Where(item => item.Id != first.Id).ToList();
            if (similar.Count == 0) return;
            _similarList.SetSongs(similar);
            _similarHeader.IsVisible = true;
            _similarList.IsVisible = true;
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception)
        {
        }
    }

    private void Render()
    {
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
            ShowStatus(string.IsNullOrEmpty(App.SelectedAlbumID)
                ? UIComponents.StatusPanel("专辑不存在或已下架")
                : UIComponents.StatusPanel("加载中…", showSpinner: true));
            return;
        }

        _statusHost.IsVisible = false;
        _headerHost.IsVisible = true;
        _bodyHost.IsVisible = true;
        RenderHeader();
        if (!ReferenceEquals(_bodyHost.Content, _bodyScroll)) _bodyHost.Content = _bodyScroll;
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

        var detail = _detail;
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*"),
            Margin = new Thickness(CTSpacing.Xl),
        };
        grid.Children.Add(new CoverImage
        {
            Width = 180,
            Height = 180,
            CornerRadius = new CornerRadius(CTRadius.Medium),
            CoverUrl = detail.Playlist.CoverURL,
            DecodeWidth = 360,
            VerticalAlignment = VerticalAlignment.Top,
        });

        var info = new StackPanel { Spacing = CTSpacing.Sm, Margin = new Thickness(CTSpacing.Lg, 0, 0, 0) };
        Grid.SetColumn(info, 1);
        info.Children.Add(new TextBlock
        {
            Text = detail.Playlist.Name,
            Classes = { "pageTitle" },
            TextWrapping = TextWrapping.Wrap,
        });

        var isSubscribed = _isSubscribed ?? false;
        if (!string.IsNullOrEmpty(detail.Playlist.CreatorName))
        {
            if (!string.IsNullOrEmpty(detail.ArtistID))
            {
                var artistID = detail.ArtistID!;
                var artistName = detail.Playlist.CreatorName!;
                info.Children.Add(UIComponents.LinkButton($"歌手：{artistName}", () => App.OpenArtist(artistID)));
            }
            else
            {
                info.Children.Add(new TextBlock
                {
                    Text = $"歌手：{detail.Playlist.CreatorName}",
                    Classes = { "secondary" },
                });
            }
        }

        info.Children.Add(new TextBlock
        {
            Text = $"{detail.Tracks.Count} 首歌曲",
            Classes = { "secondary" },
        });

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Md };
        var playAll = new Button
        {
            Content = "播放全部",
            Classes = { "accent" },
            IsEnabled = detail.Tracks.Count > 0,
        };
        playAll.Click += (_, _) => Player.PlaySongs(detail.Tracks.ToList(), 0);
        actions.Children.Add(playAll);

        var insertNext = new Button
        {
            Content = "下一首播放",
            IsEnabled = detail.Tracks.Count > 0,
        };
        insertNext.Click += (_, _) => Player.InsertNext(detail.Tracks.ToList());
        actions.Children.Add(insertNext);

        if (App.CanPerformWrite)
        {
            var subscribe = new Button
            {
                Content = isSubscribed ? "取消收藏" : "收藏专辑",
                IsEnabled = !_isSubscribing,
            };
            subscribe.Click += (_, _) => _ = SubscribeAsync(!isSubscribed);
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

    private async Task SubscribeAsync(bool subscribe)
    {
        if (_albumID is null || _isSubscribing) return;
        var token = _loadToken;
        _isSubscribing = true;
        RenderHeader();
        try
        {
            await Provider.SubscribeAlbumAsync(_albumID, subscribe).ConfigureAwait(true);
            if (_loadToken != token) return;
            _isSubscribed = subscribe;
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

    private static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }
}
