using System.ComponentModel;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using ClearTone.Core.Models;
using ClearTone.Core.Persistence;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Playback;
using ClearTone.Shell;

namespace ClearTone;

public partial class MainWindow : Window
{
    public PlayerBarModel Bar { get; } = new();
    public AppState App => AppState.Shared;
    private static PlayerController Player => PlayerController.Shared;

    private bool _syncingSidebar;
    private bool _progressDragging;
    private bool _syncingVolume;
    private bool _startupCompleted;

    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;

        BuildSidebarItems();
        BuildPlaylists();
        ShowPage(App.CurrentPage);
        SyncSidebarSelection();
        UpdateAccountArea();
        UpdateMuteGlyph();

        ProgressSlider.AddHandler(PointerPressedEvent, OnProgressPointerPressed, RoutingStrategies.Tunnel);
        ProgressSlider.AddHandler(PointerReleasedEvent, OnProgressPointerReleased, RoutingStrategies.Tunnel);
        ProgressSlider.PropertyChanged += OnProgressPropertyChanged;
        VolumeSlider.PropertyChanged += OnVolumePropertyChanged;
        AddHandler(KeyDownEvent, OnWindowKeyDown, RoutingStrategies.Tunnel);

        App.PropertyChanged += OnAppPropertyChanged;
        Player.PropertyChanged += OnPlayerPropertyChanged;

