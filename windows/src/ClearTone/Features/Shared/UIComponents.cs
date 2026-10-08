using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using ClearTone.Core.Models;
using ClearTone.DesignSystem;
using ClearTone.Playback;
using ClearTone.Shell;
using PlaylistModel = ClearTone.Core.Models.Playlist;
using AlbumModel = ClearTone.Core.Models.Album;
using ArtistModel = ClearTone.Core.Models.Artist;

namespace ClearTone.Features.Shared;

public static class UIComponents
{
    public static Control HeaderRow(string title, Control? trailing = null)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        var block = new TextBlock
        {
            Text = title,
            FontSize = 20,
            FontWeight = FontWeight.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        grid.Children.Add(block);
        if (trailing is not null)
        {
            Grid.SetColumn(trailing, 1);
            grid.Children.Add(trailing);
        }
        return new Border { Padding = new Thickness(0, 6, 0, 6), Child = grid };
    }

    public static Button LinkButton(string text, Action action)
    {
        var button = new Button
        {
            Content = text,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Foreground = CTColors.TextSecondaryBrush,
            Padding = new Thickness(6, 2),
            FontSize = 12,
        };
        button.Click += (_, _) => action();
        return button;
    }

    public static Control StatusPanel(string text, bool showSpinner = false)
    {
        var panel = new StackPanel
        {
            Spacing = 10,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 60, 0, 60),
        };
        if (showSpinner)
        {
            panel.Children.Add(new ProgressBar
            {
                IsIndeterminate = true,
                Width = 160,
                HorizontalAlignment = HorizontalAlignment.Center,
            });
        }
        panel.Children.Add(new TextBlock
        {
            Text = text,
            Foreground = CTColors.TextSecondaryBrush,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        return panel;
    }

    public static Control ErrorPanel(string message, Action retry)
    {
        var panel = new StackPanel
        {
            Spacing = 10,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 60, 0, 60),
        };
        panel.Children.Add(new TextBlock
        {
            Text = message,
            Foreground = CTColors.TextSecondaryBrush,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 420,
            TextAlignment = TextAlignment.Center,
        });
        var button = new Button { Content = L10n.Common.Retry, Classes = { "accent" } };
        button.Click += (_, _) => retry();
        panel.Children.Add(button);
        return panel;
    }

    public static Button PlaylistCard(PlaylistModel playlist, Action<PlaylistModel> onClick, double width = 160)
    {
        var stack = new StackPanel { Spacing = 6, Width = width };
        var cover = new Controls.CoverImage
        {
            Width = width,
            Height = width,
            CornerRadius = new CornerRadius(10),
            CoverUrl = playlist.CoverURL,
            DecodeWidth = (int)width * 2,
        };
        stack.Children.Add(cover);
        stack.Children.Add(new TextBlock
        {
            Text = playlist.Name,
            FontWeight = FontWeight.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = width,
        });
        stack.Children.Add(new TextBlock
        {
            Text = $"{playlist.TrackCount} 首",
            Classes = { "secondary" },
        });
        var button = new Button
        {
            Content = stack,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
        };
        button.Click += (_, _) => onClick(playlist);
        return button;
    }

    public static Button AlbumCard(AlbumModel album, Action<AlbumModel> onClick, double width = 160)
    {
        var stack = new StackPanel { Spacing = 6, Width = width };
        stack.Children.Add(new Controls.CoverImage
        {
            Width = width,
            Height = width,
            CornerRadius = new CornerRadius(10),
            CoverUrl = album.CoverURL,
            DecodeWidth = (int)width * 2,
        });
        stack.Children.Add(new TextBlock
        {
            Text = album.Name,
            FontWeight = FontWeight.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = width,
        });
        stack.Children.Add(new TextBlock
        {
            Text = "专辑",
            Classes = { "secondary" },
        });
        var button = new Button
        {
            Content = stack,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
        };
        button.Click += (_, _) => onClick(album);
        return button;
    }

