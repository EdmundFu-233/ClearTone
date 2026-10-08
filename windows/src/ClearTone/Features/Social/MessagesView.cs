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
using ClearTone.Providers.Netease;
using ClearTone.Shell;

namespace ClearTone.Features.Social;

[PageView(Page.Messages)]
public sealed class MessagesView : UserControl, IPageView
{
    private enum MessageTab
    {
        Notices,
        Conversations,
        MyComments,
    }

    private static AppState App => AppState.Shared;
    private static NeteaseProvider Provider => NeteaseProvider.Shared;

    private readonly Grid _root = new();
    private readonly ContentControl _tabsHost = new();
    private readonly ContentControl _contentHost = new();

    private MessageTab _tab = MessageTab.Notices;

    private readonly List<UserNotice> _notices = new();
    private bool _loadingNotices;
    private string? _noticesError;
    private int _noticesToken;

    private readonly List<PrivateConversation> _conversations = new();
    private bool _loadingConversations;
    private string? _conversationsError;
    private int _conversationsToken;

    private PrivateConversation? _selectedConversation;
    private readonly List<PrivateMessage> _messages = new();
    private bool _loadingMessages;
    private string? _messagesError;
    private int _messagesToken;

    private readonly List<MyComment> _myComments = new();
    private bool _loadingMyComments;
    private string? _myCommentsError;
    private int _myCommentsToken;

    private bool _isAttached;
    private string _lastDataContextKey = "";

    public MessagesView()
    {
        _tabsHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _contentHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _contentHost.VerticalContentAlignment = VerticalAlignment.Stretch;

        var titleStack = new StackPanel { Spacing = CTSpacing.Xs };
        titleStack.Children.Add(new TextBlock { Text = "消息", Classes = { "pageTitle" } });
        titleStack.Children.Add(new TextBlock { Text = "评论、回复与私信都在这里。", Classes = { "secondary" } });

        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        header.Children.Add(titleStack);
        var refresh = new Button { Content = "刷新", VerticalAlignment = VerticalAlignment.Center };
        refresh.Click += (_, _) => _ = RefreshAsync();
        Grid.SetColumn(refresh, 1);
        header.Children.Add(refresh);
        header.Margin = new Thickness(CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Lg);

        _root.RowDefinitions = new RowDefinitions("Auto,Auto,*");
        _root.Background = CTColors.BackgroundBrush;
        _root.Children.Add(header);
        Grid.SetRow(_tabsHost, 1);
        _root.Children.Add(_tabsHost);
        Grid.SetRow(_contentHost, 2);
        _root.Children.Add(_contentHost);
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
        _ = LoadCurrentTabAsync();
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
        _notices.Clear();
        _conversations.Clear();
        _myComments.Clear();
        _selectedConversation = null;
        _messages.Clear();
        _noticesToken++;
        _conversationsToken++;
        _myCommentsToken++;
        _messagesToken++;
        if (_isAttached) Post(() => _ = LoadCurrentTabAsync());
        else Post(Render);
    }

    private async Task LoadCurrentTabAsync()
    {
        switch (_tab)
        {
            case MessageTab.Notices:
                await LoadNoticesAsync().ConfigureAwait(true);
                break;
            case MessageTab.Conversations:
                await LoadConversationsAsync().ConfigureAwait(true);
                break;
            default:
                await LoadMyCommentsAsync().ConfigureAwait(true);
                break;
        }
    }

    private async Task RefreshAsync()
    {
        if (_tab == MessageTab.Conversations && _selectedConversation is { } conversation)
        {
            await OpenConversationAsync(conversation).ConfigureAwait(true);
            return;
        }
        await LoadCurrentTabAsync().ConfigureAwait(true);
    }

    private async Task LoadNoticesAsync()
    {
        var token = ++_noticesToken;
        _loadingNotices = _notices.Count == 0;
        _noticesError = null;
        Render();
        try
        {
            var loaded = await Provider.FetchNoticesAsync().ConfigureAwait(true);
            if (_noticesToken != token) return;
            _notices.Clear();
            _notices.AddRange(loaded);
        }
        catch (Exception error)
        {
            if (_noticesToken != token) return;
            _noticesError = error.CtUserMessage();
        }
        finally
        {
            if (_noticesToken == token)
            {
                _loadingNotices = false;
                Render();
            }
        }
    }

    private async Task LoadConversationsAsync()
    {
        var token = ++_conversationsToken;
        _loadingConversations = _conversations.Count == 0;
        _conversationsError = null;
        Render();
        try
        {
            var loaded = await Provider.FetchPrivateConversationsAsync().ConfigureAwait(true);
            if (_conversationsToken != token) return;
            _conversations.Clear();
            _conversations.AddRange(loaded);
        }
        catch (Exception error)
        {
            if (_conversationsToken != token) return;
            _conversationsError = error.CtUserMessage();
        }
        finally
        {
            if (_conversationsToken == token)
            {
                _loadingConversations = false;
                Render();
            }
        }
    }

