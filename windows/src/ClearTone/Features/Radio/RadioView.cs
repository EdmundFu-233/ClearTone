using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
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

[PageView(Page.Radio)]
public sealed class RadioView : UserControl, IPageView
{
    public static string? PendingStationID { get; set; }

    private static readonly FontFamily IconFont = new("Segoe MDL2 Assets, Segoe Fluent Icons");
    private const int PageSize = 30;

    private static PlayerController Player => PlayerController.Shared;
    private static NeteaseProvider Provider => NeteaseProvider.Shared;

    private readonly StackPanel _chipRow = new() { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Sm };
    private readonly ScrollViewer _chipScroll;
    private readonly ContentControl _host = new();
    private readonly TextBlock _subtitle;

    private List<RadioCategory> _categories = new();
    private string? _selectedCategoryID;
    private List<RadioStation> _radios = new();
    private bool _isLoading;
    private string? _errorMessage;
    private Guid _loadToken;
    private bool _categoriesLoaded;
    private bool _loaded;

    private string? _detailID;
    private RadioStation? _station;
    private List<RadioProgram> _programs = new();
    private bool _isLoadingDetail;
    private bool _isLoadingMore;
    private bool _hasMore;
    private int _page = 1;
    private string? _detailError;
    private Guid _detailToken;

    public RadioView()
    {
        _subtitle = new TextBlock { Text = "主播的声音，长音频节目。", Classes = { "secondary" } };

        _chipScroll = new ScrollViewer
        {
            Content = _chipRow,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Margin = new Thickness(CTSpacing.Xl, 0, CTSpacing.Xl, CTSpacing.Md),
        };

        var titleStack = new StackPanel { Spacing = CTSpacing.Xs };
        titleStack.Children.Add(new TextBlock { Text = "电台", Classes = { "pageTitle" } });
        titleStack.Children.Add(_subtitle);
        titleStack.Margin = new Thickness(CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Xl, CTSpacing.Md);

        _host.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _host.VerticalContentAlignment = VerticalAlignment.Stretch;

        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*"), Background = CTColors.BackgroundBrush };
        root.Children.Add(titleStack);
        Grid.SetRow(_chipScroll, 1);
        root.Children.Add(_chipScroll);
        Grid.SetRow(_host, 2);
        root.Children.Add(_host);
        Content = root;

        AttachedToVisualTree += (_, _) => OnAttached();
        Render();
    }

    public void OnActivated()
    {
    }

    private void OnAttached()
    {
        if (!_categoriesLoaded)
        {
            _categoriesLoaded = true;
            _ = LoadCategoriesAsync();
        }
        if (!_loaded)
        {
            _loaded = true;
            _ = LoadRadiosAsync();
        }
        if (PendingStationID is { Length: > 0 } pending)
        {
            PendingStationID = null;
            _ = OpenStationAsync(pending);
        }
    }

    private async Task LoadCategoriesAsync()
    {
        try
        {
            var loaded = await Provider.FetchRadioCategoriesAsync();
            _categories = loaded;
            RenderChips();
        }
        catch
        {
            _categories = new List<RadioCategory>();
            RenderChips();
        }
    }

    private async Task LoadRadiosAsync()
    {
        var token = Guid.NewGuid();
        _loadToken = token;
        _isLoading = true;
        _errorMessage = null;
        Render();
        try
        {
            List<RadioStation> loaded;
            if (!string.IsNullOrEmpty(_selectedCategoryID))
            {
                loaded = await Provider.FetchHotRadiosAsync(_selectedCategoryID, 40);
            }
            else
            {
                loaded = await Provider.FetchRecommendedRadiosAsync(40);
                if (loaded.Count == 0)
                {
                    loaded = await Provider.FetchHotRadiosAsync(limit: 40);
                }
            }
            if (_loadToken != token) return;
            _radios = loaded;
        }
        catch (Exception error)
        {
            if (_loadToken != token) return;
            _radios = new List<RadioStation>();
            _errorMessage = error.CtUserMessage();
        }
        if (_loadToken != token) return;
        _isLoading = false;
        Render();
    }

