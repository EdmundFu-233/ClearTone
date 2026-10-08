using System.ComponentModel;
using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using ClearTone.Controls;
using ClearTone.Core.Lyrics;
using ClearTone.Core.Models;
using ClearTone.Core.Persistence;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Playback;
using ClearTone.Providers.Netease;
using ClearTone.Shell;

namespace ClearTone.Features.NowPlaying;

[OverlayView(OverlayKind.NowPlaying)]
public sealed class NowPlayingView : UserControl
{
    private static AppState App => AppState.Shared;
    private static PlayerController Player => PlayerController.Shared;
    private static readonly FontFamily IconFont = new("Segoe MDL2 Assets, Segoe Fluent Icons");

    private static readonly IBrush PrimaryText = new SolidColorBrush(Color.Parse("#F4F4F6"));
    private static readonly IBrush SecondaryText = new SolidColorBrush(Color.Parse("#AEB3BF"));
    private static readonly IBrush FaintText = new SolidColorBrush(Color.Parse("#73FFFFFF"));
    private static readonly IBrush AccentText = new SolidColorBrush(CTColors.DarkAccent);

    private readonly LyricsSession _lyrics = LyricsSession.NeteaseOnly();

    private readonly CoverImage _cover = new()
    {
        Width = 300,
        Height = 300,
        CornerRadius = new CornerRadius(CTRadius.Large),
        DecodeWidth = 600,
        HorizontalAlignment = HorizontalAlignment.Center,
    };

