using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using ClearTone.Controls;
using ClearTone.Core.Comments;
using ClearTone.Core.Models;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Playback;
using ClearTone.Shell;
using CommentModel = ClearTone.Core.Models.Comment;

namespace ClearTone.Features.Comments;

[PageView(Page.SongComments)]
public sealed class SongCommentsView : UserControl, IPageView
{
    private static readonly FontFamily IconFont = new("Segoe MDL2 Assets, Segoe Fluent Icons");

    private static AppState App => AppState.Shared;
    private static PlayerController Player => PlayerController.Shared;

    private readonly CommentsStore _store = new();
    private readonly Grid _root = new();
    private readonly ContentControl _headerHost = new();
    private readonly ContentControl _bodyHost = new();
    private readonly ContentControl _footerHost = new();

    private Song? _song;
    private Guid _loadToken;
    private bool _isAttached;
    private string _lastDataContextKey = "";

    public SongCommentsView()
    {
        _headerHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _bodyHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _bodyHost.VerticalContentAlignment = VerticalAlignment.Stretch;
        _footerHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;

        _root.RowDefinitions = new RowDefinitions("Auto,*,Auto");
        _root.Background = CTColors.BackgroundBrush;
        _root.Children.Add(_headerHost);
        Grid.SetRow(_bodyHost, 1);
        _root.Children.Add(_bodyHost);
        Grid.SetRow(_footerHost, 2);
        _root.Children.Add(_footerHost);
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
            case nameof(AppState.CommentSong):
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
        var song = App.CommentSong;
        if (song is null)
        {
            _song = null;
            Render();
            return;
        }

        var token = Guid.NewGuid();
        _loadToken = token;
        _song = song;
        Render();

        try
        {
            await _store.LoadAsync(song, _store.Sort).ConfigureAwait(true);
        }
        catch (Exception)
        {
        }
        if (_loadToken != token) return;
        _song = _store.Song ?? song;
        Render();
    }

    private async Task ChangeSortAsync(CommentSort sort)
    {
        if (_song is null || _store.Sort == sort) return;
        try
        {
            await _store.LoadAsync(_song, sort).ConfigureAwait(true);
        }
        catch (Exception)
        {
        }
        Render();
    }

    private async Task LoadMoreAsync()
    {
        try
        {
            await _store.LoadMoreAsync().ConfigureAwait(true);
        }
        catch (Exception)
        {
        }
        Render();
    }

    private async Task ToggleLikeAsync(CommentModel comment)
    {
        if (!App.CanPerformWrite) return;
        try
        {
            await _store.ToggleLikeAsync(comment).ConfigureAwait(true);
        }
        catch (Exception)
        {
        }
        Render();
    }

    private void Render()
    {
        RenderHeader();

        if (_song is null)
        {
            _bodyHost.Content = UIComponents.StatusPanel("暂无内容");
            _footerHost.Content = null;
            return;
        }
        if (_store.IsLoading)
        {
            _bodyHost.Content = UIComponents.StatusPanel("加载中…", showSpinner: true);
            _footerHost.Content = null;
            return;
        }
        if (_store.ErrorMessage is { } error)
        {
            _bodyHost.Content = UIComponents.ErrorPanel(error, () => _ = LoadAsync());
            _footerHost.Content = null;
            return;
        }
        if (_store.Comments.Count == 0)
        {
            _bodyHost.Content = UIComponents.StatusPanel("暂无内容");
            _footerHost.Content = null;
            return;
        }

        _bodyHost.Content = BuildList();
        _footerHost.Content = BuildFooter();
    }

