using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using ClearTone.Core.Models;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Providers.Local;
using ClearTone.Shell;

namespace ClearTone.Features.Library;

[PageView(Page.Local)]
public sealed class LocalView : UserControl, IPageView
{
    private static readonly FilePickerFileType AudioFileType = new("音频文件")
    {
        Patterns = new[] { "*.mp3", "*.m4a", "*.aac", "*.wav", "*.flac", "*.aiff", "*.alac" },
    };

    private static LocalProvider Provider => LocalProvider.Shared;

    private readonly List<Song> _songs = new();
    private readonly SongListView _list = new();
    private readonly TextBox _searchBox = new();
    private readonly Border _searchRow;
    private readonly TextBlock _countText = new();
    private readonly ContentControl _host = new();
    private readonly Control _emptyPanel = UIComponents.StatusPanel("导入音频文件或文件夹开始播放");
    private readonly Control _noMatchPanel = UIComponents.StatusPanel("没有匹配的音乐");
    private readonly Control _importingPanel = UIComponents.StatusPanel("导入中…", showSpinner: true);
    private readonly TextBlock _title = new();

    private bool _isImporting;
    private string? _error;

    public LocalView()
    {
        _title.Text = "本地音乐";
        _title.Classes.Add("pageTitle");

        var importFiles = new Button { Content = "导入文件" };
        importFiles.Click += (_, _) => _ = ImportFilesAsync();
        var importFolder = new Button { Content = "导入文件夹" };
        importFolder.Click += (_, _) => _ = ImportFolderAsync();
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Sm,
            VerticalAlignment = VerticalAlignment.Center,
        };
        actions.Children.Add(importFiles);
        actions.Children.Add(importFolder);

        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        header.Children.Add(_title);
        Grid.SetColumn(actions, 1);
        header.Children.Add(actions);
        header.Margin = new Thickness(CTSpacing.Lg, CTSpacing.Lg, CTSpacing.Lg, CTSpacing.Sm);

        _searchBox.Watermark = "在本地音乐中搜索";
        _searchBox.Background = Brushes.Transparent;
        _searchBox.BorderThickness = new Thickness(0);
        _searchBox.VerticalAlignment = VerticalAlignment.Center;
        _searchBox.TextChanged += (_, _) => Render();

        _countText.Classes.Add("secondary");
        _countText.VerticalAlignment = VerticalAlignment.Center;
        _countText.IsVisible = false;

        var clear = new Button
        {
            Content = "清空",
            Classes = { "toolbar" },
            VerticalAlignment = VerticalAlignment.Center,
        };
        clear.Click += (_, _) => _searchBox.Text = "";