    private readonly TextBlock _titleText = new()
    {
        Text = "未在播放",
        FontSize = 26,
        FontWeight = FontWeight.Bold,
        Foreground = PrimaryText,
        TextTrimming = TextTrimming.CharacterEllipsis,
        MaxWidth = 360,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private readonly Button _likeButton = new()
    {
        Classes = { "toolbar" },
        FontFamily = IconFont,
        FontSize = 20,
        Foreground = SecondaryText,
    };

    private readonly Button _artistButton = new()
    {
        Content = "未知艺术家",
        Background = Brushes.Transparent,
        BorderThickness = new Thickness(0),
        Foreground = SecondaryText,
        Padding = new Thickness(0),
        FontSize = 16,
        HorizontalAlignment = HorizontalAlignment.Center,
    };

    private readonly TextBlock _sourceText = new()
    {
        FontSize = 12,
        Foreground = SecondaryText,
        HorizontalAlignment = HorizontalAlignment.Center,
    };

    private readonly Button _modeButton = new()
    {
        Classes = { "toolbar" },
        FontFamily = IconFont,
        FontSize = 16,
        Foreground = PrimaryText,
    };

    private readonly Button _previousButton = new()
    {
        Classes = { "toolbar" },
        FontFamily = IconFont,
        FontSize = 18,
        Foreground = PrimaryText,
        Content = "\uE892",
    };

    private readonly Button _playPauseButton = new()
    {
        Classes = { "toolbar" },
        FontFamily = IconFont,
        FontSize = 36,
        Foreground = AccentText,
        Content = "\uE768",
    };

    private readonly Button _nextButton = new()
    {
        Classes = { "toolbar" },
        FontFamily = IconFont,
        FontSize = 18,
        Foreground = PrimaryText,
        Content = "\uE893",
    };

    private readonly Button _muteButton = new()
    {
        Classes = { "toolbar" },
        FontFamily = IconFont,
        FontSize = 15,
        Foreground = PrimaryText,
        Content = "\uE767",
    };

    private readonly Button _qualityButton = new()
    {
        Classes = { "toolbar" },
        FontSize = 12,
        Foreground = PrimaryText,
        Content = "音质",
    };

    private readonly Slider _progress = new()
    {
        Minimum = 0,
        Maximum = 100,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private readonly Slider _volume = new()
    {
        Minimum = 0,
        Maximum = 100,
        Width = 130,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private readonly TextBlock _currentTimeText = new()
    {
        Foreground = SecondaryText,
        FontSize = 12,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private readonly TextBlock _durationText = new()
    {
        Foreground = SecondaryText,
        FontSize = 12,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private readonly ToggleButton _translationToggle = new()
    {
        Content = "翻译",
        FontSize = 12,
        IsChecked = true,
    };

    private readonly ToggleButton _romanizationToggle = new()
    {
        Content = "音译",
        FontSize = 12,
    };

    private readonly TextBlock _offsetText = new()
    {
        Text = "0.0s",
        FontSize = 12,
        Foreground = SecondaryText,
        MinWidth = 64,
        TextAlignment = TextAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private readonly Button _offsetDecrease = new()
    {
        Classes = { "toolbar" },
        Content = "-",
        FontSize = 12,
        Foreground = PrimaryText,
    };

    private readonly Button _offsetIncrease = new()
    {
        Classes = { "toolbar" },
        Content = "+",
        FontSize = 12,
        Foreground = PrimaryText,
    };

    private readonly Button _offsetReset = new()
    {
        Classes = { "toolbar" },
        Content = "重置",
        FontSize = 12,
        Foreground = PrimaryText,
        IsVisible = false,
    };

    private readonly ScrollViewer _lyricScroll = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
    };

    private readonly Button _backToCurrentButton = new()
    {
        Classes = { "accent" },
        Content = L10n.Player.BackToCurrent,
        FontSize = 12,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Bottom,
        Margin = new Thickness(0, 0, 0, CTSpacing.Md),
        IsVisible = false,
    };

    private readonly StackPanel _lyricStack = new()
    {
        Spacing = CTSpacing.Md,
        Margin = new Thickness(CTSpacing.Sm, 0, CTSpacing.Md, 0),
    };

    private readonly Grid _lyricHost = new();
    private readonly TextBlock _lyricErrorText = new()
    {
        Foreground = SecondaryText,
        TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center,
        MaxWidth = 420,
    };

    private readonly Control _loadingPanel;
    private readonly Control _errorPanel;
    private readonly Control _purePanel;
    private readonly Control _emptyPanel;
    private readonly List<LyricRow> _rows = new();

    private double _lyricOffset;
    private int? _currentLineIndex;
    private DateTimeOffset _userScrollUntil = DateTimeOffset.MinValue;
    private bool _showTranslation = true;
    private bool _showRomanization;
    private bool _progressDragging;
    private bool _syncingProgress;
    private bool _syncingVolume;
    private CancellationTokenSource? _lyricsCts;

    public NowPlayingView()
    {
        _loadingPanel = BuildLoadingPanel();
        _errorPanel = BuildErrorPanel();
        _purePanel = BuildNoticePanel(L10n.Player.PureMusic);
        _emptyPanel = BuildNoticePanel(L10n.Player.NoLyrics);

        _lyricScroll.Content = _lyricStack;
        _lyricHost.Children.Add(_lyricScroll);
        _lyricHost.Children.Add(_loadingPanel);
        _lyricHost.Children.Add(_errorPanel);
        _lyricHost.Children.Add(_purePanel);
        _lyricHost.Children.Add(_emptyPanel);
        _lyricHost.Children.Add(_backToCurrentButton);

        _modeButton.Click += (_, _) => Player.CyclePlayMode();
        _previousButton.Click += (_, _) => Player.Previous();
        _playPauseButton.Click += (_, _) => Player.TogglePlayPause();
        _nextButton.Click += (_, _) => Player.Next();
        _muteButton.Click += (_, _) =>
        {
            Player.IsMuted = !Player.IsMuted;
            RefreshMuteGlyph();
        };
        _qualityButton.Click += (_, _) => ShowQualityMenu();
        _likeButton.Click += async (_, _) =>
        {
            var song = Player.CurrentSong;
            if (song is null) return;
            await App.ToggleLikeAsync(song);
            Refresh();
        };
        _artistButton.Click += (_, _) =>
        {
            var song = Player.CurrentSong;
            if (song is null || song.Artists.Count == 0) return;
            App.OpenArtist(song.Artists[0].Id);
            App.IsNowPlayingExpanded = false;
        };

        _translationToggle.IsCheckedChanged += (_, _) =>
        {
            _showTranslation = _translationToggle.IsChecked == true;
            UpdateRowVisibility();
        };
        _romanizationToggle.IsCheckedChanged += (_, _) =>
        {
            _showRomanization = _romanizationToggle.IsChecked == true;
            UpdateRowVisibility();
        };
        _backToCurrentButton.Click += (_, _) => BackToCurrentLyric();
        _lyricScroll.PointerWheelChanged += (_, _) => MarkUserScroll();
        _offsetDecrease.Click += (_, _) => AdjustOffset(-0.1);
        _offsetIncrease.Click += (_, _) => AdjustOffset(0.1);
        _offsetReset.Click += (_, _) => AdjustOffset(-_lyricOffset);

        _progress.AddHandler(PointerPressedEvent, OnProgressPointerPressed, RoutingStrategies.Tunnel);
        _progress.AddHandler(PointerReleasedEvent, OnProgressPointerReleased, RoutingStrategies.Tunnel);
        _progress.PropertyChanged += OnProgressPropertyChanged;
        _volume.PropertyChanged += OnVolumePropertyChanged;

        ToolTip.SetTip(_artistButton, "打开歌手");
        ToolTip.SetTip(_muteButton, "静音");
        ToolTip.SetTip(_qualityButton, "为这首歌指定音质");

        Content = BuildRoot();

        _lyricOffset = LoadOffset();
        UpdateOffsetUi();

        Player.PropertyChanged += OnPlayerPropertyChanged;
        Player.TimeUpdated += OnPlayerTimeUpdated;
        AudioCacheManager.Shared.StateChanged += OnCacheStateChanged;
        _lyrics.PropertyChanged += OnLyricsPropertyChanged;
        App.PropertyChanged += OnAppPropertyChanged;

        Refresh();
        LoadLyrics();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        _lyricsCts?.Cancel();
        _lyricsCts = null;
        base.OnDetachedFromVisualTree(e);
    }

    private Control BuildRoot()
    {
        var left = new StackPanel
        {
            Spacing = CTSpacing.Md,
            Margin = new Thickness(CTSpacing.Xl),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 460,
        };
        left.Children.Add(_cover);

        var titleRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Sm,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        titleRow.Children.Add(_titleText);
        titleRow.Children.Add(_likeButton);
        left.Children.Add(titleRow);
        left.Children.Add(_artistButton);
        left.Children.Add(_sourceText);

        var controls = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Lg,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        controls.Children.Add(_modeButton);
        controls.Children.Add(_previousButton);
        controls.Children.Add(_playPauseButton);
        controls.Children.Add(_nextButton);
        left.Children.Add(controls);

        var progressRow = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"),
            MaxWidth = 440,
        };
        progressRow.Children.Add(_currentTimeText);
        Grid.SetColumn(_progress, 1);
        _progress.Margin = new Thickness(CTSpacing.Sm, 0);
        progressRow.Children.Add(_progress);
        Grid.SetColumn(_durationText, 2);
        progressRow.Children.Add(_durationText);
        left.Children.Add(progressRow);

        var volumeRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Sm,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        volumeRow.Children.Add(_muteButton);
        volumeRow.Children.Add(_volume);
        volumeRow.Children.Add(_qualityButton);
        left.Children.Add(volumeRow);

        var right = new DockPanel
        {
            LastChildFill = true,
            Margin = new Thickness(0, CTSpacing.Lg, CTSpacing.Lg, CTSpacing.Lg),
        };

        var toolbar = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,Auto,*,Auto"),
            Margin = new Thickness(0, 0, 0, CTSpacing.Md),
        };
        toolbar.Children.Add(_translationToggle);
        Grid.SetColumn(_romanizationToggle, 1);
        _romanizationToggle.Margin = new Thickness(CTSpacing.Sm, 0, 0, 0);
        toolbar.Children.Add(_romanizationToggle);

        var offsetControls = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Xs,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        offsetControls.Children.Add(_offsetDecrease);
        offsetControls.Children.Add(_offsetText);
        offsetControls.Children.Add(_offsetIncrease);
        offsetControls.Children.Add(_offsetReset);
        Grid.SetColumn(offsetControls, 3);
        toolbar.Children.Add(offsetControls);

        DockPanel.SetDock(toolbar, Dock.Top);
        right.Children.Add(toolbar);
        right.Children.Add(_lyricHost);

        var root = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*") };
        root.Children.Add(left);
        Grid.SetColumn(right, 1);
        root.Children.Add(right);

        var close = new Button
        {
            Classes = { "toolbar" },
            FontFamily = IconFont,
            FontSize = 14,
            Foreground = PrimaryText,
            Content = "\uE711",
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(CTSpacing.Lg),
            ZIndex = 10,
        };
        ToolTip.SetTip(close, L10n.Common.Close);
        close.Click += (_, _) => App.IsNowPlayingExpanded = false;
        root.Children.Add(close);
        return root;
    }

    private Control BuildLoadingPanel()
    {
        var stack = new StackPanel
        {
            Spacing = CTSpacing.Md,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        stack.Children.Add(new ProgressBar { IsIndeterminate = true, Width = 160 });
        stack.Children.Add(new TextBlock
        {
            Text = L10n.Player.LoadingLyrics,
            Foreground = SecondaryText,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        return stack;
    }

    private Control BuildErrorPanel()
    {
        var stack = new StackPanel
        {
            Spacing = CTSpacing.Sm,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        stack.Children.Add(_lyricErrorText);
        var retry = new Button
        {
            Content = L10n.Common.Retry,
            Classes = { "accent" },
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        retry.Click += (_, _) => LoadLyrics();
        stack.Children.Add(retry);
        return stack;
    }

    private static Control BuildNoticePanel(string text) => new TextBlock
    {
        Text = text,
        FontSize = 18,
        Foreground = SecondaryText,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        TextAlignment = TextAlignment.Center,
    };

    private void OnAppPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppState.LikesVersion))
        {
            Post(Refresh);
        }
        else if (e.PropertyName == nameof(AppState.IsNowPlayingExpanded))
        {
            if (App.IsNowPlayingExpanded)
            {
                Post(() =>
                {
                    Refresh();
                    if (!_lyrics.IsLoading && _lyrics.ErrorMessage is null && !_lyrics.IsPureMusic && _lyrics.Lines.Count == 0)
                    {
                        LoadLyrics();
                    }
                });
            }
            else
            {
                _lyricsCts?.Cancel();
            }
        }
    }

    private void OnPlayerPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(PlayerController.CurrentSong))
        {
            Post(() =>
            {
                Refresh();
                LoadLyrics();
            });
            return;
        }

        if (e.PropertyName is nameof(PlayerController.Queue)
            or nameof(PlayerController.PlaybackState)
            or nameof(PlayerController.Duration)
            or nameof(PlayerController.Volume)
            or nameof(PlayerController.IsMuted)
            or nameof(PlayerController.ActualQuality)
            or nameof(PlayerController.IsCurrentFromCache)
            or nameof(PlayerController.RequestedQuality)
            or nameof(PlayerController.PreferredQuality)
            or nameof(PlayerController.IsAccountVIP))
        {
            Post(Refresh);
        }
    }

    private void OnLyricsPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(LyricsSession.Lines))
        {
            Post(RenderLyrics);
        }
        else if (e.PropertyName is nameof(LyricsSession.IsLoading)
            or nameof(LyricsSession.ErrorMessage)
            or nameof(LyricsSession.IsPureMusic))
        {
            Post(RenderLyricState);
        }
    }

    private void OnPlayerTimeUpdated(double time)
    {
        if (!Dispatcher.UIThread.CheckAccess())
        {
            Dispatcher.UIThread.Post(() => OnPlayerTimeUpdated(time));
            return;
        }

        _currentTimeText.Text = CTFormatting.Time(time);
        _durationText.Text = CTFormatting.Time(Player.Duration);
        if (!_progressDragging)
        {
            _syncingProgress = true;
            _progress.Value = Player.Duration > 0
                ? Math.Clamp(time / Player.Duration * 100, 0, 100)
                : 0;
            _syncingProgress = false;
        }
        UpdateCurrentLyric(time);
        UpdateWordProgress(time);
    }

    private void OnProgressPointerPressed(object? sender, PointerPressedEventArgs e) => _progressDragging = true;

    private void OnProgressPointerReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (!_progressDragging) return;
        _progressDragging = false;
        if (Player.Duration > 0)
        {
            Player.CommitSeek(_progress.Value / 100.0 * Player.Duration);
        }
    }