    private void RenderChips()
    {
        _chipRow.Children.Clear();
        _chipRow.Children.Add(BuildChip("全部", null));
        foreach (var category in _categories)
        {
            _chipRow.Children.Add(BuildChip(category.Name, category.Id));
        }
        if (_detailID is null) _chipScroll.IsVisible = _categories.Count > 0;
    }

    private Control BuildChip(string title, string? id)
    {
        var selected = _selectedCategoryID == id;
        var button = new Button
        {
            Content = title,
            Background = selected ? CTColors.AccentBrush : CTColors.OverlayBrush,
            Foreground = selected ? Brushes.White : CTColors.TextSecondaryBrush,
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(CTRadius.Small),
            Padding = new Thickness(12, 5),
            FontSize = 12,
        };
        button.Click += (_, _) =>
        {
            if (_selectedCategoryID == id) return;
            _selectedCategoryID = id;
            RenderChips();
            _ = LoadRadiosAsync();
        };
        return button;
    }

    private void Render()
    {
        if (_detailID is not null)
        {
            _chipScroll.IsVisible = false;
            _subtitle.Text = "主播的声音，长音频节目。";
            RenderDetail();
            return;
        }
        _chipScroll.IsVisible = _categories.Count > 0;
        _subtitle.Text = _isLoading && _radios.Count == 0 ? "正在获取电台…" : "主播的声音，长音频节目。";
        RenderList();
    }

