using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using ClearTone.Controls;
using ClearTone.Core.Models;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Playback;
using ClearTone.Providers.Netease;
using ClearTone.Shell;

namespace ClearTone.Features.Radio;

[PageView(Page.RadioDetail)]
public sealed class RadioDetailView : UserControl, IPageView
{
    private static AppState App => AppState.Shared;
    private static NeteaseProvider Provider => NeteaseProvider.Shared;

    private readonly StackPanel _root = new()
    {
        Spacing = CTSpacing.Lg,
        Margin = new Thickness(CTSpacing.Xl),
    };

    private readonly StackPanel _header = new() { Spacing = CTSpacing.Sm };
    private readonly TextBlock _statusText = new() { Foreground = CTColors.TextSecondaryBrush };
    private readonly SongListView _programList = new();
    private readonly Button _loadMoreButton = new()
    {
        Content = "加载更多节目",
        Classes = { "accent" },
        HorizontalAlignment = HorizontalAlignment.Center,
        IsVisible = false,
    };

    private readonly List<Song> _songs = new();
    private string? _loadedStationID;
    private int _page = 1;
    private int _programCount;
    private bool _loading;
    private RadioStation? _station;

    public RadioDetailView()
    {
        _root.Children.Add(_header);
        _root.Children.Add(_statusText);
        _root.Children.Add(_programList);
        _root.Children.Add(_loadMoreButton);
        Content = new ScrollViewer { Content = _root };

        _loadMoreButton.Click += (_, _) => _ = LoadProgramsAsync(App.SelectedRadioID ?? "", _page + 1);
        App.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(AppState.SelectedRadioID)) Load();
        };
        Load();
    }

    public void OnActivated() => Load();

    private void Load()
    {
        var id = App.SelectedRadioID;
        if (string.IsNullOrEmpty(id))
        {
            _statusText.Text = "未选择电台";
            _statusText.IsVisible = true;
            return;
        }
        if (id == _loadedStationID) return;
        _loadedStationID = id;
        _page = 1;
        _programCount = 0;
        _station = null;
        _songs.Clear();
        _programList.SetSongs(_songs);
        _header.Children.Clear();
        _loadMoreButton.IsVisible = false;
        _ = LoadStationAsync(id);
    }

    private async Task LoadStationAsync(string id)
    {
        _statusText.Text = "加载中…";
        _statusText.IsVisible = true;
        try
        {
            var station = await Provider.FetchRadioStationDetailAsync(id);
            if (App.SelectedRadioID != id) return;
            _station = station;
            _programCount = station.ProgramCount;
            RenderHeader(station);
            await LoadProgramsAsync(id, 1);
        }
        catch (Exception error)
        {
            if (App.SelectedRadioID != id) return;
            _statusText.Text = error.CtUserMessage();
            _statusText.IsVisible = true;
        }
    }

    private void RenderHeader(RadioStation station)
    {
        _header.Children.Clear();
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Lg };
        row.Children.Add(new CoverImage
        {
            Width = 130,
            Height = 130,
            CornerRadius = new CornerRadius(CTRadius.Medium),
            CoverUrl = station.CoverURL,
            DecodeWidth = 260,
        });

        var info = new StackPanel { Spacing = CTSpacing.Sm, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 520 };
        info.Children.Add(new TextBlock
        {
            Text = station.Name,
            FontSize = 24,
            FontWeight = FontWeight.Bold,
            TextWrapping = TextWrapping.Wrap,
        });
        var meta = new List<string>();
        if (!string.IsNullOrEmpty(station.CreatorName)) meta.Add(station.CreatorName!);
        if (station.ProgramCount > 0) meta.Add($"{station.ProgramCount} 期节目");
        if (station.SubscriberCount > 0) meta.Add($"{CTFormatting.Count(station.SubscriberCount)} 人订阅");
        info.Children.Add(new TextBlock
        {
            Text = string.Join(" · ", meta),
            Classes = { "secondary" },
        });
        if (!string.IsNullOrEmpty(station.DescriptionText))
        {
            info.Children.Add(new TextBlock
            {
                Text = station.DescriptionText,
                Classes = { "secondary" },
                TextWrapping = TextWrapping.Wrap,
                MaxLines = 4,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
        }

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Sm };
        var subscribe = new Button
        {
            Content = station.IsSubscribed ? "取消订阅" : "订阅电台",
            Classes = { "accent" },
            IsEnabled = App.IsLoggedIn,
        };
        subscribe.Click += (_, _) => _ = ToggleSubscribeAsync(station);
        actions.Children.Add(subscribe);

        var playAll = new Button { Content = "播放全部" };
        playAll.Click += (_, _) =>
        {
            if (_songs.Count > 0) PlayerController.Shared.PlaySongs(_songs, 0);
        };
        actions.Children.Add(playAll);
        info.Children.Add(actions);

        row.Children.Add(info);
        _header.Children.Add(row);
    }

    private async Task ToggleSubscribeAsync(RadioStation station)
    {
        try
        {
            await Provider.SubscribeRadioAsync(station.Id, !station.IsSubscribed);
            var refreshed = await Provider.FetchRadioStationDetailAsync(station.Id);
            if (App.SelectedRadioID != station.Id) return;
            _station = refreshed;
            RenderHeader(refreshed);
        }
        catch (Exception error)
        {
            App.PublishWriteError(error);
            _statusText.Text = error.CtUserMessage();
            _statusText.IsVisible = true;
        }
    }

    private async Task LoadProgramsAsync(string id, int page)
    {
        if (_loading || string.IsNullOrEmpty(id)) return;
        _loading = true;
        try
        {
            var programs = await Provider.FetchRadioProgramsAsync(id, page, 30);
            if (App.SelectedRadioID != id) return;
            var songs = programs
                .Select(program => program.Song)
                .Where(song => song is not null)
                .Select(song => song!)
                .ToList();
            _songs.AddRange(songs);
            _programList.SetSongs(_songs);
            _page = page;
            var hasMore = _programCount > 0
                ? _page * 30 < _programCount
                : programs.Count >= 30;
            _loadMoreButton.IsVisible = hasMore;
            _statusText.IsVisible = _songs.Count == 0;
            _statusText.Text = _songs.Count == 0 ? "暂无节目" : "";
        }
        catch (Exception error)
        {
            if (App.SelectedRadioID != id) return;
            _statusText.Text = error.CtUserMessage();
            _statusText.IsVisible = true;
        }
        finally
        {
            _loading = false;
        }
    }
}