    private void OnProgressPropertyChanged(object? sender, AvaloniaPropertyChangedEventArgs e)
    {
        if (e.Property != RangeBase.ValueProperty) return;
        if (!_progressDragging || _syncingProgress) return;
        if (Player.Duration > 0)
        {
            Player.PreviewSeek(_progress.Value / 100.0 * Player.Duration);
        }
    }

    private void OnVolumePropertyChanged(object? sender, AvaloniaPropertyChangedEventArgs e)
    {
        if (e.Property != RangeBase.ValueProperty) return;
        if (_syncingVolume) return;
        Player.Volume = (float)(_volume.Value / 100.0);
        if (Player.Volume > 0.001f) Player.IsMuted = false;
        RefreshMuteGlyph();
    }

    private void Refresh()
    {
        var song = Player.CurrentSong;
        _titleText.Text = song?.Title ?? "未在播放";
        _artistButton.Content = song is not null && song.Artists.Count > 0 ? song.ArtistNames : "未知艺术家";
        _artistButton.IsEnabled = song is not null && song.Artists.Count > 0;
        _cover.CoverUrl = song?.CoverURL;

        var source = Player.PlayingSource;
        _sourceText.Text = source?.Text ?? "";
        _sourceText.IsVisible = !string.IsNullOrEmpty(_sourceText.Text);
        if (source is not null)
        {
            ToolTip.SetTip(_sourceText, source.Detail);
        }

        _playPauseButton.Content = Player.PlaybackState.IsPlayIntentActive ? "\uE769" : "\uE768";
        _modeButton.Content = ModeGlyph(Player.Queue.Mode);
        ToolTip.SetTip(_modeButton, Player.Queue.Mode.DisplayName());

        var isNetease = song is not null && song.Source == SongSource.Netease;
        var liked = song is not null && App.IsLiked(song.Id);
        _likeButton.Content = liked ? "\uEB52" : "\uEB51";
        _likeButton.Foreground = liked ? AccentText : SecondaryText;
        _likeButton.IsEnabled = isNetease && App.IsLoggedIn;
        ToolTip.SetTip(_likeButton, liked ? "取消收藏" : "收藏到喜欢的音乐");

        var overrideLevel = song is null ? null : Player.QualityOverrideFor(song.Id);
        _qualityButton.Content = overrideLevel?.DisplayName() ?? "音质";
        _qualityButton.IsVisible = isNetease;
        _qualityButton.IsEnabled = isNetease;

        _durationText.Text = CTFormatting.Time(Player.Duration);
        _currentTimeText.Text = CTFormatting.Time(Player.CurrentTime);
        SyncVolume();
        RefreshMuteGlyph();

        if (!_progressDragging)
        {
            _syncingProgress = true;
            _progress.Value = Player.Duration > 0
                ? Math.Clamp(Player.CurrentTime / Player.Duration * 100, 0, 100)
                : 0;
            _syncingProgress = false;
        }

        UpdateCurrentLyric(Player.CurrentTime);
    }

