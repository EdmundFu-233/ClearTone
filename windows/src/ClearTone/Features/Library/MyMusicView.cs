using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using ClearTone.Core.Models;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Shell;
using PlaylistModel = ClearTone.Core.Models.Playlist;

namespace ClearTone.Features.Library;

[PageView(Page.MyMusic)]
public sealed class MyMusicView : UserControl, IPageView
{
    private static readonly FontFamily IconFont = new("Segoe MDL2 Assets, Segoe Fluent Icons");
    private static AppState App => AppState.Shared;

    private readonly Grid _root = new();
    private readonly StackPanel _body = new();
    private readonly Button _createButton;
    private readonly TextBlock _subtitle;
    private string _lastDataContextKey = "";

    public MyMusicView()
    {
        _subtitle = new TextBlock { Text = "收藏的旋律，都在这里。", Classes = { "secondary" } };

        var titleStack = new StackPanel { Spacing = CTSpacing.Xs };
        titleStack.Children.Add(new TextBlock { Text = "我的音乐", Classes = { "pageTitle" } });
        titleStack.Children.Add(_subtitle);

        _createButton = new Button { Content = "新建歌单", Classes = { "accent" }, VerticalAlignment = VerticalAlignment.Center };
        _createButton.Click += (_, _) => ShowCreatePlaylistDialog();

        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        header.Children.Add(titleStack);
        Grid.SetColumn(_createButton, 1);
        header.Children.Add(_createButton);
        header.Margin = new Thickness(CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Lg);

        var scroll = new ScrollViewer
        {
            Content = _body,
            Padding = new Thickness(CTSpacing.Xl, 0, CTSpacing.Xl, CTSpacing.Xl),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        _body.Spacing = CTSpacing.Lg;

        _root.RowDefinitions = new RowDefinitions("Auto,*");
        _root.Background = CTColors.BackgroundBrush;
        _root.Children.Add(header);
        Grid.SetRow(scroll, 1);
        _root.Children.Add(scroll);
        Content = _root;

        App.PropertyChanged += OnAppPropertyChanged;
        AttachedToVisualTree += (_, _) => _ = LoadAsync();
        _lastDataContextKey = App.DataContextKey;

        Render();
    }

    public void OnActivated()
    {
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
            case nameof(AppState.UserPlaylists):
            case nameof(AppState.IsLoadingUserPlaylists):
            case nameof(AppState.LikesVersion):
            case nameof(AppState.NeedsReLogin):
                Post(Render);
                break;
        }
    }

    private void RefreshForDataContext()
    {
        var key = App.DataContextKey;
        if (key == _lastDataContextKey) return;
        _lastDataContextKey = key;
        _ = LoadAsync();
    }

    private async Task LoadAsync()
    {
        try
        {
            await App.LoadLikedSongsAsync();
            await App.LoadUserPlaylistsAsync();
        }
        catch (Exception error)
        {
            App.PublishWriteError(error);
        }
        Post(Render);
    }

    private void Render()
    {
        _createButton.IsVisible = App.CanPerformWrite;
        _subtitle.Text = App.IsLoggedIn
            ? (App.UserPlaylists.Count == 0 ? "收藏的旋律，都在这里。" : $"{App.UserPlaylists.Count} 个歌单 · {App.LikedSongs.Count} 首喜欢")
            : "收藏的旋律，都在这里。";
        _body.Children.Clear();

        if (!App.IsLoggedIn)
        {
            _body.Children.Add(UIComponents.StatusPanel("登录后查看我的音乐"));
            return;
        }

        if (App.IsLoadingUserPlaylists && App.UserPlaylists.Count == 0)
        {
            _body.Children.Add(UIComponents.StatusPanel("加载中…", showSpinner: true));
            return;
        }

        if (App.UserPlaylists.Count == 0)
        {
            _body.Children.Add(UIComponents.StatusPanel("还没有创建歌单"));
            if (App.CanPerformWrite)
            {
                var button = new Button
                {
                    Content = "新建歌单",
                    Classes = { "accent" },
                    HorizontalAlignment = HorizontalAlignment.Center,
                };
                button.Click += (_, _) => ShowCreatePlaylistDialog();
                _body.Children.Add(button);
            }
            return;
        }

        var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
        wrap.Children.Add(BuildLikedCard());
        foreach (var playlist in App.UserPlaylists)
        {
            wrap.Children.Add(BuildPlaylistCard(playlist));
        }
        _body.Children.Add(wrap);
    }

    private Button BuildLikedCard()
    {
        var stack = new StackPanel { Spacing = CTSpacing.Sm, Width = 160 };
        stack.Children.Add(new Border
        {
            Width = 160,
            Height = 160,
            CornerRadius = new CornerRadius(CTRadius.Medium),
            Background = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
                EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
                GradientStops =
                {
                    new GradientStop(Color.Parse("#D966C6"), 0),
                    new GradientStop(Color.Parse("#5A7BE0"), 1),
                },
            },
            Child = new TextBlock
            {
                Text = "\uEB52",
                FontFamily = IconFont,
                FontSize = 48,
                Foreground = Brushes.White,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        });
        stack.Children.Add(new TextBlock
        {
            Text = "我喜欢的音乐",
            FontWeight = FontWeight.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        stack.Children.Add(new TextBlock
        {
            Text = $"{App.LikedSongs.Count} 首",
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
        button.Click += (_, _) => App.SwitchToTopLevel(Page.Liked);
        return button;
    }

    private Button BuildPlaylistCard(PlaylistModel playlist)
    {
        var card = UIComponents.PlaylistCard(playlist, item => App.OpenPlaylist(item.Id));
        card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
        var menu = new ContextMenu();
        menu.Items.Add(MenuItem("打开", () => App.OpenPlaylist(playlist.Id)));
        menu.Items.Add(MenuItem("重命名", () => ShowRenameDialog(playlist)));
        menu.Items.Add(MenuItem("删除", () => ShowDeleteDialog(playlist)));
        card.ContextMenu = menu;
        return card;
    }

    private void ShowCreatePlaylistDialog()
    {
        _ = ShowNameDialogAsync("新建歌单", "", true, async (name, isPrivate) =>
        {
            var created = await App.CreatePlaylistAsync(name, isPrivate);
            return created is not null;
        });
    }

    private void ShowRenameDialog(PlaylistModel playlist)
    {
        _ = ShowNameDialogAsync("重命名歌单", playlist.Name, false,
            async (name, _) => await App.RenamePlaylistAsync(playlist, name));
    }

    private void ShowDeleteDialog(PlaylistModel playlist)
    {
        _ = ShowConfirmDialogAsync("删除歌单", $"确定要删除「{playlist.Name}」吗？此操作不可撤销。", "删除",
            async () => await App.DeletePlaylistAsync(playlist));
    }

    private Task ShowNameDialogAsync(string title, string initial, bool allowPrivate, Func<string, bool, Task<bool>> onSubmit)
    {
        var panel = new StackPanel { Spacing = CTSpacing.Lg, Width = 380 };
        panel.Children.Add(new TextBlock { Text = title, Classes = { "sectionTitle" } });

        var box = new TextBox { Text = initial, Watermark = "歌单名称", MaxLength = 40 };
        panel.Children.Add(box);

        var privateSwitch = new ToggleSwitch
        {
            Content = "隐私歌单（不公开显示）",
            IsChecked = false,
            IsVisible = allowPrivate,
        };
        panel.Children.Add(privateSwitch);

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
            var ok = await onSubmit(name, privateSwitch.IsChecked == true);
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

    private Border BuildScrim(Control card) => new()
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