        var searchGrid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto,Auto") };
        searchGrid.Children.Add(new TextBlock
        {
            Text = "\uE721",
            FontFamily = new FontFamily("Segoe MDL2 Assets, Segoe Fluent Icons"),
            Foreground = CTColors.TextSecondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, CTSpacing.Sm, 0),
        });
        Grid.SetColumn(_searchBox, 1);
        searchGrid.Children.Add(_searchBox);
        Grid.SetColumn(_countText, 2);
        searchGrid.Children.Add(_countText);
        Grid.SetColumn(clear, 3);
        searchGrid.Children.Add(clear);

        _searchRow = new Border
        {
            Background = CTColors.PanelBrush,
            CornerRadius = new CornerRadius(CTRadius.Small),
            Padding = new Thickness(CTSpacing.Sm),
            Margin = new Thickness(CTSpacing.Lg, 0, CTSpacing.Lg, CTSpacing.Sm),
            IsVisible = false,
            Child = searchGrid,
        };

        _host.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _host.VerticalContentAlignment = VerticalAlignment.Stretch;

        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*"), Background = CTColors.BackgroundBrush };
        root.Children.Add(header);
        Grid.SetRow(_searchRow, 1);
        root.Children.Add(_searchRow);
        Grid.SetRow(_host, 2);
        root.Children.Add(_host);
        Content = root;

        AttachedToVisualTree += (_, _) => _ = RestoreAsync();
        Render();
    }

    public void OnActivated()
    {
    }

    private async Task RestoreAsync()
    {
        try
        {
            var songs = await Provider.RestoreLibraryAsync();
            _songs.Clear();
            _songs.AddRange(songs);
            _title.Text = $"本地音乐（{_songs.Count}）";
        }
        catch (Exception error)
        {
            _error = error.CtUserMessage();
        }
        Render();
    }

    private async Task ImportFilesAsync()
    {
        TopLevel? top;
        IReadOnlyList<IStorageFile> files;
        try
        {
            top = TopLevel.GetTopLevel(this);
            if (top is null) return;
            files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "选择音频文件",
                AllowMultiple = true,
                FileTypeFilter = new[] { AudioFileType },
            });
        }
        catch (Exception error)
        {
            _error = error.CtUserMessage();
            Render();
            return;
        }

        var paths = files
            .Select(file => file.TryGetLocalPath())
            .Where(path => !string.IsNullOrEmpty(path))
            .Select(path => path!)
            .ToList();
        if (paths.Count == 0) return;
        await RunImportAsync(() => Provider.ImportFilesAsync(paths));
    }

    private async Task ImportFolderAsync()
    {
        TopLevel? top;
        IReadOnlyList<IStorageFolder> folders;
        try
        {
            top = TopLevel.GetTopLevel(this);
            if (top is null) return;
            folders = await top.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
            {
                Title = "选择音乐文件夹",
                AllowMultiple = false,
            });
        }
        catch (Exception error)
        {
            _error = error.CtUserMessage();
            Render();
            return;
        }

        var folder = folders.Select(item => item.TryGetLocalPath()).FirstOrDefault(path => !string.IsNullOrEmpty(path));
        if (folder is null) return;
        await RunImportAsync(() => Provider.ScanDirectoryAsync(folder!));
    }

    private async Task RunImportAsync(Func<Task<List<Song>>> action)
    {
        if (_isImporting) return;
        _isImporting = true;
        _error = null;
        Render();
        try
        {
            await action();
            _songs.Clear();
            _songs.AddRange(Provider.AllSongs());
            _title.Text = $"本地音乐（{_songs.Count}）";
        }
        catch (Exception error)
        {
            _error = error.CtUserMessage();
        }
        finally
        {
            _isImporting = false;
        }
        Render();
    }

    private List<Song> Filtered()
    {
        var keyword = (_searchBox.Text ?? "").Trim();
        if (keyword.Length == 0) return _songs.ToList();
        return _songs
            .Where(song =>
                song.Title.Contains(keyword, StringComparison.CurrentCultureIgnoreCase) ||
                song.ArtistNames.Contains(keyword, StringComparison.CurrentCultureIgnoreCase) ||
                (song.Album?.Name.Contains(keyword, StringComparison.CurrentCultureIgnoreCase) ?? false))
            .ToList();
    }

    private void Render()
    {
        var filtered = Filtered();
        _searchRow.IsVisible = _songs.Count > 0;
        _countText.IsVisible = (_searchBox.Text ?? "").Trim().Length > 0;
        _countText.Text = $"{filtered.Count} / {_songs.Count}";

        if (_isImporting)
        {
            _host.Content = _importingPanel;
            return;
        }
        if (_error is { } error)
        {
            _host.Content = UIComponents.ErrorPanel(error, () =>
            {
                _error = null;
                if (_songs.Count == 0) _ = RestoreAsync();
                else Render();
            });
            return;
        }
        if (_songs.Count == 0)
        {
            _host.Content = _emptyPanel;
            return;
        }
        if (filtered.Count == 0)
        {
            _host.Content = _noMatchPanel;
            return;
        }

        _list.SetSongs(filtered);
        _host.Content = _list;
    }
}