    private void SyncVolume()
    {
        _syncingVolume = true;
        _volume.Value = Math.Clamp(Player.Volume * 100, 0, 100);
        _syncingVolume = false;
    }

    private void RefreshMuteGlyph()
    {
        _muteButton.Content = Player.IsMuted || Player.Volume <= 0.001f ? "\uE74F" : "\uE767";
    }

    private void ShowQualityMenu()
    {
        var song = Player.CurrentSong;
        if (song is null || song.Source != SongSource.Netease) return;
        var current = Player.QualityOverrideFor(song.Id);
        var menu = new MenuFlyout();
        var auto = new MenuItem
        {
            Header = "自动（跟随全局设置）",
            ToggleType = MenuItemToggleType.Radio,
            IsChecked = current is null,
        };
        auto.Click += (_, _) =>
        {
            Player.SetQualityOverride(null, song.Id);
            Refresh();
        };
        menu.Items.Add(auto);
        foreach (var level in SongQualityPolicy.SelectableLevels)
        {
            var item = new MenuItem
            {
                Header = level.DisplayName(),
                ToggleType = MenuItemToggleType.Radio,
                IsChecked = current == level,
            };
            var captured = level;
            item.Click += (_, _) =>
            {
                Player.SetQualityOverride(captured, song.Id);
                Refresh();
            };
            menu.Items.Add(item);
        }
        menu.ShowAt(_qualityButton);
    }