    private async Task OpenConversationAsync(PrivateConversation conversation)
    {
        _selectedConversation = conversation;
        var token = ++_messagesToken;
        _loadingMessages = true;
        _messagesError = null;
        _messages.Clear();
        Render();
        try
        {
            var loaded = await Provider.FetchPrivateMessagesAsync(conversation.UserID, 50).ConfigureAwait(true);
            if (_messagesToken != token) return;
            _messages.AddRange(loaded);
            MarkConversationRead(conversation);
        }
        catch (Exception error)
        {
            if (_messagesToken != token) return;
            _messagesError = error.CtUserMessage();
        }
        finally
        {
            if (_messagesToken == token)
            {
                _loadingMessages = false;
                Render();
            }
        }
    }

    private void MarkConversationRead(PrivateConversation conversation)
    {
        var index = _conversations.FindIndex(item => item.Id == conversation.Id);
        if (index < 0 || _conversations[index].UnreadCount == 0) return;
        _conversations[index] = _conversations[index] with { UnreadCount = 0 };
    }

    private void CloseConversation()
    {
        _selectedConversation = null;
        _messages.Clear();
        _messagesToken++;
        Render();
    }

    private async Task LoadMyCommentsAsync()
    {
        var token = ++_myCommentsToken;
        _loadingMyComments = _myComments.Count == 0;
        _myCommentsError = null;
        Render();
        try
        {
            var loaded = await Provider.FetchMyCommentsAsync().ConfigureAwait(true);
            if (_myCommentsToken != token) return;
            _myComments.Clear();
            _myComments.AddRange(loaded);
        }
        catch (Exception error)
        {
            if (_myCommentsToken != token) return;
            _myCommentsError = error.CtUserMessage();
        }
        finally
        {
            if (_myCommentsToken == token)
            {
                _loadingMyComments = false;
                Render();
            }
        }
    }

    private void Render()
    {
        if (!App.CanPerformWrite)
        {
            _tabsHost.IsVisible = false;
            _contentHost.Content = BuildLoginRequired();
            return;
        }

        _tabsHost.IsVisible = true;
        RenderTabs();
        _contentHost.Content = _tab switch
        {
            MessageTab.Notices => BuildNoticesPane(),
            MessageTab.Conversations => BuildConversationsPane(),
            _ => BuildMyCommentsPane(),
        };
    }