    private void RenderList()
    {
        if (_isLoading && _radios.Count == 0)
        {
            _host.Content = UIComponents.StatusPanel("加载中…", showSpinner: true);
            return;
        }
        if (_errorMessage is { } error && _radios.Count == 0)
        {
            _host.Content = UIComponents.ErrorPanel(error, () => _ = LoadRadiosAsync());
            return;
        }
        if (_radios.Count == 0)
        {
            _host.Content = UIComponents.StatusPanel("没有找到电台");
            return;
        }
        var wrap = new WrapPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(CTSpacing.Xl, 0, CTSpacing.Xl, CTSpacing.Xl),
        };
        foreach (var radio in _radios)
        {
            var card = BuildRadioCard(radio);
            card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
            wrap.Children.Add(card);
        }
        _host.Content = wrap;
    }

    private Control BuildRadioCard(RadioStation radio)
    {
        var stack = new StackPanel { Spacing = CTSpacing.Sm, Width = 160 };
        stack.Children.Add(new CoverImage
        {
            Width = 160,
            Height = 160,
            CornerRadius = new CornerRadius(CTRadius.Medium),
            CoverUrl = radio.CoverURL,
            DecodeWidth = 320,
        });
        stack.Children.Add(new TextBlock
        {
            Text = radio.Name,
            FontWeight = FontWeight.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 160,
        });
        var parts = new List<string>();
        if (!string.IsNullOrEmpty(radio.CreatorName)) parts.Add(radio.CreatorName);
        if (radio.ProgramCount > 0) parts.Add($"{radio.ProgramCount} 期");
        stack.Children.Add(new TextBlock
        {
            Text = parts.Count > 0 ? string.Join(" · ", parts) : "电台",
            Classes = { "secondary" },
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = 160,
        });

        var button = new Button
        {
            Content = stack,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
        };
        button.Click += (_, _) => _ = OpenStationAsync(radio.Id);
        return button;
    }

    private async Task OpenStationAsync(string id, bool force = false)
    {
        if (!force && _detailID == id)
        {
            Render();
            return;
        }
        var token = Guid.NewGuid();
        _detailToken = token;
        _detailID = id;
        _station = null;
        _programs = new List<RadioProgram>();
        _detailError = null;
        _isLoadingDetail = true;
        _isLoadingMore = false;
        _hasMore = true;
        _page = 1;
        Render();

        try
        {
            var loaded = await Provider.FetchRadioProgramsAsync(id, 1, PageSize);
            if (_detailToken != token) return;
            _programs = loaded.AsEnumerable().Reverse().ToList();
            _page = 1;
            _hasMore = loaded.Count >= PageSize;
        }
        catch (Exception error)
        {
            if (_detailToken != token) return;
            _detailError = error.CtUserMessage();
            _isLoadingDetail = false;
            Render();
            return;
        }

        _isLoadingDetail = false;
        Render();
        await LoadStationDetailAsync(id, token);
    }

    private async Task LoadStationDetailAsync(string id, Guid token)
    {
        try
        {
            var detail = await Provider.FetchRadioStationDetailAsync(id);
            if (_detailToken != token) return;
            _station = detail;
        }
        catch
        {
            if (_detailToken != token) return;
            _station ??= new RadioStation { Id = id, Name = "电台", ProgramCount = _programs.Count };
        }
        Render();
    }

    private async Task LoadMoreProgramsAsync()
    {
        if (!_hasMore || _isLoadingMore || _isLoadingDetail || _detailID is null) return;
        var radioID = _detailID;
        var token = _detailToken;
        _isLoadingMore = true;
        Render();
        try
        {
            var next = _page + 1;
            var loaded = await Provider.FetchRadioProgramsAsync(radioID, next, PageSize);
            if (_detailToken != token) return;
            _programs = loaded.AsEnumerable().Reverse().Concat(_programs).ToList();
            _page = next;
            _hasMore = loaded.Count >= PageSize;
        }
        catch
        {
            if (_detailToken != token) return;
            _hasMore = false;
        }
        if (_detailToken != token) return;
        _isLoadingMore = false;
        Render();
    }

    private void CloseDetail()
    {
        _detailToken = Guid.NewGuid();
        _detailID = null;
        _station = null;
        _programs = new List<RadioProgram>();
        _detailError = null;
        _isLoadingDetail = false;
        _isLoadingMore = false;
        _hasMore = false;
        Render();
    }

    private void RenderDetail()
    {
        if (_isLoadingDetail && _station is null && _programs.Count == 0)
        {
            _host.Content = UIComponents.StatusPanel("加载中…", showSpinner: true);
            return;
        }
        if (_detailError is { } error && _station is null && _programs.Count == 0)
        {
            var id = _detailID ?? "";
            _host.Content = UIComponents.ErrorPanel(error, () => _ = OpenStationAsync(id, force: true));
            return;
        }
        _host.Content = BuildDetailPanel();
    }

    private Control BuildDetailPanel()
    {
        var station = _station;
        var playable = _programs.Where(program => program.IsPlayable && program.Song is not null).ToList();
        var songs = playable.Select(program => program.Song!).ToList();

        var panel = new StackPanel { Spacing = CTSpacing.Lg, Margin = new Thickness(CTSpacing.Xl) };
        panel.Children.Add(UIComponents.LinkButton("← 返回电台列表", CloseDetail));

        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*") };
        header.Children.Add(new CoverImage
        {
            Width = 160,
            Height = 160,
            CornerRadius = new CornerRadius(CTRadius.Medium),
            CoverUrl = station?.CoverURL,
            DecodeWidth = 320,
            VerticalAlignment = VerticalAlignment.Top,
        });

        var info = new StackPanel { Spacing = CTSpacing.Sm, Margin = new Thickness(CTSpacing.Lg, 0, 0, 0) };
        info.Children.Add(new TextBlock
        {
            Text = station?.Name ?? "电台",
            Classes = { "pageTitle" },
            TextWrapping = TextWrapping.Wrap,
        });
        if (station is { CreatorName: { Length: > 0 } creator })
        {
            info.Children.Add(new TextBlock { Text = $"主播：{creator}", Classes = { "secondary" } });
        }
        var stats = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Lg };
        if (station is { ProgramCount: > 0 })
        {
            stats.Children.Add(new TextBlock { Text = $"{station.ProgramCount} 期", Classes = { "secondary" } });
        }
        else if (_programs.Count > 0)
        {
            stats.Children.Add(new TextBlock { Text = $"{_programs.Count} 期", Classes = { "secondary" } });
        }
        if (station is { SubscriberCount: > 0 })
        {
            stats.Children.Add(new TextBlock { Text = $"{station.SubscriberCount} 订阅", Classes = { "secondary" } });
        }
        info.Children.Add(stats);

        var playAll = new Button { Content = "播放全部节目", Classes = { "accent" }, IsEnabled = songs.Count > 0 };
        playAll.Click += (_, _) =>
        {
            if (songs.Count > 0) Player.PlaySongs(songs, 0);
        };
        info.Children.Add(playAll);
        Grid.SetColumn(info, 1);
        header.Children.Add(info);
        panel.Children.Add(header);

        panel.Children.Add(new Border { Height = 1, Background = CTColors.OverlayBrush });

        if (_programs.Count == 0)
        {
            panel.Children.Add(_isLoadingDetail
                ? UIComponents.StatusPanel("加载中…", showSpinner: true)
                : UIComponents.StatusPanel("该电台还没有节目"));
        }
        else
        {
            var list = new ListBox
            {
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                ItemsSource = playable,
            };
            list.ItemTemplate = new FuncDataTemplate<RadioProgram>((program, _) =>
                program is null ? new Control() : BuildProgramRow(program, playable, songs));
            list.DoubleTapped += (_, _) =>
            {
                if (list.SelectedItem is not RadioProgram program) return;
                var index = playable.FindIndex(item => item.Id == program.Id);
                if (index >= 0 && index < songs.Count) Player.PlaySongs(songs, index);
            };
            panel.Children.Add(list);

            if (_isLoadingMore)
            {
                panel.Children.Add(UIComponents.StatusPanel("加载中…", showSpinner: true));
            }
            else if (_hasMore)
            {
                var more = new Button { Content = "加载更多节目", HorizontalAlignment = HorizontalAlignment.Center };
                more.Click += (_, _) => _ = LoadMoreProgramsAsync();
                panel.Children.Add(more);
            }
        }

        return new ScrollViewer
        {
            Content = panel,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
    }

    private static Control BuildProgramRow(RadioProgram program, IReadOnlyList<RadioProgram> playable, IReadOnlyList<Song> songs)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        grid.Children.Add(new CoverImage
        {
            Width = 44,
            Height = 44,
            CornerRadius = new CornerRadius(CTRadius.Small),
            CoverUrl = program.CoverURL,
            DecodeWidth = 88,
        });

        var text = new StackPanel { Spacing = 2, Margin = new Thickness(CTSpacing.Md, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock
        {
            Text = program.Title,
            FontWeight = FontWeight.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        var meta = new StackPanel { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Sm };
        if (program.Duration > 0)
        {
            meta.Children.Add(new TextBlock { Text = CTFormatting.Time(program.Duration), Classes = { "secondary" } });
        }
        if (program.CreateTime is { } created)
        {
            meta.Children.Add(new TextBlock { Text = created.ToString("yyyy-MM-dd"), Classes = { "secondary" } });
        }
        if (program.PlayCount > 0)
        {
            meta.Children.Add(new TextBlock { Text = $"{program.PlayCount} 次播放", Classes = { "secondary" } });
        }
        text.Children.Add(meta);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var index = playable.ToList().FindIndex(item => item.Id == program.Id);
        var play = new Button
        {
            Content = "\uE768",
            FontFamily = IconFont,
            FontSize = 16,
            Foreground = CTColors.AccentBrush,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(6),
            VerticalAlignment = VerticalAlignment.Center,
        };
        play.Click += (_, _) =>
        {
            if (index >= 0 && index < songs.Count) Player.PlaySongs(songs, index);
        };
        Grid.SetColumn(play, 2);
        grid.Children.Add(play);

        var row = new Border { Child = grid, Padding = new Thickness(CTSpacing.Sm), Background = Brushes.Transparent };
        row.DoubleTapped += (_, _) =>
        {
            if (index >= 0 && index < songs.Count) Player.PlaySongs(songs, index);
        };
        return row;
    }
}