    private void OnCacheStateChanged() => Post(() =>
    {
        var source = Player.PlayingSource;
        _sourceText.Text = source?.Text ?? "";
        _sourceText.IsVisible = !string.IsNullOrEmpty(_sourceText.Text);
        if (source is not null)
        {
            ToolTip.SetTip(_sourceText, source.Detail);
        }
    });

    private void MarkUserScroll()
    {
        _userScrollUntil = DateTimeOffset.Now.AddSeconds(6);
        _backToCurrentButton.IsVisible = _currentLineIndex is not null;
    }

    private void BackToCurrentLyric()
    {
        _userScrollUntil = DateTimeOffset.MinValue;
        _backToCurrentButton.IsVisible = false;
        if (_currentLineIndex is { } index && index >= 0 && index < _rows.Count)
        {
            _rows[index].Container.BringIntoView();
        }
    }

    private void UpdateWordProgress(double time)
    {
        if (_currentLineIndex is not { } index || index < 0 || index >= _rows.Count) return;
        var row = _rows[index];
        if (row.WordBlocks.Count == 0) return;
        var words = _lyrics.Lines[index].Words;
        if (words is null) return;
        var adjusted = time + _lyricOffset;
        var wordIndex = -1;
        for (var i = 0; i < words.Count; i++)
        {
            if (adjusted >= words[i].Time) wordIndex = i;
            else break;
        }
        row.SetWordProgress(wordIndex);
    }