    private void RenderTabs()
    {
        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Sm,
            Margin = new Thickness(CTSpacing.Xl, 0, CTSpacing.Xl, CTSpacing.Md),
        };
        panel.Children.Add(TabButton(MessageTab.Notices, "通知"));
        panel.Children.Add(TabButton(MessageTab.Conversations, "私信"));
        panel.Children.Add(TabButton(MessageTab.MyComments, "我的评论"));
        _tabsHost.Content = panel;
    }

    private Button TabButton(MessageTab tab, string text)
    {
        var button = new Button { Content = text };
        if (tab == _tab) button.Classes.Add("accent");
        button.Click += (_, _) => _ = SwitchTabAsync(tab);
        return button;
    }

    private async Task SwitchTabAsync(MessageTab tab)
    {
        if (_tab == tab) return;
        _tab = tab;
        _selectedConversation = null;
        _messages.Clear();
        _messagesToken++;
        Render();
        await LoadCurrentTabAsync().ConfigureAwait(true);
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
            Text = "登录后查看通知与私信",
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

    private Control BuildNoticesPane()
    {
        if (_loadingNotices && _notices.Count == 0) return UIComponents.StatusPanel("加载中…", showSpinner: true);
        if (_noticesError is { } error) return UIComponents.ErrorPanel(error, () => _ = LoadNoticesAsync());
        if (_notices.Count == 0) return UIComponents.StatusPanel("暂无内容");

        var list = new ListBox
        {
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            ItemsSource = _notices.ToList(),
        };
        list.ItemTemplate = new FuncDataTemplate<UserNotice>((notice, _) =>
            notice is null ? new Control() : BuildNoticeRow(notice));
        return list;
    }

    private static Control BuildNoticeRow(UserNotice notice)
    {
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*"),
            Margin = new Thickness(CTSpacing.Lg, CTSpacing.Sm),
        };
        grid.Children.Add(new CoverImage
        {
            Width = 34,
            Height = 34,
            CornerRadius = new CornerRadius(17),
            CoverUrl = notice.ActorAvatarURL,
            DecodeWidth = 68,
            VerticalAlignment = VerticalAlignment.Top,
        });

        var right = new StackPanel
        {
            Spacing = 3,
            Margin = new Thickness(CTSpacing.Md, 0, 0, 0),
        };
        Grid.SetColumn(right, 1);

        var top = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Sm };
        top.Children.Add(new TextBlock
        {
            Text = notice.Kind.Label,
            Foreground = CTColors.AccentBrush,
            Classes = { "secondary" },
        });
        if (!string.IsNullOrEmpty(notice.ActorNickname))
        {
            top.Children.Add(new TextBlock { Text = notice.ActorNickname, FontWeight = FontWeight.Medium });
        }
        top.Children.Add(new TextBlock
        {
            Text = RelativeTime(notice.Time),
            Classes = { "secondary" },
            VerticalAlignment = VerticalAlignment.Center,
        });
        right.Children.Add(top);

        if (!string.IsNullOrEmpty(notice.Content))
        {
            right.Children.Add(new TextBlock
            {
                Text = notice.Content,
                Classes = { "secondary" },
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 720,
            });
        }
        if (!string.IsNullOrEmpty(notice.ReplyCommentText))
        {
            right.Children.Add(new Border
            {
                Background = CTColors.OverlayBrush,
                CornerRadius = new CornerRadius(CTRadius.Small),
                Padding = new Thickness(CTSpacing.Xs),
                Child = new TextBlock
                {
                    Text = $"「{notice.ReplyCommentText}」",
                    Classes = { "secondary" },
                    TextWrapping = TextWrapping.Wrap,
                    MaxWidth = 680,
                },
            });
        }
        grid.Children.Add(right);
        return new Border { Child = grid };
    }

    private Control BuildConversationsPane()
    {
        if (_selectedConversation is { } conversation) return BuildConversationDetail(conversation);
        if (_loadingConversations && _conversations.Count == 0) return UIComponents.StatusPanel("加载中…", showSpinner: true);
        if (_conversationsError is { } error) return UIComponents.ErrorPanel(error, () => _ = LoadConversationsAsync());
        if (_conversations.Count == 0) return UIComponents.StatusPanel("暂无内容");

        var list = new ListBox
        {
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            ItemsSource = _conversations.ToList(),
        };
        list.ItemTemplate = new FuncDataTemplate<PrivateConversation>((conversation, _) =>
            conversation is null ? new Control() : BuildConversationRow(conversation));
        return list;
    }

    private Control BuildConversationRow(PrivateConversation conversation)
    {
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"),
            Margin = new Thickness(CTSpacing.Lg, CTSpacing.Sm),
        };
        grid.Children.Add(new CoverImage
        {
            Width = 40,
            Height = 40,
            CornerRadius = new CornerRadius(20),
            CoverUrl = conversation.AvatarURL,
            DecodeWidth = 80,
        });

        var info = new StackPanel
        {
            Spacing = 2,
            Margin = new Thickness(CTSpacing.Md, 0, CTSpacing.Md, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(info, 1);
        info.Children.Add(new TextBlock { Text = conversation.Nickname, FontWeight = FontWeight.Medium });
        if (!string.IsNullOrEmpty(conversation.LastMessage))
        {
            info.Children.Add(new TextBlock
            {
                Text = conversation.LastMessage,
                Classes = { "secondary" },
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxWidth = 520,
            });
        }
        grid.Children.Add(info);

        var status = new StackPanel
        {
            Spacing = 4,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        if (conversation.LastTime is { } lastTime)
        {
            status.Children.Add(new TextBlock
            {
                Text = RelativeTime(lastTime),
                Classes = { "secondary" },
                HorizontalAlignment = HorizontalAlignment.Right,
            });
        }
        if (conversation.UnreadCount > 0)
        {
            status.Children.Add(new Border
            {
                Background = CTColors.AccentBrush,
                CornerRadius = new CornerRadius(9),
                Padding = new Thickness(6, 1),
                HorizontalAlignment = HorizontalAlignment.Right,
                Child = new TextBlock
                {
                    Text = conversation.UnreadCount.ToString(),
                    Foreground = Brushes.White,
                    FontSize = 11,
                },
            });
        }
        Grid.SetColumn(status, 2);
        grid.Children.Add(status);

        var button = new Button
        {
            Content = grid,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        button.Click += (_, _) => _ = OpenConversationAsync(conversation);
        return button;
    }

    private Control BuildConversationDetail(PrivateConversation conversation)
    {
        var panel = new StackPanel { Spacing = 0 };

        var top = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"),
            Margin = new Thickness(CTSpacing.Lg),
        };
        var back = new Button { Content = "返回" };
        back.Click += (_, _) => CloseConversation();
        top.Children.Add(back);
        var title = new TextBlock
        {
            Text = conversation.Nickname,
            Classes = { "sectionTitle" },
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(title, 1);
        top.Children.Add(title);
        panel.Children.Add(top);

        panel.Children.Add(new Border
        {
            Height = 1,
            Background = CTColors.OverlayBrush,
        });

        var body = new ContentControl
        {
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
        };
        if (_loadingMessages)
        {
            body.Content = UIComponents.StatusPanel("加载中…", showSpinner: true);
        }
        else if (_messagesError is { } error)
        {
            body.Content = UIComponents.ErrorPanel(error, () => _ = OpenConversationAsync(conversation));
        }
        else if (_messages.Count == 0)
        {
            body.Content = UIComponents.StatusPanel("暂无内容");
        }
        else
        {
            body.Content = BuildMessageBubbles();
        }
        panel.Children.Add(body);

        panel.Children.Add(new Border
        {
            Height = 1,
            Background = CTColors.OverlayBrush,
        });
        panel.Children.Add(new TextBlock
        {
            Text = "发送私信依赖网易云的反作弊校验，当前版本仅支持阅读",
            Classes = { "secondary" },
            Margin = new Thickness(CTSpacing.Lg),
            TextWrapping = TextWrapping.Wrap,
        });

        return panel;
    }

    private Control BuildMessageBubbles()
    {
        var stack = new StackPanel { Spacing = CTSpacing.Md, Margin = new Thickness(CTSpacing.Lg) };
        foreach (var message in _messages)
        {
            var content = new StackPanel { Spacing = 3 };
            if (message.Kind is not PrivateMessageKind.Text)
            {
                content.Children.Add(new TextBlock
                {
                    Text = KindLabel(message.Kind),
                    Classes = { "secondary" },
                });
            }
            content.Children.Add(new TextBlock
            {
                Text = message.Content,
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 420,
            });
            content.Children.Add(new TextBlock
            {
                Text = RelativeTime(message.Time),
                Classes = { "secondary" },
            });

            var bubble = new Border
            {
                Background = message.IsOutgoing ? CTColors.OverlayBrush : CTColors.PanelBrush,
                BorderBrush = message.IsOutgoing ? CTColors.AccentBrush : CTColors.OverlayBrush,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(CTRadius.Medium),
                Padding = new Thickness(CTSpacing.Md),
                HorizontalAlignment = message.IsOutgoing ? HorizontalAlignment.Right : HorizontalAlignment.Left,
                Child = content,
            };
            stack.Children.Add(bubble);
        }

        return new ScrollViewer
        {
            Content = stack,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
    }

    private static string KindLabel(PrivateMessageKind kind) => kind switch
    {
        PrivateMessageKind.Image => "图片",
        PrivateMessageKind.Song => "歌曲",
        PrivateMessageKind.Album => "专辑",
        PrivateMessageKind.Playlist => "歌单",
        _ => "消息",
    };

    private Control BuildMyCommentsPane()
    {
        if (_loadingMyComments && _myComments.Count == 0) return UIComponents.StatusPanel("加载中…", showSpinner: true);
        if (_myCommentsError is { } error) return UIComponents.ErrorPanel(error, () => _ = LoadMyCommentsAsync());
        if (_myComments.Count == 0) return UIComponents.StatusPanel("暂无内容");

        var list = new ListBox
        {
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            ItemsSource = _myComments.ToList(),
        };
        list.ItemTemplate = new FuncDataTemplate<MyComment>((comment, _) =>
            comment is null ? new Control() : BuildMyCommentRow(comment));
        return list;
    }

    private static Control BuildMyCommentRow(MyComment comment)
    {
        var panel = new StackPanel
        {
            Spacing = CTSpacing.Xs,
            Margin = new Thickness(CTSpacing.Lg, CTSpacing.Sm),
        };

        var top = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Sm };
        top.Children.Add(new TextBlock
        {
            Text = comment.ResourceKind.Label(),
            Foreground = CTColors.AccentBrush,
            Classes = { "secondary" },
        });
        top.Children.Add(new TextBlock { Text = RelativeTime(comment.Time), Classes = { "secondary" } });
        if (comment.LikedCount > 0)
        {
            top.Children.Add(new TextBlock
            {
                Text = $"{comment.LikedCount} 赞",
                Classes = { "secondary" },
            });
        }
        panel.Children.Add(top);

        if (!string.IsNullOrEmpty(comment.RepliedNickname))
        {
            panel.Children.Add(new TextBlock
            {
                Text = $"回复 @{comment.RepliedNickname}：{comment.RepliedContent}",
                Classes = { "secondary" },
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 720,
            });
        }

        panel.Children.Add(new TextBlock
        {
            Text = comment.Content,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 720,
        });
        return panel;
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
