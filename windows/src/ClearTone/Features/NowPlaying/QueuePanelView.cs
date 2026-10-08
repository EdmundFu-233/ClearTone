using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using ClearTone.Controls;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Playback;

namespace ClearTone.Features.NowPlaying;

[OverlayView(OverlayKind.Queue)]
public sealed class QueuePanelView : UserControl
{
    private static PlayerController Player => PlayerController.Shared;
    private static readonly FontFamily IconFont = new("Segoe MDL2 Assets, Segoe Fluent Icons");

    private readonly ListBox _list = new();
    private readonly TextBlock _countText = new()
    {
        Classes = { "secondary" },
        VerticalAlignment = VerticalAlignment.Center,
    };

    private readonly TextBlock _emptyText = new()
    {
        Text = "队列为空",
        Classes = { "secondary" },
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private bool _syncing;

    public QueuePanelView()
    {
        var clearButton = new Button
        {
            Classes = { "toolbar" },
            FontFamily = IconFont,
            FontSize = 14,
            Content = "\uE74D",
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTip.SetTip(clearButton, "清空队列");
        clearButton.Click += (_, _) => Player.ClearQueue();

        var header = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("*,Auto"),
            Margin = new Thickness(CTSpacing.Lg, CTSpacing.Sm, CTSpacing.Lg, CTSpacing.Sm),
        };
        header.Children.Add(_countText);
        Grid.SetColumn(clearButton, 1);
        header.Children.Add(clearButton);

        _list.Background = Brushes.Transparent;
        _list.BorderThickness = new Thickness(0);
        _list.ItemTemplate = new FuncDataTemplate<QueueItem>((item, _) =>
            item is null ? new Control() : BuildRow(item));
        _list.SelectionChanged += (_, _) =>
        {
            if (_syncing) return;
            if (_list.SelectedItem is QueueItem item)
            {
                Player.JumpTo(item.Id);
            }
        };

        var body = new Grid();
        body.Children.Add(_list);
        body.Children.Add(_emptyText);

        var root = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        root.Children.Add(body);
        Content = root;

        Player.PropertyChanged += OnPlayerPropertyChanged;
        AttachedToVisualTree += (_, _) => Refresh();
        Refresh();
    }

    private void OnPlayerPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PlayerController.Queue) or nameof(PlayerController.CurrentSong))
        {
            Post(Refresh);
        }
    }

    private void Refresh()
    {
        if (!Dispatcher.UIThread.CheckAccess())
        {
            Dispatcher.UIThread.Post(Refresh);
            return;
        }

        var items = Player.Queue.Items.ToList();
        _countText.Text = $"{items.Count} 首";
        _emptyText.IsVisible = items.Count == 0;
        _list.IsVisible = items.Count > 0;

        _syncing = true;
        _list.ItemsSource = items;
        _list.SelectedItem = Player.Queue.CurrentItem;
        _syncing = false;
    }

    private static Control BuildRow(QueueItem item)
    {
        var song = item.Song;
        var isCurrent = Player.Queue.CurrentItem?.Id == item.Id;

        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto,Auto"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        grid.Children.Add(new CoverImage
        {
            Width = 36,
            Height = 36,
            CornerRadius = new CornerRadius(CTRadius.Small),
            CoverUrl = song.CoverURL,
            DecodeWidth = 72,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var info = new StackPanel
        {
            Margin = new Thickness(CTSpacing.Sm, 0, CTSpacing.Sm, 0),
            Spacing = 2,
            VerticalAlignment = VerticalAlignment.Center,
        };
        info.Children.Add(new TextBlock
        {
            Text = song.Title,
            FontWeight = isCurrent ? FontWeight.SemiBold : FontWeight.Normal,
            Foreground = isCurrent ? CTColors.AccentBrush : CTColors.TextPrimaryBrush,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        info.Children.Add(new TextBlock
        {
            Text = song.ArtistNames,
            Classes = { "secondary" },
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        Grid.SetColumn(info, 1);
        grid.Children.Add(info);

        var duration = new TextBlock
        {
            Text = CTFormatting.Time(song.Duration),
            Classes = { "secondary" },
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, CTSpacing.Sm, 0),
        };
        Grid.SetColumn(duration, 2);
        grid.Children.Add(duration);

        var remove = new Button
        {
            Classes = { "toolbar" },
            FontFamily = IconFont,
            FontSize = 12,
            Content = "\uE711",
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTip.SetTip(remove, "从队列移除");
        remove.Click += (_, _) => Player.RemoveFromQueue(item.Id);
        Grid.SetColumn(remove, 3);
        grid.Children.Add(remove);

        var row = new Border { Padding = new Thickness(CTSpacing.Sm, 4), Child = grid };
        var menu = new ContextMenu();
        menu.Items.Add(MenuItem("立即播放", () => Player.JumpTo(item.Id)));
        menu.Items.Add(MenuItem("上移", () => Move(item, -1)));
        menu.Items.Add(MenuItem("下移", () => Move(item, 1)));
        menu.Items.Add(MenuItem("从队列移除", () => Player.RemoveFromQueue(item.Id)));
        row.ContextMenu = menu;
        return row;
    }

    private static void Move(QueueItem item, int delta)
    {
        var items = Player.Queue.Items;
        var index = items.IndexOf(item);
        if (index < 0) return;
        var target = index + delta;
        if (target < 0 || target >= items.Count) return;
        Player.MoveQueueItems(index, target);
    }

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
