using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Data;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using ClearTone.Core.Models;
using CommunityToolkit.Mvvm.ComponentModel;
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

public sealed class SongRowModel : ObservableObject
{
    private static readonly IBrush PrimaryBrush = new SolidColorBrush(CTColors.TextPrimary);
    private static readonly IBrush SecondaryBrush = new SolidColorBrush(CTColors.TextSecondary);
    private static readonly IBrush AccentBrush = new SolidColorBrush(CTColors.Accent);

    private bool _isLiked;
    private bool _isPlaying;

    public SongRowModel(Song song, int index, bool isLiked)
    {
        Song = song;
        Index = index;
        _isLiked = isLiked;
    }

    public Song Song { get; }
    public int Index { get; }
    public string IndexText => (Index + 1).ToString();
    public string Title => Song.Title;
    public string ArtistNames => Song.ArtistNames;
    public string DurationText => CTFormatting.Time(Song.Duration);
    public string? CoverUrl => Song.CoverURL;
    public bool IsPlayable => Song.IsPlayable;
    public bool HasUnavailableReason => !string.IsNullOrEmpty(Song.UnavailableReason);
    public string? UnavailableReason => Song.UnavailableReason;
    public IBrush TitleBrush => Song.IsPlayable ? PrimaryBrush : SecondaryBrush;

    public bool IsLiked
    {
        get => _isLiked;
        set => SetProperty(ref _isLiked, value);
    }

    public bool IsPlaying
    {
        get => _isPlaying;
        set
        {
            if (!SetProperty(ref _isPlaying, value)) return;
            OnPropertyChanged(nameof(NotPlaying));
            OnPropertyChanged(nameof(IndexBrush));
        }
    }

    public bool NotPlaying => !_isPlaying;

    public IBrush IndexBrush => _isPlaying ? AccentBrush : SecondaryBrush;
}

public sealed class SongListView : UserControl
{
    private static readonly FontFamily IconFont = new("Segoe MDL2 Assets, Segoe Fluent Icons");

    private readonly ListBox _list = new();
    private IReadOnlyList<Song> _songs = Array.Empty<Song>();
    private List<SongRowModel> _rows = new();
    private SongRowModel? _playingRow;
    private AppState App => AppState.Shared;

