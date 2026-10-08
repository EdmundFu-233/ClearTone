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

[PageView(Page.Liked)]
public sealed class LikedView : UserControl, IPageView
{
    private static AppState App => AppState.Shared;
    private static PlayerController Player => PlayerController.Shared;

    private readonly ContentControl _host = new();
    private readonly Button _playAll;
    private readonly TextBlock _subtitle;
    private readonly Control _empty;
    private SongListView? _list;
    private string _lastDataContextKey = "";

    public LikedView()
    {
        _subtitle = new TextBlock { Text = "把心动的旋律，留在身边。", Classes = { "secondary" } };

        var titleStack = new StackPanel { Spacing = CTSpacing.Xs };
        titleStack.Children.Add(new TextBlock { Text = "喜欢的音乐", Classes = { "pageTitle" } });
        titleStack.Children.Add(_subtitle);

        _playAll = new Button { Content = "播放全部", Classes = { "accent" }, VerticalAlignment = VerticalAlignment.Center, IsVisible = false };
        _playAll.Click += (_, _) =>
        {
            var songs = App.LikedSongs.ToList();
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

        _empty = UIComponents.StatusPanel("还没有喜欢的歌曲");

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
            case nameof(AppState.LikedSongs):
            case nameof(AppState.LikesVersion):
                Post(Render);
                break;
        }
    }

    private void RefreshForDataContext()
    {
        var key = App.DataContextKey;
        if (key == _lastDataContextKey)
        {
            Post(Render);
            return;
        }
        _lastDataContextKey = key;
        _ = LoadAsync();
    }

    private async Task LoadAsync()
    {
        try
        {
            await App.LoadLikedSongsAsync();
        }
        catch (Exception error)
        {
            App.PublishWriteError(error);
        }
        Post(Render);
    }

    private void Render()
    {
        if (!App.IsLoggedIn)
        {
            _playAll.IsVisible = false;
            _subtitle.Text = "登录后查看喜欢的歌曲";
            _host.Content = UIComponents.StatusPanel("登录后查看喜欢的歌曲");
            return;
        }

        var songs = App.LikedSongs.ToList();
        _playAll.IsVisible = songs.Count > 0;
        _subtitle.Text = songs.Count == 0 ? "把心动的旋律，留在身边。" : $"{songs.Count} 首珍藏 · 随时重温";

        if (songs.Count == 0)
        {
            _host.Content = _empty;
            return;
        }

        _list ??= new SongListView();
        if (!ReferenceEquals(_host.Content, _list)) _host.Content = _list;
        _list.SetSongs(songs);
    }

    private static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }
}
