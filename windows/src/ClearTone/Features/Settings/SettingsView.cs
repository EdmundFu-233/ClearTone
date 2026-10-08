using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Styling;
using ClearTone.Core.Models;
using ClearTone.Core.Persistence;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Playback;
using ClearTone.Shell;

namespace ClearTone.Features.Settings;

[PageView(Page.Settings)]
public sealed class SettingsView : UserControl, IPageView
{
    private static AppState App => AppState.Shared;

    private readonly Grid _root = new();
    private readonly StackPanel _body = new() { Spacing = CTSpacing.Xl };
    private readonly ComboBox _themeBox = new();
    private readonly CheckBox _resumeBox = new() { Content = "启动时恢复上次播放" };
    private readonly CheckBox _cacheBox = new() { Content = "缓存播放的音乐（128kbps OPUS）" };
    private readonly ComboBox _qualityBox = new();
    private readonly ComboBox _closeBox = new();
    private readonly TextBlock _closeHint = new() { Classes = { "secondary" }, TextWrapping = TextWrapping.Wrap };
    private readonly NumericUpDown _offsetBox = new()
    {
        Minimum = -10,
        Maximum = 10,
        Increment = 0.1m,
        FormatString = "0.0",
        Width = 120,
    };
    private readonly TextBlock _offsetDescription = new() { Classes = { "secondary" } };
    private readonly TextBlock _cacheSizeText = new() { Classes = { "secondary" } };
    private readonly Button _clearCacheButton = new() { Content = "清空缓存" };
    private readonly TextBlock _accountText = new();
    private readonly Button _logoutButton = new() { Content = "退出登录" };
    private readonly TextBlock _saveHint = new() { Classes = { "secondary" }, VerticalAlignment = VerticalAlignment.Center };

    private AppSettings _settings = new();

    public SettingsView()
    {
        _themeBox.ItemsSource = new List<string> { "跟随系统", "深色", "浅色" };
        _closeBox.ItemsSource = Enum.GetValues<CloseBehavior>().Select(behavior => behavior.DisplayName()).ToList();

        var titleStack = new StackPanel { Spacing = CTSpacing.Xs };
        titleStack.Children.Add(new TextBlock { Text = "设置", Classes = { "pageTitle" } });
        titleStack.Children.Add(new TextBlock { Text = "外观、播放与账号。", Classes = { "secondary" } });

        var save = new Button { Content = "保存设置", Classes = { "accent" }, VerticalAlignment = VerticalAlignment.Center };
        save.Click += (_, _) => Save();

        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto") };
        header.Children.Add(titleStack);
        Grid.SetColumn(_saveHint, 1);
        _saveHint.Margin = new Thickness(0, 0, CTSpacing.Md, 0);
        header.Children.Add(_saveHint);
        Grid.SetColumn(save, 2);
        header.Children.Add(save);
        header.Margin = new Thickness(CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Lg);

        BuildSections();

        var scroll = new ScrollViewer
        {
            Content = _body,
            Padding = new Thickness(CTSpacing.Xl, 0, CTSpacing.Xl, CTSpacing.Xl),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };

        _root.RowDefinitions = new RowDefinitions("Auto,*");
        _root.Background = CTColors.BackgroundBrush;
        _root.Children.Add(header);
        Grid.SetRow(scroll, 1);
        _root.Children.Add(scroll);
        Content = _root;

        _closeBox.SelectionChanged += (_, _) => UpdateCloseHint();
        _offsetBox.ValueChanged += (_, _) => UpdateOffsetDescription();
        _clearCacheButton.Click += (_, _) => ClearCache();
        _logoutButton.Click += (_, _) => _ = LogoutAsync();

        LoadSettings();
    }

    public void OnActivated()
    {
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        LoadSettings();
    }

