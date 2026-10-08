using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
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
using ArtistModel = ClearTone.Core.Models.Artist;

namespace ClearTone.Features.Discover;

[PageView(Page.PersonalFM)]
public sealed class PersonalFMView : UserControl, IPageView
{
    private static AppState App => AppState.Shared;
    private static PlayerController Player => PlayerController.Shared;
    private static NeteaseProvider Provider => NeteaseProvider.Shared;

    private readonly ContentControl _host = new();
    private readonly TextBlock _subtitle;

    private readonly List<Song> _songs = new();
    private int _index;
    private bool _isLoading;
    private string? _errorMessage;
    private Guid _loadToken;
    private bool _hasLoaded;
    private string _lastDataContextKey = "";

    public PersonalFMView()
    {
        _subtitle = new TextBlock { Text = "根据你的口味生成 endless 流。", Classes = { "secondary" } };

        var titleStack = new StackPanel { Spacing = CTSpacing.Xs };
        titleStack.Children.Add(new TextBlock { Text = "私人 FM", Classes = { "pageTitle" } });
        titleStack.Children.Add(_subtitle);
        titleStack.Margin = new Thickness(CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Xl, 0);

        _host.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _host.VerticalContentAlignment = VerticalAlignment.Stretch;

        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*"), Background = CTColors.BackgroundBrush };
        root.Children.Add(titleStack);
        Grid.SetRow(_host, 1);
        root.Children.Add(_host);
        Content = root;

        App.PropertyChanged += OnAppPropertyChanged;
        Player.PropertyChanged += OnPlayerPropertyChanged;
        _lastDataContextKey = App.DataContextKey;
        Render();
    }

    public void OnActivated()
    {
        if (_hasLoaded) return;
        _hasLoaded = true;
        if (App.CanPerformWrite) _ = LoadAsync();
        else Render();
    }

    private void OnAppPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppState.DataContextKey):
            case nameof(AppState.Account):
            case nameof(AppState.IsLoggedIn):
            case nameof(AppState.CurrentAccountGeneration):
                Post(RefreshForDataContext);
                break;
            case nameof(AppState.LikesVersion):
                Post(Render);
                break;
        }
    }

    private void OnPlayerPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PlayerController.CurrentSong) or nameof(PlayerController.PlaybackState))
        {
            Post(Render);
        }
    }

    private void RefreshForDataContext()
    {
        var key = App.DataContextKey;
        if (key == _lastDataContextKey)
        {
            Render();
            return;
        }
        _lastDataContextKey = key;
        _loadToken = Guid.NewGuid();
        _songs.Clear();
        _index = 0;
        _errorMessage = null;
        _isLoading = false;
        _hasLoaded = true;
        if (App.CanPerformWrite) _ = LoadAsync();
        else Render();
    }

    private async Task LoadAsync()
    {
        var token = Guid.NewGuid();
        _loadToken = token;
        _isLoading = true;
        _errorMessage = null;
        Render();
        try
        {
            var batch = await Provider.FetchPersonalFMAsync();
            if (_loadToken != token) return;
            _songs.Clear();
            _songs.AddRange(batch);
            _index = 0;
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            if (_songs.Count == 0) _errorMessage = error.CtUserMessage();
        }
        if (_loadToken != token) return;
        _isLoading = false;
        Render();
    }

    private async Task NextAsync()
    {
        if (_isLoading) return;
        _index++;
        if (_index < _songs.Count)
        {
            Render();
            return;
        }
        await LoadAsync();
    }

    private async Task ToggleLikeAsync(Song song)
    {
        if (!App.CanPerformWrite) return;
        try
        {
            await App.ToggleLikeAsync(song);
        }
        catch (Exception error)
        {
            App.PublishWriteError(error);
        }
        Render();
    }

    private void Render()
    {
        if (!App.CanPerformWrite)
        {
            _subtitle.Text = "登录后使用私人 FM";
            _host.Content = BuildLoginRequired();
            return;
        }
        if (_isLoading && _songs.Count == 0)
        {
            _subtitle.Text = "正在获取推荐…";
            _host.Content = UIComponents.StatusPanel("加载中…", showSpinner: true);
            return;
        }
        if (_errorMessage is { } error && _songs.Count == 0)
        {
            _subtitle.Text = "根据你的口味生成 endless 流。";
            _host.Content = UIComponents.ErrorPanel(error, () => _ = LoadAsync());
            return;
        }
        if (_songs.Count == 0 || _index < 0 || _index >= _songs.Count)
        {
            _subtitle.Text = "根据你的口味生成 endless 流。";
            _host.Content = UIComponents.StatusPanel("点「下一首」获取推荐");
            return;
        }
        _subtitle.Text = $"本批 {_songs.Count} 首 · 第 {_index + 1} 首";
        _host.Content = BuildCurrentPanel(_songs[_index]);
    }

    private Control BuildCurrentPanel(Song song)
    {
        var isCurrent = Player.CurrentSong?.Id == song.Id;
        var isPlaying = isCurrent && Player.PlaybackState.IsPlaying;

        var panel = new StackPanel
        {
            Spacing = CTSpacing.Lg,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Xxl),
        };
        panel.Children.Add(new CoverImage
        {
            Width = 280,
            Height = 280,
            CornerRadius = new CornerRadius(CTRadius.Large),
            CoverUrl = song.CoverURL,
            DecodeWidth = 560,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        panel.Children.Add(new TextBlock
        {
            Text = song.Title,
            Classes = { "sectionTitle" },
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            MaxWidth = 480,
        });
        panel.Children.Add(BuildArtistLinks(song.Artists));
        panel.Children.Add(new TextBlock
        {
            Text = $"第 {_index + 1} / {_songs.Count} 首 · {CTFormatting.Time(song.Duration)}",
            Classes = { "secondary" },
            HorizontalAlignment = HorizontalAlignment.Center,
        });

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Md,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        var play = new Button { Content = isPlaying ? "暂停" : "播放", Classes = { "accent" } };
        play.Click += (_, _) =>
        {
            if (isPlaying) Player.Pause();
            else if (song.IsPlayable) Player.PlaySong(song);
        };
        actions.Children.Add(play);

        var next = new Button { Content = "下一首" };
        next.Click += (_, _) => _ = NextAsync();
        actions.Children.Add(next);

        var liked = App.IsLiked(song.Id);
        var like = new Button
        {
            Content = liked ? "取消喜欢" : "喜欢",
            IsEnabled = song.Source == SongSource.Netease,
        };
        like.Click += (_, _) => _ = ToggleLikeAsync(song);
        actions.Children.Add(like);

        panel.Children.Add(actions);
        return panel;
    }

    private Control BuildLoginRequired()
    {
        var panel = new StackPanel
        {
            Spacing = CTSpacing.Md,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 60, 0, 60),
        };
        panel.Children.Add(new TextBlock
        {
            Text = "登录后使用私人 FM",
            Classes = { "sectionTitle" },
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        panel.Children.Add(new TextBlock
        {
            Text = "私人 FM 属于账号数据，扫码登录后即可使用。",
            Classes = { "secondary" },
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        var login = new Button { Content = "扫码登录", Classes = { "accent" }, HorizontalAlignment = HorizontalAlignment.Center };
        login.Click += (_, _) => App.IsLoginPresented = true;
        panel.Children.Add(login);
        return panel;
    }

    private static Control BuildArtistLinks(IReadOnlyList<ArtistModel> artists)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0, HorizontalAlignment = HorizontalAlignment.Center };
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

    private static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }
}
