using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using ClearTone.Controls;
using ClearTone.Core.Discover;
using ClearTone.Core.Models;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Playback;
using ClearTone.Providers.Netease;
using ClearTone.Shell;

namespace ClearTone.Features.Discover;

[PageView(Page.TopList)]
public sealed class TopListView : UserControl, IPageView
{
    private static PlayerController Player => PlayerController.Shared;
    private static NeteaseProvider Provider => NeteaseProvider.Shared;

    private readonly TopListSession _session = new();
    private readonly ListBox _listBox = new();
    private readonly ContentControl _listHost = new();
    private readonly ContentControl _trackHost = new();
    private readonly TextBlock _trackTitle;
    private readonly TextBlock _trackCount;
    private readonly Button _playAll;

    private IReadOnlyList<TopList>? _renderedLists;
    private SongListView? _songList;
    private List<Song> _tracks = new();
    private TopList? _selected;
    private Guid _trackToken;
    private bool _isLoadingTracks;
    private string? _tracksError;
    private bool _loaded;

    public TopListView()
    {
        _listBox.Background = Brushes.Transparent;
        _listBox.BorderThickness = new Thickness(0);
        _listBox.ItemTemplate = new FuncDataTemplate<TopList>((list, _) =>
            list is null ? new Control() : BuildListItem(list));
        _listBox.SelectionChanged += OnSelectionChanged;

        _listHost.Width = 240;
        _listHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _listHost.VerticalContentAlignment = VerticalAlignment.Stretch;

        _trackTitle = new TextBlock { Text = "选择榜单", Classes = { "sectionTitle" }, VerticalAlignment = VerticalAlignment.Center };
        _trackCount = new TextBlock { Classes = { "secondary" }, VerticalAlignment = VerticalAlignment.Center };
        _playAll = new Button
        {
            Content = "播放全部",
            Classes = { "accent" },
            IsEnabled = false,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _playAll.Click += (_, _) =>
        {
            if (_tracks.Count > 0) Player.PlaySongs(_tracks, 0);
        };

        var trackTitleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Md, VerticalAlignment = VerticalAlignment.Center };
        trackTitleRow.Children.Add(_trackTitle);
        trackTitleRow.Children.Add(_trackCount);

        var trackHeader = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Margin = new Thickness(CTSpacing.Lg, CTSpacing.Md, CTSpacing.Lg, CTSpacing.Sm) };
        trackHeader.Children.Add(trackTitleRow);
        Grid.SetColumn(_playAll, 1);
        trackHeader.Children.Add(_playAll);

        var trackPane = new Grid { RowDefinitions = new RowDefinitions("Auto,*") };
        trackPane.Children.Add(trackHeader);
        _trackHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _trackHost.VerticalContentAlignment = VerticalAlignment.Stretch;
        Grid.SetRow(_trackHost, 1);
        trackPane.Children.Add(_trackHost);

        var divider = new Border { Width = 1, Background = CTColors.OverlayBrush };

        var columns = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,Auto,*") };
        columns.Children.Add(_listHost);
        Grid.SetColumn(divider, 1);
        columns.Children.Add(divider);
        Grid.SetColumn(trackPane, 2);
        columns.Children.Add(trackPane);

        var titleStack = new StackPanel { Spacing = CTSpacing.Xs };
        titleStack.Children.Add(new TextBlock { Text = "排行榜", Classes = { "pageTitle" } });
        titleStack.Children.Add(new TextBlock { Text = "看看大家都在听什么。", Classes = { "secondary" } });
        titleStack.Margin = new Thickness(CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Md);

        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*"), Background = CTColors.BackgroundBrush };
        root.Children.Add(titleStack);
        Grid.SetRow(columns, 1);
        root.Children.Add(columns);
        Content = root;