    private void LoadLyrics()
    {
        _lyricsCts?.Cancel();
        var cts = new CancellationTokenSource();
        _lyricsCts = cts;
        _currentLineIndex = null;
        _ = _lyrics.LoadAsync(Player.CurrentSong, cts.Token);
    }

    private void RenderLyricState()
    {
        var loading = _lyrics.IsLoading;
        var error = _lyrics.ErrorMessage;
        var pure = _lyrics.IsPureMusic;
        var hasLines = _lyrics.Lines.Count > 0;

        _loadingPanel.IsVisible = loading;
        _errorPanel.IsVisible = !loading && error is not null;
        _purePanel.IsVisible = !loading && error is null && pure;
        _emptyPanel.IsVisible = !loading && error is null && !pure && !hasLines;
        _lyricScroll.IsVisible = !loading && error is null && !pure && hasLines;

        if (error is not null)
        {
            _lyricErrorText.Text = error;
        }
    }

    private void RenderLyrics()
    {
        _lyricStack.Children.Clear();
        _rows.Clear();
        _currentLineIndex = null;

        foreach (var line in _lyrics.Lines)
        {
            var row = BuildRow(line);
            _rows.Add(row);
            _lyricStack.Children.Add(row.Container);
        }

        RenderLyricState();
        if (_rows.Count > 0)
        {
            UpdateCurrentLyric(Player.CurrentTime);
        }
    }

    private LyricRow BuildRow(LyricLine line)
    {
        var main = new TextBlock
        {
            Text = string.IsNullOrEmpty(line.Text) ? "♪" : line.Text,
            FontSize = 16,
            Foreground = FaintText,
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };

        WrapPanel? wordsHost = null;
        var wordBlocks = new List<TextBlock>();
        if (line.Words is { Count: > 0 })
        {
            wordsHost = new WrapPanel
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                MaxWidth = 560,
            };
            foreach (var word in line.Words)
            {
                var block = new TextBlock
                {
                    Text = word.Text,
                    FontSize = 16,
                    Foreground = FaintText,
                };
                wordBlocks.Add(block);
                wordsHost.Children.Add(block);
            }
            main.IsVisible = false;
        }
        var translation = new TextBlock
        {
            Text = line.Translation ?? "",
            FontSize = 14,
            Foreground = FaintText,
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            IsVisible = _showTranslation && !string.IsNullOrEmpty(line.Translation),
        };
        var romanization = new TextBlock
        {
            Text = line.Romanization ?? "",
            FontSize = 14,
            Foreground = FaintText,
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            IsVisible = _showRomanization && !string.IsNullOrEmpty(line.Romanization),
        };

        var stack = new StackPanel { Spacing = 2 };
        stack.Children.Add(main);
        if (wordsHost is not null) stack.Children.Add(wordsHost);
        stack.Children.Add(translation);
        stack.Children.Add(romanization);

        var container = new Border
        {
            Child = stack,
            Padding = new Thickness(CTSpacing.Sm, CTSpacing.Xs),
            Background = Brushes.Transparent,
            Cursor = new Cursor(StandardCursorType.Hand),
        };
        container.PointerPressed += (_, _) =>
            Player.CommitSeek(Math.Max(0, line.Time - _lyricOffset));