    public static Button ArtistCard(ArtistModel artist, Action<ArtistModel> onClick, double width = 140)
    {
        var stack = new StackPanel { Spacing = 6, Width = width, HorizontalAlignment = HorizontalAlignment.Center };
        var cover = new Controls.CoverImage
        {
            Width = width,
            Height = width,
            CornerRadius = new CornerRadius(width / 2),
            CoverUrl = artist.AvatarURL,
            DecodeWidth = (int)width * 2,
        };
        stack.Children.Add(cover);
        stack.Children.Add(new TextBlock
        {
            Text = artist.Name,
            FontWeight = FontWeight.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = width,
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        var button = new Button
        {
            Content = stack,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
        };
        button.Click += (_, _) => onClick(artist);
        return button;
    }

    public static Control SongRowContent(Song song, int index, bool isLiked, bool isPlaying)
    {
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("36,*,2*,Auto"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var indexBlock = new TextBlock
        {
            Text = isPlaying ? "\uE768" : (index + 1).ToString(),
            FontFamily = isPlaying
                ? new FontFamily("Segoe MDL2 Assets, Segoe Fluent Icons")
                : FontFamily.Default,
            Foreground = isPlaying ? CTColors.AccentBrush : CTColors.TextSecondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        grid.Children.Add(indexBlock);

        var title = new TextBlock
        {
            Text = song.Title,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = song.IsPlayable ? CTColors.TextPrimaryBrush : CTColors.TextSecondaryBrush,
        };
        Grid.SetColumn(title, 1);
        grid.Children.Add(title);

        var artist = new TextBlock
        {
            Text = song.ArtistNames,
            Classes = { "secondary" },
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0),
        };
        Grid.SetColumn(artist, 2);
        grid.Children.Add(artist);

        var right = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (isLiked)
        {
            right.Children.Add(new TextBlock
            {
                Text = "\uEB52",
                FontFamily = new FontFamily("Segoe MDL2 Assets, Segoe Fluent Icons"),
                FontSize = 12,
                Foreground = CTColors.AccentBrush,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        if (!song.IsPlayable && song.UnavailableReason is { } reason)
        {
            right.Children.Add(new TextBlock
            {
                Text = reason,
                Classes = { "secondary" },
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        right.Children.Add(new TextBlock
        {
            Text = CTFormatting.Time(song.Duration),
            Classes = { "secondary" },
            VerticalAlignment = VerticalAlignment.Center,
        });
        Grid.SetColumn(right, 3);
        grid.Children.Add(right);

        return new Border
        {
            Padding = new Thickness(6, 6),
            Child = grid,
        };
    }
}

public sealed class SongListView : UserControl
{
    private readonly ListBox _list = new();
    private IReadOnlyList<Song> _songs = Array.Empty<Song>();
    private AppState App => AppState.Shared;

    public SongListView()
    {
        _list.Background = Brushes.Transparent;
        _list.BorderThickness = new Thickness(0);
        _list.ItemTemplate = new FuncDataTemplate<Song>((song, _) =>
        {
            if (song is null) return new Control();
            var index = _songs.ToList().FindIndex(item => item.Id == song.Id);
            var isLiked = App.IsLiked(song.Id);
            var isPlaying = PlayerController.Shared.CurrentSong?.Id == song.Id;
            var content = UIComponents.SongRowContent(song, Math.Max(0, index), isLiked, isPlaying);
            content.ContextMenu = BuildContextMenu(song);
            return content;
        });
        _list.DoubleTapped += (_, _) =>
        {
            if (_list.SelectedItem is Song song)
            {
                var index = _songs.ToList().FindIndex(item => item.Id == song.Id);
                PlayerController.Shared.PlaySongs(_songs, Math.Max(0, index));
            }
        };
        App.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName is nameof(AppState.LikesVersion)) RefreshItems();
        };
        PlayerController.Shared.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName is nameof(PlayerController.CurrentSong)) RefreshItems();
        };
        Content = _list;
    }

    private void RefreshItems() => _list.ItemsSource = _songs.ToList();

    public void SetSongs(IReadOnlyList<Song> songs)
    {
        _songs = songs;
        _list.ItemsSource = songs.ToList();
    }

    private ContextMenu BuildContextMenu(Song song)
    {
        var menu = new ContextMenu();
        menu.Items.Add(MenuItem("立即播放", () => PlayerController.Shared.PlaySong(song)));
        menu.Items.Add(MenuItem("下一首播放", () => PlayerController.Shared.InsertNext(song)));
        menu.Items.Add(MenuItem("添加到队列", () => PlayerController.Shared.AppendToQueue(song)));
        menu.Items.Add(MenuItem("喜欢/取消喜欢", async () => await App.ToggleLikeAsync(song)));
        if (App.IsLoggedIn && App.UserPlaylists.Count > 0)
        {
            var addTo = new MenuItem { Header = "添加到歌单" };
            foreach (var playlist in App.UserPlaylists.Take(50))
            {
                var captured = playlist;
                var item = new MenuItem { Header = captured.Name };
                item.Click += async (_, _) => await App.ModifyPlaylistAsync(captured, new[] { song.Id }, true);
                addTo.Items.Add(item);
            }
            menu.Items.Add(addTo);
        }
        if (!string.IsNullOrEmpty(song.Album?.Id))
        {
            menu.Items.Add(MenuItem("打开专辑", () => App.OpenAlbum(song.Album!.Id)));
        }
        if (song.Artists.Count > 0)
        {
            menu.Items.Add(MenuItem("打开歌手", () => App.OpenArtist(song.Artists[0].Id)));
        }
        return menu;
    }

    private static MenuItem MenuItem(string header, Action action)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => action();
        return item;
    }
}