    public SongListView()
    {
        _list.Background = Brushes.Transparent;
        _list.BorderThickness = new Thickness(0);
        _list.ItemTemplate = new FuncDataTemplate<SongRowModel>((row, _) =>
            row is null ? new Control() : BuildRow(row));
        _list.DoubleTapped += (_, _) =>
        {
            if (_list.SelectedItem is SongRowModel row && _songs.Count > 0)
            {
                PlayerController.Shared.PlaySongs(_songs, Math.Clamp(row.Index, 0, _songs.Count - 1));
            }
        };
        App.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName is nameof(AppState.LikesVersion)) RefreshLikes();
        };
        PlayerController.Shared.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName is nameof(PlayerController.CurrentSong)) RefreshPlaying();
        };
        Content = _list;
    }

    public void SetSongs(IReadOnlyList<Song> songs)
    {
        _songs = songs;
        _rows = songs.Select((song, index) => new SongRowModel(song, index, App.IsLiked(song.Id))).ToList();
        _playingRow = null;
        _list.ItemsSource = _rows;
        RefreshPlaying();
    }

    private void RefreshLikes()
    {
        foreach (var row in _rows)
        {
            row.IsLiked = App.IsLiked(row.Song.Id);
        }
    }

    private void RefreshPlaying()
    {
        var songID = PlayerController.Shared.CurrentSong?.Id;
        if (_playingRow is not null && _playingRow.Song.Id != songID)
        {
            _playingRow.IsPlaying = false;
            _playingRow = null;
        }
        if (songID is null || _playingRow is not null) return;
        _playingRow = _rows.FirstOrDefault(row => row.Song.Id == songID);
        if (_playingRow is not null) _playingRow.IsPlaying = true;
    }

    private static Control BuildRow(SongRowModel row)
    {
        var grid = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("30,44,*,2*,Auto"),
            VerticalAlignment = VerticalAlignment.Center,
        };

        var indexText = new TextBlock
        {
            Text = row.IndexText,
            Foreground = row.IndexBrush,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        indexText.Bind(IsVisibleProperty, new Binding(nameof(SongRowModel.NotPlaying)));
        indexText.Bind(TextBlock.ForegroundProperty, new Binding(nameof(SongRowModel.IndexBrush)));
        var playingGlyph = new TextBlock
        {
            Text = "\uE768",
            FontFamily = IconFont,
            FontSize = 13,
            Foreground = row.IndexBrush,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        playingGlyph.Bind(IsVisibleProperty, new Binding(nameof(SongRowModel.IsPlaying)));
        var indexPanel = new Panel();
        indexPanel.Children.Add(indexText);
        indexPanel.Children.Add(playingGlyph);
        grid.Children.Add(indexPanel);

        var cover = new Controls.CoverImage
        {
            Width = 36,
            Height = 36,
            CornerRadius = new CornerRadius(4),
            DecodeWidth = 72,
            CoverUrl = row.CoverUrl,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(cover, 1);
        grid.Children.Add(cover);

        var title = new TextBlock
        {
            Text = row.Title,
            Foreground = row.TitleBrush,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(CTSpacing.Sm, 0, 0, 0),
        };
        Grid.SetColumn(title, 2);
        grid.Children.Add(title);

        var artist = new TextBlock
        {
            Text = row.ArtistNames,
            Classes = { "secondary" },
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(CTSpacing.Sm, 0),
        };
        Grid.SetColumn(artist, 3);
        grid.Children.Add(artist);

        var right = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Sm,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var likeIcon = new TextBlock
        {
            Text = "\uEB52",
            FontFamily = IconFont,
            FontSize = 12,
            Foreground = new SolidColorBrush(CTColors.Accent),
            VerticalAlignment = VerticalAlignment.Center,
        };
        likeIcon.Bind(IsVisibleProperty, new Binding(nameof(SongRowModel.IsLiked)));
        right.Children.Add(likeIcon);
        if (row.HasUnavailableReason)
        {
            right.Children.Add(new TextBlock
            {
                Text = row.UnavailableReason,
                Classes = { "secondary" },
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        right.Children.Add(new TextBlock
        {
            Text = row.DurationText,
            Classes = { "secondary" },
            VerticalAlignment = VerticalAlignment.Center,
        });
        Grid.SetColumn(right, 4);
        grid.Children.Add(right);

        var container = new Border
        {
            Padding = new Thickness(6, 4),
            Child = grid,
        };
        container.ContextMenu = BuildContextMenu(row.Song);
        return container;
    }

    private static ContextMenu BuildContextMenu(Song song)
    {
        var app = AppState.Shared;
        var menu = new ContextMenu();
        menu.Items.Add(MenuItem("立即播放", () => PlayerController.Shared.PlaySong(song)));
        menu.Items.Add(MenuItem("下一首播放", () => PlayerController.Shared.InsertNext(song)));
        menu.Items.Add(MenuItem("添加到队列", () => PlayerController.Shared.AppendToQueue(song)));
        menu.Items.Add(MenuItem("喜欢/取消喜欢", async () => await app.ToggleLikeAsync(song)));
        if (app.IsLoggedIn && app.UserPlaylists.Count > 0)
        {
            var addTo = new MenuItem { Header = "添加到歌单" };
            foreach (var playlist in app.UserPlaylists.Take(50))
            {
                var captured = playlist;
                var item = new MenuItem { Header = captured.Name };
                item.Click += async (_, _) => await app.ModifyPlaylistAsync(captured, new[] { song.Id }, true);
                addTo.Items.Add(item);
            }
            menu.Items.Add(addTo);
        }
        if (!string.IsNullOrEmpty(song.Album?.Id))
        {
            menu.Items.Add(MenuItem("打开专辑", () => app.OpenAlbum(song.Album!.Id)));
        }
        if (song.Artists.Count > 0)
        {
            menu.Items.Add(MenuItem("打开歌手", () => app.OpenArtist(song.Artists[0].Id)));
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