        return new LyricRow
        {
            Container = container,
            Main = main,
            Translation = translation,
            Romanization = romanization,
            WordsHost = wordsHost,
            WordBlocks = wordBlocks,
        };
    }

    private void UpdateRowVisibility()
    {
        foreach (var row in _rows)
        {
            row.Translation.IsVisible = _showTranslation && !string.IsNullOrEmpty(row.Translation.Text);
            row.Romanization.IsVisible = _showRomanization && !string.IsNullOrEmpty(row.Romanization.Text);
        }
    }

    private void UpdateCurrentLyric(double time)
    {
        var index = LRCParser.CurrentLineIndex(_lyrics.Lines, time, _lyricOffset);
        if (index == _currentLineIndex) return;
        var previous = _currentLineIndex;
        _currentLineIndex = index;

        if (previous is { } old && old >= 0 && old < _rows.Count)
        {
            _rows[old].SetCurrent(false);
        }
        if (index is { } current && current >= 0 && current < _rows.Count)
        {
            _rows[current].SetCurrent(true);
            UpdateWordProgress(Player.CurrentTime);
            Dispatcher.UIThread.Post(() =>
            {
                if (current < _rows.Count && _currentLineIndex == current
                    && DateTimeOffset.Now >= _userScrollUntil)
                {
                    _backToCurrentButton.IsVisible = false;
                    _rows[current].Container.BringIntoView();
                }
                else if (_currentLineIndex == current)
                {
                    _backToCurrentButton.IsVisible = true;
                }
            });
        }
    }

    private void AdjustOffset(double delta)
    {
        var next = Math.Clamp(_lyricOffset + delta, -5.0, 5.0);
        _lyricOffset = Math.Round(next * 10) / 10;
        SaveOffset(_lyricOffset);
        UpdateOffsetUi();
        UpdateCurrentLyric(Player.CurrentTime);
    }

    private void UpdateOffsetUi()
    {
        var adjusted = Math.Abs(_lyricOffset) >= 0.001;
        _offsetText.Text = !adjusted
            ? "0.0s"
            : _lyricOffset > 0
                ? $"提前 {_lyricOffset.ToString("0.0", CultureInfo.InvariantCulture)}s"
                : $"延后 {(-_lyricOffset).ToString("0.0", CultureInfo.InvariantCulture)}s";
        _offsetText.Foreground = adjusted ? AccentText : SecondaryText;
        _offsetReset.IsVisible = adjusted;
        _offsetDecrease.IsEnabled = _lyricOffset > -5.0 + 0.0001;
        _offsetIncrease.IsEnabled = _lyricOffset < 5.0 - 0.0001;
    }

    private static double LoadOffset()
    {
        var settings = PersistenceStore.Shared.LoadSetting<AppSettings>("appSettings");
        return settings?.LyricOffset ?? 0;
    }

    private static void SaveOffset(double value)
    {
        var settings = PersistenceStore.Shared.LoadSetting<AppSettings>("appSettings") ?? new AppSettings();
        settings.LyricOffset = value;
        PersistenceStore.Shared.SaveSetting(settings, "appSettings");
    }

    private static string ModeGlyph(PlayMode mode) => mode switch
    {
        PlayMode.LoopOne => "\uE8ED",
        PlayMode.Shuffle => "\uE8B1",
        _ => "\uE8EE",
    };

    private static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }

    private sealed class LyricRow
    {
        public Border Container { get; init; } = new();
        public TextBlock Main { get; init; } = new();
        public TextBlock Translation { get; init; } = new();
        public TextBlock Romanization { get; init; } = new();
        public WrapPanel? WordsHost { get; init; }
        public IReadOnlyList<TextBlock> WordBlocks { get; init; } = Array.Empty<TextBlock>();

        public void SetCurrent(bool current)
        {
            Main.FontSize = current ? 20 : 16;
            Main.FontWeight = current ? FontWeight.SemiBold : FontWeight.Normal;
            Main.Foreground = current ? PrimaryText : FaintText;
            Translation.Foreground = current ? PrimaryText : FaintText;
            Romanization.Foreground = current ? PrimaryText : FaintText;
            foreach (var block in WordBlocks)
            {
                block.FontSize = current ? 20 : 16;
                block.FontWeight = current ? FontWeight.SemiBold : FontWeight.Normal;
                block.Foreground = current ? PrimaryText : FaintText;
            }
        }

        public void SetWordProgress(int currentWordIndex)
        {
            for (var i = 0; i < WordBlocks.Count; i++)
            {
                WordBlocks[i].Foreground = i < currentWordIndex
                    ? PrimaryText
                    : i == currentWordIndex ? AccentText : FaintText;
            }
        }
    }
}