        NowPlayingHost.Content = PageFactory.ResolveOverlay(OverlayKind.NowPlaying);
        QueueHost.Content = PageFactory.ResolveOverlay(OverlayKind.Queue);
        LoginHost.Content = PageFactory.ResolveOverlay(OverlayKind.Login);
    }

    protected override async void OnOpened(EventArgs e)
    {
        base.OnOpened(e);
        TrayIconManager.RefreshVisibility();
        if (_startupCompleted) return;
        _startupCompleted = true;
        try
        {
            MediaSessionIntegration.Initialize(this);
            _ = Task.Run(() => Core.Networking.HelperProcessManager.Shared.StartAsync());
            await App.RestoreLoginStateAsync();
            Player.ResumeFromPersistence();
        }
        catch (Exception error)
        {
            Core.Logging.CTLog.General.Error($"启动初始化失败: {error.CtUserMessage()}");
        }
    }

    protected override void OnClosing(WindowClosingEventArgs e)
    {
        if (e.CloseReason != WindowCloseReason.ApplicationShutdown)
        {
            var settings = PersistenceStore.Shared.LoadSetting<AppSettings>("appSettings") ?? new AppSettings();
            if (!CloseBehaviorPolicy.ShouldQuitOnClose(settings))
            {
                e.Cancel = true;
                Hide();
                TrayIconManager.RefreshVisibility();
                return;
            }
        }
        base.OnClosing(e);
    }

    private void BuildSidebarItems()
    {
        SidebarList.Items.Clear();
        foreach (var page in PageExtensions.SidebarPages)
        {
            SidebarList.Items.Add(new ListBoxItem
            {
                Tag = page,
                Content = new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Spacing = 10,
                    Children =
                    {
                        new TextBlock
                        {
                            Text = page.Glyph(),
                            FontFamily = new FontFamily("Segoe MDL2 Assets, Segoe Fluent Icons"),
                            FontSize = 15,
                            VerticalAlignment = VerticalAlignment.Center,
                        },
                        new TextBlock
                        {
                            Text = page.DisplayName(),
                            VerticalAlignment = VerticalAlignment.Center,
                        },
                    },
                },
            });
        }
    }

    private void BuildPlaylists()
    {
        PlaylistPanel.Children.Clear();
        foreach (var playlist in App.UserPlaylists.Take(200))
        {
            var button = new Button
            {
                Content = new TextBlock
                {
                    Text = playlist.Name,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
                Background = Brushes.Transparent,
                BorderThickness = new Avalonia.Thickness(0),
                Padding = new Avalonia.Thickness(10, 5),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            var id = playlist.Id;
            button.Click += (_, _) => App.OpenPlaylist(id);
            PlaylistPanel.Children.Add(button);
        }
    }

    private void ShowPage(Page page)
    {
        PageTitleText.Text = page.DisplayName();
        MainContent.Content = PageFactory.Resolve(page);
        BackButton.IsVisible = App.CanGoBack;
    }

    private void SyncSidebarSelection()
    {
        _syncingSidebar = true;
        try
        {
            ListBoxItem? match = null;
            foreach (var item in SidebarList.Items.OfType<ListBoxItem>())
            {
                if (item.Tag is Page page && page == App.CurrentPage) match = item;
            }
            SidebarList.SelectedItem = match;
        }
        finally
        {
            _syncingSidebar = false;
        }
    }

    private void UpdateAccountArea()
    {
        var account = App.Account;
        AccountNameText.Text = account?.Nickname ?? "未登录";
        AccountHintText.Text = account is null
            ? "点击扫码登录"
            : account.IsVIP ? "VIP 会员" : "已登录";
        AccountGlyph.Text = account?.IsVIP == true ? "\uE735" : "\uE77B";
    }

    private void UpdateMuteGlyph()
    {
        MuteButton.Content = Player.IsMuted || Player.Volume <= 0.001f ? "\uE74F" : "\uE767";
    }

    private void OnAppPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppState.CurrentPage):
                ShowPage(App.CurrentPage);
                SyncSidebarSelection();
                break;
            case nameof(AppState.CanGoBack):
                BackButton.IsVisible = App.CanGoBack;
                break;
            case nameof(AppState.UserPlaylists):
                BuildPlaylists();
                break;
            case nameof(AppState.Account):
            case nameof(AppState.IsLoggedIn):
                UpdateAccountArea();
                break;
        }
    }

    private void OnPlayerPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PlayerController.IsMuted) or nameof(PlayerController.Volume))
        {
            UpdateMuteGlyph();
        }
        if (e.PropertyName == nameof(PlayerController.SleepTimerRemaining))
        {
            UpdateSleepButton();
        }
    }

    private void OnWindowKeyDown(object? sender, KeyEventArgs e)
    {
        var modifiers = e.KeyModifiers;
        var ctrl = (modifiers & KeyModifiers.Control) != 0;
        var shift = (modifiers & KeyModifiers.Shift) != 0;
        var alt = (modifiers & KeyModifiers.Alt) != 0;

        if (modifiers == KeyModifiers.None && e.Key == Key.Space)
        {
            if (IsTextInputFocused()) return;
            e.Handled = true;
            Player.TogglePlayPause();
            return;
        }

        if (!ctrl || alt) return;

        if (shift)
        {
            switch (e.Key)
            {
                case Key.D0:
                case Key.NumPad0:
                    e.Handled = true;
                    App.ShowQueue = !App.ShowQueue;
                    return;
                case Key.L:
                    e.Handled = true;
                    Player.CyclePlayMode();
                    return;
                case Key.D:
                    e.Handled = true;
                    _ = ToggleCurrentLikeAsync();
                    return;
                case Key.M:
                    e.Handled = true;
                    MiniPlayerWindow.Toggle();
                    return;
                case Key.OemCloseBrackets:
                    e.Handled = true;
                    Player.SeekBy(-15);
                    return;
                default:
                    return;
            }
        }

        switch (e.Key)
        {
            case Key.F:
                e.Handled = true;
                App.SwitchToTopLevel(Page.Search);
                return;
            case Key.OemComma:
                e.Handled = true;
                App.SwitchToTopLevel(Page.Settings);
                return;
            case Key.OemOpenBrackets:
                e.Handled = true;
                App.GoBack();
                return;
            case Key.P:
                e.Handled = true;
                Player.TogglePlayPause();
                return;
            case Key.Right:
                e.Handled = true;
                Player.Next();
                return;
            case Key.Left:
                e.Handled = true;
                Player.Previous();
                return;
            case Key.OemCloseBrackets:
                e.Handled = true;
                Player.SeekBy(15);
                return;
            case Key.Up:
                e.Handled = true;
                Player.Volume = Math.Min(1f, Player.Volume + 0.1f);
                if (Player.Volume > 0.001f) Player.IsMuted = false;
                return;
            case Key.Down:
                e.Handled = true;
                Player.Volume = Math.Max(0f, Player.Volume - 0.1f);
                if (Player.Volume > 0.001f) Player.IsMuted = false;
                return;
        }

        if (DigitForKey(e.Key) is { } digit && SwitchToSidebar(digit))
        {
            e.Handled = true;
        }
    }

    private bool IsTextInputFocused() =>
        TopLevel.GetTopLevel(this)?.FocusManager?.GetFocusedElement() is TextBox;

    private static char? DigitForKey(Key key) => key switch
    {
        Key.D0 or Key.NumPad0 => '0',
        Key.D1 or Key.NumPad1 => '1',
        Key.D2 or Key.NumPad2 => '2',
        Key.D3 or Key.NumPad3 => '3',
        Key.D4 or Key.NumPad4 => '4',
        Key.D5 or Key.NumPad5 => '5',
        Key.D6 or Key.NumPad6 => '6',
        Key.D7 or Key.NumPad7 => '7',
        Key.D8 or Key.NumPad8 => '8',
        Key.D9 or Key.NumPad9 => '9',
        _ => null,
    };

    private bool SwitchToSidebar(char digit)
    {
        var pages = PageExtensions.SidebarPages;
        for (var index = 0; index < pages.Length; index++)
        {
            if (SidebarShortcuts.KeyForIndex(index) != digit) continue;
            App.SwitchToTopLevel(pages[index]);
            return true;
        }
        return false;
    }

    private async Task ToggleCurrentLikeAsync()
    {
        var song = Player.CurrentSong;
        if (song is null || !App.CanPerformWrite) return;
        await App.ToggleLikeAsync(song);
        Bar.NotifyLike();
    }

    private void OnSleepClick(object? sender, RoutedEventArgs e)
    {
        var menu = new MenuFlyout();
        foreach (var minutes in new[] { 15, 30, 45, 60, 90 })
        {
            var item = new MenuItem { Header = $"{minutes} 分钟" };
            var captured = minutes;
            item.Click += (_, _) => Player.SetSleepTimer(captured);
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());
        var cancel = new MenuItem { Header = "关闭定时器" };
        cancel.Click += (_, _) => Player.SetSleepTimer(0);
        menu.Items.Add(cancel);
        menu.ShowAt(SleepButton);
    }

    private void UpdateSleepButton()
    {
        var remaining = Player.SleepTimerRemaining;
        SleepButton.Content = remaining > 0
            ? $"{Math.Max(1, (int)Math.Ceiling(remaining / 60.0))} 分钟"
            : "\uE916";
    }

    private void OnSidebarSelectionChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (_syncingSidebar) return;
        if (SidebarList.SelectedItem is ListBoxItem { Tag: Page page })
        {
            App.SwitchToTopLevel(page);
        }
    }

    private void OnProgressPropertyChanged(object? sender, Avalonia.AvaloniaPropertyChangedEventArgs e)
    {
        if (e.Property != RangeBase.ValueProperty) return;
        if (!_progressDragging) return;
        var duration = Player.Duration;
        if (duration <= 0) return;
        Player.PreviewSeek(ProgressSlider.Value / 100.0 * duration);
    }

    private void OnProgressPointerPressed(object? sender, PointerPressedEventArgs e) => _progressDragging = true;

    private void OnProgressPointerReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (!_progressDragging) return;
        _progressDragging = false;
        var duration = Player.Duration;
        if (duration > 0)
        {
            Player.CommitSeek(ProgressSlider.Value / 100.0 * duration);
        }
    }

    private void OnVolumePropertyChanged(object? sender, Avalonia.AvaloniaPropertyChangedEventArgs e)
    {
        if (e.Property != RangeBase.ValueProperty) return;
        if (_syncingVolume) return;
        _syncingVolume = true;
        Player.Volume = (float)(VolumeSlider.Value / 100.0);
        if (Player.Volume > 0.001f) Player.IsMuted = false;
        _syncingVolume = false;
        UpdateMuteGlyph();
    }

    private void OnPlayPauseClick(object? sender, RoutedEventArgs e) => Player.TogglePlayPause();

    private void OnPrevClick(object? sender, RoutedEventArgs e) => Player.Previous();

    private void OnNextClick(object? sender, RoutedEventArgs e) => Player.Next();

    private void OnModeClick(object? sender, RoutedEventArgs e) => Player.CyclePlayMode();

    private void OnMuteClick(object? sender, RoutedEventArgs e)
    {
        Player.IsMuted = !Player.IsMuted;
        UpdateMuteGlyph();
    }

    private void OnRateClick(object? sender, RoutedEventArgs e)
    {
        var menu = new MenuFlyout();
        foreach (var rate in PlayerController.AvailableRates)
        {
            var item = new MenuItem
            {
                Header = PlayerController.RateLabel(rate),
                ToggleType = MenuItemToggleType.Radio,
                IsChecked = Math.Abs(Player.PlaybackRate - rate) < 0.001f,
            };
            var captured = rate;
            item.Click += (_, _) =>
            {
                Player.SetPlaybackRate(captured);
                Bar.RefreshRate();
            };
            menu.Items.Add(item);
        }
        menu.ShowAt(RateButton);
    }

    private void OnQualityClick(object? sender, RoutedEventArgs e)
    {
        var levels = SongQualityPolicy.SelectableLevels;
        var current = Player.RequestedQuality;
        var index = -1;
        for (var i = 0; i < levels.Count; i++)
        {
            if (levels[i] == current) index = i;
        }
        var next = levels[(index + 1 + levels.Count) % levels.Count];
        Player.SetRequestedQuality(next);
    }

    private async void OnLikeClick(object? sender, RoutedEventArgs e)
    {
        var song = Player.CurrentSong;
        if (song is null) return;
        await App.ToggleLikeAsync(song);
        Bar.NotifyLike();
    }

    private void OnExpandClick(object? sender, RoutedEventArgs e) => App.IsNowPlayingExpanded = true;

    private void OnCollapseClick(object? sender, RoutedEventArgs e) => App.IsNowPlayingExpanded = false;

    private void OnQueueClick(object? sender, RoutedEventArgs e) => App.ShowQueue = true;

    private void OnQueueCloseClick(object? sender, RoutedEventArgs e) => App.ShowQueue = false;

    private void OnBackClick(object? sender, RoutedEventArgs e) => App.GoBack();

    private void OnSettingsClick(object? sender, RoutedEventArgs e) => App.SwitchToTopLevel(Page.Settings);

    private void OnAccountClick(object? sender, RoutedEventArgs e)
    {
        if (App.Account is null)
        {
            App.IsLoginPresented = true;
        }
        else
        {
            App.SwitchToTopLevel(Page.Profile);
        }
    }
}
