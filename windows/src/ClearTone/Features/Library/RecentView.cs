using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Threading;
using ClearTone.Core.Models;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Playback;
using ClearTone.Shell;

namespace ClearTone.Features.Library;

[PageView(Page.Recent)]
public sealed class RecentView : UserControl, IPageView
{
    private static PlayerController Player => PlayerController.Shared;

    private readonly ContentControl _host = new();
    private readonly Button _playAll;
    private readonly TextBlock _subtitle;
    private readonly Control _empty = UIComponents.StatusPanel("暂无播放记录");
    private SongListView? _list;

    public RecentView()
    {
        _subtitle = new TextBlock { Text = "听过的歌会出现在这里。", Classes = { "secondary" } };

        var titleStack = new StackPanel { Spacing = CTSpacing.Xs };
        titleStack.Children.Add(new TextBlock { Text = "最近播放", Classes = { "pageTitle" } });
        titleStack.Children.Add(_subtitle);

        _playAll = new Button { Content = "播放全部", Classes = { "accent" }, VerticalAlignment = VerticalAlignment.Center, IsVisible = false };
        _playAll.Click += (_, _) =>
        {
            var songs = Player.RecentlyPlayed.ToList();
            if (songs.Count > 0) Player.PlaySongs(songs, 0);
        };

        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        header.Children.Add(titleStack);
        Grid.SetColumn(_playAll, 1);
        header.Children.Add(_playAll);
        header.Margin = new Thickness(CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Lg);

        _host.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _host.VerticalContentAlignment = VerticalAlignment.Stretch;

        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,*"), Background = CTColors.BackgroundBrush };
        root.Children.Add(header);
        Grid.SetRow(_host, 1);
        root.Children.Add(_host);
        Content = root;

        Player.PropertyChanged += OnPlayerPropertyChanged;
        AttachedToVisualTree += (_, _) => Render();
        Render();
    }

    public void OnActivated()
    {
    }

    private void OnPlayerPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(PlayerController.CurrentSong))
        {
            Post(Render);
        }
    }

    private void Render()
    {
        var songs = Player.RecentlyPlayed;
        _playAll.IsVisible = songs.Count > 0;
        _subtitle.Text = songs.Count == 0 ? "听过的歌会出现在这里。" : $"最近 {songs.Count} 首";

        if (songs.Count == 0)
        {
            _host.Content = _empty;
            return;
        }

        _list ??= new SongListView();
        if (!ReferenceEquals(_host.Content, _list)) _host.Content = _list;
        _list.SetSongs(songs.ToList());
    }

    private static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }
}