    private void RenderHeader()
    {
        if (_song is not { } song)
        {
            _headerHost.Content = null;
            return;
        }

        var panel = new StackPanel { Spacing = CTSpacing.Md, Margin = new Thickness(CTSpacing.Xl) };

        var top = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        top.Children.Add(new CoverImage
        {
            Width = 72,
            Height = 72,
            CornerRadius = new CornerRadius(CTRadius.Small),
            CoverUrl = song.CoverURL,
            DecodeWidth = 144,
            VerticalAlignment = VerticalAlignment.Top,
        });

        var info = new StackPanel
        {
            Spacing = 4,
            Margin = new Thickness(CTSpacing.Lg, 0, CTSpacing.Md, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(info, 1);
        info.Children.Add(new TextBlock
        {
            Text = song.Title,
            Classes = { "pageTitle" },
            TextWrapping = TextWrapping.Wrap,
        });
        var subtitle = string.IsNullOrEmpty(song.Album?.Name)
            ? song.ArtistNames
            : $"{song.ArtistNames} · {song.Album!.Name}";
        info.Children.Add(new TextBlock
        {
            Text = subtitle,
            Classes = { "secondary" },
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        top.Children.Add(info);

        var play = new Button
        {
            Content = "播放",
            VerticalAlignment = VerticalAlignment.Center,
        };
        play.Click += (_, _) => Player.PlaySongs(new List<Song> { song }, 0);
        Grid.SetColumn(play, 2);
        top.Children.Add(play);
        panel.Children.Add(top);

        var sortRow = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        var sorts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Sm };
        foreach (var sort in new[] { CommentSort.Recommended, CommentSort.Hot, CommentSort.Newest })
        {
            sorts.Children.Add(SortButton(sort));
        }
        sortRow.Children.Add(sorts);
        var total = new TextBlock
        {
            Text = $"{_store.Total} 条评论",
            Classes = { "secondary" },
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(total, 2);
        sortRow.Children.Add(total);
        panel.Children.Add(sortRow);

        panel.Children.Add(new TextBlock
        {
            Text = App.CanPerformWrite
                ? "发表评论依赖网易云的反作弊校验，当前版本仅支持阅读与点赞"
                : "登录后可发表评论、点赞",
            Classes = { "secondary" },
            TextWrapping = TextWrapping.Wrap,
        });

        _headerHost.Content = panel;
    }

    private Button SortButton(CommentSort sort)
    {
        var button = new Button { Content = sort.DisplayName() };
        if (_store.Sort == sort) button.Classes.Add("accent");
        button.Click += (_, _) => _ = ChangeSortAsync(sort);
        return button;
    }

    private Control BuildList()
    {
        var list = new ListBox
        {
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            ItemsSource = _store.Comments.ToList(),
        };
        list.ItemTemplate = new FuncDataTemplate<CommentModel>((comment, _) =>
            comment is null ? new Control() : BuildRow(comment));
        return list;
    }

    private Control BuildRow(CommentModel comment)
    {
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*"),
            Margin = new Thickness(CTSpacing.Lg, CTSpacing.Md),
        };
        grid.Children.Add(new CoverImage
        {
            Width = 36,
            Height = 36,
            CornerRadius = new CornerRadius(18),
            CoverUrl = comment.AvatarURL,
            DecodeWidth = 72,
            VerticalAlignment = VerticalAlignment.Top,
        });

        var right = new StackPanel
        {
            Spacing = CTSpacing.Xs,
            Margin = new Thickness(CTSpacing.Md, 0, 0, 0),
        };
        Grid.SetColumn(right, 1);

        var nameRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Sm };
        nameRow.Children.Add(new TextBlock { Text = comment.Nickname, FontWeight = FontWeight.Medium });
        if (comment.IsMine)
        {
            nameRow.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(8),
                Background = CTColors.OverlayBrush,
                Padding = new Thickness(5, 1),
                Child = new TextBlock { Text = "我", Classes = { "secondary" }, Foreground = CTColors.AccentBrush },
            });
        }
        nameRow.Children.Add(new TextBlock { Text = RelativeTime(comment.Time), Classes = { "secondary" } });
        right.Children.Add(nameRow);

        if (!string.IsNullOrEmpty(comment.ReplyToNickname))
        {
            right.Children.Add(new Border
            {
                Background = CTColors.OverlayBrush,
                CornerRadius = new CornerRadius(CTRadius.Small),
                Padding = new Thickness(CTSpacing.Xs),
                Child = new TextBlock
                {
                    Text = $"回复 @{comment.ReplyToNickname}：{comment.ReplyToContent}",
                    Classes = { "secondary" },
                    TextWrapping = TextWrapping.Wrap,
                },
            });
        }

        right.Children.Add(new TextBlock
        {
            Text = comment.Content,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 720,
        });

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Lg };
        var pending = _store.PendingLikeIDs.Contains(comment.Id);
        var like = new Button
        {
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(4, 2),
            IsEnabled = App.CanPerformWrite && !pending,
        };
        var likeContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        var likeBrush = comment.IsLiked ? CTColors.AccentBrush : CTColors.TextSecondaryBrush;
        likeContent.Children.Add(new TextBlock
        {
            Text = "\uE8E1",
            FontFamily = IconFont,
            FontSize = 12,
            Foreground = likeBrush,
        });
        if (comment.LikedCount > 0)
        {
            likeContent.Children.Add(new TextBlock
            {
                Text = comment.LikedCount.ToString(),
                Foreground = likeBrush,
                FontSize = 12,
            });
        }
        like.Content = likeContent;
        like.Click += (_, _) => _ = ToggleLikeAsync(comment);
        actions.Children.Add(like);

        if (comment.ReplyCount > 0)
        {
            actions.Children.Add(new TextBlock
            {
                Text = $"{comment.ReplyCount} 条回复",
                Classes = { "secondary" },
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        right.Children.Add(actions);

        grid.Children.Add(right);
        return new Border { Child = grid };
    }

    private Control? BuildFooter()
    {
        var panel = new StackPanel
        {
            Spacing = CTSpacing.Sm,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, CTSpacing.Md),
        };

        if (_store.LikeError is { } likeError)
        {
            panel.Children.Add(new TextBlock
            {
                Text = likeError,
                Classes = { "secondary" },
                HorizontalAlignment = HorizontalAlignment.Center,
            });
        }

        if (_store.IsLoadingMore)
        {
            panel.Children.Add(new ProgressBar
            {
                IsIndeterminate = true,
                Width = 160,
                Height = 4,
                HorizontalAlignment = HorizontalAlignment.Center,
            });
        }
        else if (_store.PaginationError is { } paginationError && _store.HasMore)
        {
            panel.Children.Add(new TextBlock
            {
                Text = paginationError,
                Classes = { "secondary" },
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            panel.Children.Add(UIComponents.LinkButton("重试加载更多", () => _ = LoadMoreAsync()));
        }
        else if (_store.HasMore)
        {
            var button = new Button { Content = "加载更多", HorizontalAlignment = HorizontalAlignment.Center };
            button.Click += (_, _) => _ = LoadMoreAsync();
            panel.Children.Add(button);
        }

        return panel.Children.Count == 0 ? null : new Border
        {
            Padding = new Thickness(0, CTSpacing.Sm, 0, CTSpacing.Lg),
            Child = panel,
        };
    }

    private static string RelativeTime(DateTimeOffset date)
    {
        var seconds = (DateTimeOffset.Now - date).TotalSeconds;
        if (seconds < 60) return "刚刚";
        if (seconds < 3600) return $"{(int)(seconds / 60)} 分钟前";
        if (seconds < 86400) return $"{(int)(seconds / 3600)} 小时前";
        if (seconds < 172800) return "昨天";
        if (seconds < 604800) return $"{(int)(seconds / 86400)} 天前";
        return date.ToLocalTime().ToString("yyyy-MM-dd");
    }

    private static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }
}
