using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.VisualTree;
using Avalonia.Layout;
using Avalonia.Media;
using ClearTone.Controls;
using ClearTone.Core.Persistence;
using ClearTone.DesignSystem;
using ClearTone.Playback;

namespace ClearTone.Shell;

public sealed class MiniPlayerWindow : Window
{
    private static MiniPlayerWindow? _instance;

    private readonly PlayerController _player = PlayerController.Shared;
    private readonly CoverImage _cover = new() { Width = 48, Height = 48, DecodeWidth = 96 };
    private readonly TextBlock _title = new()
    {
        FontWeight = FontWeight.SemiBold,
        TextTrimming = TextTrimming.CharacterEllipsis,
    };
    private readonly TextBlock _artist = new()
    {
        Classes = { "secondary" },
        TextTrimming = TextTrimming.CharacterEllipsis,
    };
    private readonly Slider _progress = new()
    {
        Minimum = 0,
        Maximum = 100,
        Height = 3,
        MinHeight = 3,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly Button _previous;
    private readonly Button _playPause;
    private readonly Button _next;

    private bool _dragging;
    private bool _syncingProgress;

    private MiniPlayerWindow(AppSettings settings)
    {
        Width = 300;
        SizeToContent = SizeToContent.Height;
        SystemDecorations = SystemDecorations.None;
        CanResize = false;
        ShowInTaskbar = false;
        Topmost = settings.MiniPlayerAlwaysOnTop;

        _cover.CornerRadius = new CornerRadius(CTRadius.Small);
        _previous = MakeToolbarButton("\uE892", "上一首", 14);
        _playPause = MakeToolbarButton("\uE768", "播放/暂停", 20);
        _next = MakeToolbarButton("\uE893", "下一首", 14);

        Content = BuildRoot();

        _previous.Click += (_, _) => _player.Previous();
        _playPause.Click += (_, _) => _player.TogglePlayPause();
        _next.Click += (_, _) => _player.Next();

        _progress.AddHandler(PointerPressedEvent, OnProgressPointerPressed, RoutingStrategies.Tunnel);
        _progress.AddHandler(PointerReleasedEvent, OnProgressPointerReleased, RoutingStrategies.Tunnel);
        _progress.PropertyChanged += OnProgressPropertyChanged;

        _player.PropertyChanged += OnPlayerPropertyChanged;
        _player.TimeUpdated += OnTimeUpdated;
        Closed += (_, _) =>
        {
            if (ReferenceEquals(_instance, this)) _instance = null;
        };

        Refresh();
    }

    public static void Toggle()
    {
        if (_instance is { } existing)
        {
            if (existing.IsVisible)
            {
                existing.Hide();
                return;
            }
            existing.Show();
            existing.Activate();
            return;
        }

        var settings = PersistenceStore.Shared.LoadSetting<AppSettings>("appSettings") ?? new AppSettings();
        var window = new MiniPlayerWindow(settings);
        _instance = window;
        window.Show();
        PositionBottomRight(window);
        window.Activate();
    }

    protected override void OnClosing(WindowClosingEventArgs e)
    {
        base.OnClosing(e);
        e.Cancel = true;
        Hide();
    }

    private Control BuildRoot()
    {
        var close = MakeToolbarButton("\uE711", "隐藏迷你播放器", 12);
        close.Click += (_, _) => Hide();

        var info = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        info.Children.Add(_cover);

        var text = new StackPanel
        {
            Margin = new Thickness(CTSpacing.Md, 0, 0, 0),
            Spacing = 2,
            VerticalAlignment = VerticalAlignment.Center,
        };
        text.Children.Add(_title);
        text.Children.Add(_artist);
        Grid.SetColumn(text, 1);
        info.Children.Add(text);
        Grid.SetColumn(close, 2);
        info.Children.Add(close);

        var controls = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Center,
            Spacing = CTSpacing.Xl,
        };
        controls.Children.Add(_previous);
        controls.Children.Add(_playPause);
        controls.Children.Add(_next);

        var root = new StackPanel { Spacing = CTSpacing.Sm };
        root.Children.Add(info);
        root.Children.Add(_progress);
        root.Children.Add(controls);

        var surface = new Border
        {
            Background = CTColors.PanelBrush,
            CornerRadius = new CornerRadius(CTRadius.Medium),
            Padding = new Thickness(CTSpacing.Md),
            Child = root,
        };
        surface.PointerPressed += OnSurfacePointerPressed;
        return surface;
    }

    private void OnSurfacePointerPressed(object? sender, PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        if (e.Source is Visual source && HasInteractiveAncestor(source)) return;
        BeginMoveDrag(e);
    }

    private static bool HasInteractiveAncestor(Visual source)
    {
        for (Visual? current = source; current is not null; current = current.GetVisualParent())
        {
            if (current is Button or Slider or TextBox) return true;
        }
        return false;
    }

    private static Button MakeToolbarButton(string glyph, string tip, double size)
    {
        var button = new Button
        {
            Content = glyph,
            Classes = { "toolbar" },
            FontFamily = new FontFamily("Segoe MDL2 Assets, Segoe Fluent Icons"),
            FontSize = size,
        };
        ToolTip.SetTip(button, tip);
        return button;
    }

    private static void PositionBottomRight(Window window)
    {
        var screen = window.Screens.Primary;
        if (screen is null) return;
        var area = screen.WorkingArea;
        var size = window.FrameSize ?? window.ClientSize;
        var pixelSize = PixelSize.FromSize(size, window.DesktopScaling);
        var margin = (int)Math.Ceiling(12 * window.DesktopScaling);
        window.Position = new PixelPoint(
            Math.Max(area.X, area.Right - pixelSize.Width - margin),
            Math.Max(area.Y, area.Bottom - pixelSize.Height - margin));
    }

    private void OnPlayerPropertyChanged(object? sender, PropertyChangedEventArgs e) => Refresh();

    private void OnTimeUpdated(double seconds)
    {
        if (_dragging) return;
        UpdateProgress();
    }

    private void Refresh()
    {
        var song = _player.CurrentSong;
        _title.Text = song?.Title ?? "未在播放";
        _artist.Text = song?.ArtistNames ?? "";
        _cover.CoverUrl = song?.CoverURL;
        _playPause.Content = _player.PlaybackState.IsPlayIntentActive ? "\uE769" : "\uE768";
        _previous.IsEnabled = _player.Queue.HasPrevious;
        _next.IsEnabled = _player.Queue.HasNext;
        UpdateProgress();
    }

    private void UpdateProgress()
    {
        var duration = _player.Duration;
        _syncingProgress = true;
        try
        {
            _progress.Value = duration > 0
                ? Math.Clamp(_player.CurrentTime / duration * 100, 0, 100)
                : 0;
        }
        finally
        {
            _syncingProgress = false;
        }
    }

    private void OnProgressPropertyChanged(object? sender, Avalonia.AvaloniaPropertyChangedEventArgs e)
    {
        if (e.Property != RangeBase.ValueProperty) return;
        if (!_dragging || _syncingProgress) return;
        var duration = _player.Duration;
        if (duration <= 0) return;
        _player.PreviewSeek(_progress.Value / 100.0 * duration);
    }

    private void OnProgressPointerPressed(object? sender, PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        _dragging = true;
    }

    private void OnProgressPointerReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        var duration = _player.Duration;
        if (duration > 0)
        {
            _player.CommitSeek(_progress.Value / 100.0 * duration);
        }
        else
        {
            UpdateProgress();
        }
    }
}