    private void BuildSections()
    {
        var appearance = new StackPanel { Spacing = CTSpacing.Md };
        appearance.Children.Add(Labeled("主题", _themeBox));
        appearance.Children.Add(new TextBlock
        {
            Text = "深色与浅色只影响应用外观，随时可以改回跟随系统。",
            Classes = { "secondary" },
            TextWrapping = TextWrapping.Wrap,
        });
        _body.Children.Add(Section("外观", appearance));

        var playback = new StackPanel { Spacing = CTSpacing.Md };
        playback.Children.Add(_resumeBox);
        playback.Children.Add(new TextBlock
        {
            Text = "启动时接着上次的位置继续播放，而不是从队列第一首开始。",
            Classes = { "secondary" },
            TextWrapping = TextWrapping.Wrap,
        });
        playback.Children.Add(new Border { Height = 1, Background = CTColors.OverlayBrush });
        playback.Children.Add(Labeled("默认音质", _qualityBox));
        playback.Children.Add(new TextBlock
        {
            Text = "只对本地没有缓存、必须走在线流的歌曲生效。选「自动」时按会员状态决定：VIP 走无损，否则走极高。",
            Classes = { "secondary" },
            TextWrapping = TextWrapping.Wrap,
        });
        playback.Children.Add(new Border { Height = 1, Background = CTColors.OverlayBrush });
        playback.Children.Add(_cacheBox);
        playback.Children.Add(new TextBlock
        {
            Text = "听过的网易云歌曲会转成缓存，再次播放优先使用；单条最多保留 7 天，过期后重新拉流。",
            Classes = { "secondary" },
            TextWrapping = TextWrapping.Wrap,
        });
        var cacheRow = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        cacheRow.Children.Add(_cacheSizeText);
        Grid.SetColumn(_clearCacheButton, 1);
        cacheRow.Children.Add(_clearCacheButton);
        playback.Children.Add(cacheRow);
        _body.Children.Add(Section("播放", playback));

        var window = new StackPanel { Spacing = CTSpacing.Md };
        window.Children.Add(Labeled("关闭窗口时", _closeBox));
        window.Children.Add(_closeHint);
        _body.Children.Add(Section("窗口", window));

        var lyrics = new StackPanel { Spacing = CTSpacing.Md };
        var offsetRow = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto") };
        offsetRow.Children.Add(new TextBlock { Text = "时间偏移", VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(_offsetBox, 1);
        _offsetBox.Margin = new Thickness(0, 0, CTSpacing.Md, 0);
        offsetRow.Children.Add(_offsetBox);
        Grid.SetColumn(_offsetDescription, 2);
        _offsetDescription.VerticalAlignment = VerticalAlignment.Center;
        offsetRow.Children.Add(_offsetDescription);
        lyrics.Children.Add(offsetRow);
        lyrics.Children.Add(new TextBlock
        {
            Text = "字幕比音频早或晚时在这里微调。正值表示歌词提前。",
            Classes = { "secondary" },
            TextWrapping = TextWrapping.Wrap,
        });
        _body.Children.Add(Section("歌词", lyrics));

        var account = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        account.Children.Add(_accountText);
        Grid.SetColumn(_logoutButton, 1);
        account.Children.Add(_logoutButton);
        _body.Children.Add(Section("账号", account));

        var about = new StackPanel { Spacing = CTSpacing.Xs };
        about.Children.Add(new TextBlock { Text = VersionText() });
        about.Children.Add(new TextBlock
        {
            Text = "第三方网易云音乐客户端，与网易公司无关联",
            Classes = { "secondary" },
            TextWrapping = TextWrapping.Wrap,
        });
        _body.Children.Add(Section("关于", about));
    }

    private void LoadSettings()
    {
        _settings = PersistenceStore.Shared.LoadSetting<AppSettings>("appSettings") ?? new AppSettings();
        _themeBox.SelectedIndex = (int)_settings.ThemeMode;
        _resumeBox.IsChecked = _settings.ResumePlaybackOnLaunch;
        _cacheBox.IsChecked = _settings.AudioCacheEnabled;
        _qualityBox.ItemsSource = BuildQualityItems();
        _qualityBox.SelectedIndex = QualityIndex(_settings.PreferredQuality);
        _closeBox.SelectedIndex = (int)_settings.CloseBehavior;
        _offsetBox.Value = (decimal)_settings.LyricOffset;
        _saveHint.Text = "";
        _logoutButton.IsVisible = App.IsLoggedIn;
        UpdateAccountText();
        UpdateCloseHint();
        UpdateOffsetDescription();
        UpdateCacheSize();
    }

    private static List<string> BuildQualityItems()
    {
        var items = new List<string> { AutoQualityLabel() };
        items.AddRange(SongQualityPolicy.SelectableLevels.Select(level => level.DisplayName()));
        return items;
    }

    private static string AutoQualityLabel()
    {
        var resolved = SongQualityPolicy.DefaultLevel(PlayerController.Shared.IsAccountVIP);
        return PlayerController.Shared.IsAccountVIP
            ? $"自动（VIP → {resolved.DisplayName()}）"
            : $"自动（{resolved.DisplayName()}）";
    }

    private static int QualityIndex(QualityLevel level)
    {
        if (level == SongQualityPolicy.AutoLevel) return 0;
        var levels = SongQualityPolicy.SelectableLevels;
        for (var index = 0; index < levels.Count; index++)
        {
            if (levels[index] == level) return index + 1;
        }
        return 0;
    }

    private static QualityLevel QualityFromIndex(int index)
    {
        if (index <= 0) return SongQualityPolicy.AutoLevel;
        var levels = SongQualityPolicy.SelectableLevels;
        return index - 1 < levels.Count ? levels[index - 1] : SongQualityPolicy.AutoLevel;
    }

    private void Save()
    {
        _settings.ThemeMode = (CTThemeMode)Math.Clamp(_themeBox.SelectedIndex, 0, 2);
        _settings.ResumePlaybackOnLaunch = _resumeBox.IsChecked == true;
        _settings.AudioCacheEnabled = _cacheBox.IsChecked == true;
        _settings.PreferredQuality = QualityFromIndex(_qualityBox.SelectedIndex);
        _settings.CloseBehavior = (CloseBehavior)Math.Clamp(_closeBox.SelectedIndex, 0, 2);
        _settings.LyricOffset = (double)(_offsetBox.Value ?? 0m);
        PersistenceStore.Shared.SaveSetting(_settings, "appSettings");
        AudioCacheManager.Shared.IsEnabled = _settings.AudioCacheEnabled;
        PlayerController.Shared.SetRequestedQuality(_settings.PreferredQuality);
        ApplyTheme(_settings.ThemeMode);
        _saveHint.Text = "已保存";
    }

    private static void ApplyTheme(CTThemeMode mode)
    {
        if (Application.Current is not { } app) return;
        app.RequestedThemeVariant = mode switch
        {
            CTThemeMode.Dark => ThemeVariant.Dark,
            CTThemeMode.Light => ThemeVariant.Light,
            _ => ThemeVariant.Default,
        };
    }

    private void ClearCache()
    {
        AudioCacheManager.Shared.ClearAll();
        UpdateCacheSize();
    }

    private void UpdateCacheSize()
    {
        _cacheSizeText.Text = $"缓存占用：{AudioCacheManager.Shared.FormattedTotalSize}";
        _clearCacheButton.IsEnabled = AudioCacheManager.Shared.TotalCacheBytes > 0;
    }

    private void UpdateCloseHint()
    {
        var behavior = (CloseBehavior)Math.Clamp(_closeBox.SelectedIndex, 0, 2);
        _closeHint.Text = behavior.Help();
    }

    private void UpdateOffsetDescription()
    {
        var value = (double)(_offsetBox.Value ?? 0m);
        if (Math.Abs(value) < 0.001)
        {
            _offsetDescription.Text = "0.0 秒";
        }
        else if (value > 0)
        {
            _offsetDescription.Text = $"提前 {value:0.0} 秒";
        }
        else
        {
            _offsetDescription.Text = $"延后 {-value:0.0} 秒";
        }
    }

    private void UpdateAccountText()
    {
        _accountText.Text = App.IsLoggedIn
            ? (App.Account?.Nickname ?? "已登录")
            : "未登录";
    }

    private async Task LogoutAsync()
    {
        await App.PerformLogoutAsync().ConfigureAwait(true);
        _logoutButton.IsVisible = App.IsLoggedIn;
        UpdateAccountText();
    }

    private static Control Labeled(string label, Control control)
    {
        var panel = new StackPanel { Spacing = 4 };
        panel.Children.Add(new TextBlock { Text = label, FontWeight = FontWeight.Medium });
        panel.Children.Add(control);
        return panel;
    }

    private static Control Section(string title, Control content)
    {
        var panel = new StackPanel { Spacing = CTSpacing.Sm };
        panel.Children.Add(new TextBlock { Text = title, Classes = { "sectionTitle" } });
        panel.Children.Add(new Border
        {
            Background = CTColors.PanelBrush,
            CornerRadius = new CornerRadius(CTRadius.Medium),
            Padding = new Thickness(CTSpacing.Lg),
            Child = content,
        });
        return panel;
    }

    private static string VersionText()
    {
        var version = typeof(ClearTone.App).Assembly.GetName().Version;
        if (version is null) return "澄音 v0.1.0";
        var build = version.Build >= 0 ? version.Build : 0;
        return $"澄音 v{version.Major}.{version.Minor}.{build}";
    }
}