        _session.PropertyChanged += (_, _) => Post(RenderLists);
        RenderLists();
        RenderTracks();
    }

    public void OnActivated()
    {
        if (_loaded) return;
        _loaded = true;
        _ = _session.LoadAsync();
    }

    private static Control BuildListItem(TopList list)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*") };
        grid.Children.Add(new CoverImage
        {
            Width = 40,
            Height = 40,
            CornerRadius = new CornerRadius(CTRadius.Small),
            CoverUrl = list.CoverURL,
            DecodeWidth = 80,
        });
        var text = new StackPanel { Spacing = 2, Margin = new Thickness(CTSpacing.Sm, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock
        {
            Text = list.Name,
            FontWeight = FontWeight.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        if (!string.IsNullOrEmpty(list.UpdateFrequency))
        {
            text.Children.Add(new TextBlock { Text = list.UpdateFrequency, Classes = { "secondary" } });
        }
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        return new Border { Child = grid, Padding = new Thickness(CTSpacing.Sm) };
    }

    private void OnSelectionChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (_listBox.SelectedItem is not TopList list) return;
        _ = LoadTracksAsync(list);
    }

    private async Task LoadTracksAsync(TopList list)
    {
        var token = Guid.NewGuid();
        _trackToken = token;
        _selected = list;
        _isLoadingTracks = true;
        _tracksError = null;
        _tracks = new List<Song>();
        RenderTracks();
        try
        {
            var detail = await Provider.FetchPlaylistDetailAsync(list.Id);
            if (_trackToken != token) return;
            var collected = detail.Tracks;
            if (collected.Count < detail.TotalTrackCount)
            {
                const int pageSize = 100;
                var pages = Math.Min(4, (int)Math.Ceiling(detail.TotalTrackCount / (double)pageSize));
                for (var page = 1; page <= pages; page++)
                {
                    var more = await Provider.FetchPlaylistTracksAsync(list.Id, page, pageSize);
                    if (_trackToken != token) return;
                    collected = MergeUnique(collected, more);
                    if (collected.Count >= detail.TotalTrackCount) break;
                }
            }
            _tracks = collected;
        }
        catch (Exception error)
        {
            if (_trackToken != token) return;
            _tracksError = error.CtUserMessage();
        }
        if (_trackToken != token) return;
        _isLoadingTracks = false;
        RenderTracks();
    }

    private static List<Song> MergeUnique(List<Song> baseSongs, IReadOnlyList<Song> extra)
    {
        var seen = baseSongs.Select(song => song.Id).ToHashSet();
        var result = new List<Song>(baseSongs);
        foreach (var song in extra)
        {
            if (seen.Add(song.Id)) result.Add(song);
        }
        return result;
    }

    private void RenderLists()
    {
        if (_session.IsLoading && _session.Lists.Count == 0)
        {
            _listHost.Content = UIComponents.StatusPanel("加载中…", showSpinner: true);
            return;
        }
        if (_session.ErrorMessage is { } error && _session.Lists.Count == 0)
        {
            _listHost.Content = UIComponents.ErrorPanel(error, () => _ = _session.LoadAsync());
            return;
        }
        if (_session.Lists.Count == 0)
        {
            _listHost.Content = UIComponents.StatusPanel("暂无榜单数据");
            return;
        }
        if (!ReferenceEquals(_renderedLists, _session.Lists))
        {
            _renderedLists = _session.Lists;
            _listBox.ItemsSource = null;
            _listBox.ItemsSource = _session.Lists;
        }
        _listHost.Content = _listBox;
    }

    private void RenderTracks()
    {
        _trackTitle.Text = _selected?.Name ?? "选择榜单";
        _trackCount.Text = _tracks.Count > 0 ? $"{_tracks.Count} 首" : "";
        _playAll.IsEnabled = _tracks.Count > 0;

        if (_isLoadingTracks && _tracks.Count == 0)
        {
            _trackHost.Content = UIComponents.StatusPanel("加载中…", showSpinner: true);
            return;
        }
        if (_tracksError is { } error && _tracks.Count == 0)
        {
            _trackHost.Content = UIComponents.ErrorPanel(error, () =>
            {
                if (_selected is { } list) _ = LoadTracksAsync(list);
            });
            return;
        }
        if (_tracks.Count == 0)
        {
            _trackHost.Content = UIComponents.StatusPanel("选择左侧榜单查看曲目");
            return;
        }
        _songList ??= new SongListView();
        _songList.SetSongs(_tracks);
        _trackHost.Content = _songList;
    }

    private static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }
}
