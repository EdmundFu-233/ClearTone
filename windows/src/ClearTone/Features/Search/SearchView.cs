using System.ComponentModel;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Avalonia.VisualTree;
using ClearTone.Core.Models;
using ClearTone.Core.Search;
using ClearTone.DesignSystem;
using ClearTone.Features.Shared;
using ClearTone.Shell;

namespace ClearTone.Features.Search;

[PageView(Page.Search)]
public sealed class SearchView : UserControl, IPageView
{
    private static readonly FontFamily IconFont = new("Segoe MDL2 Assets, Segoe Fluent Icons");
    private static AppState App => AppState.Shared;

    private readonly SearchSession _session = new();
    private readonly SearchAssistStore _assist = new();
    private readonly Grid _root = new();
    private readonly TextBox _searchBox;
    private readonly Button _clearButton;
    private readonly StackPanel _typePicker = new() { Orientation = Orientation.Horizontal, Spacing = CTSpacing.Sm };
    private readonly Border _assistHost = new() { IsVisible = false };
    private readonly ContentControl _resultHost = new();
    private readonly ContentControl _footerHost = new();

    private SearchType _searchType = SearchType.Song;
    private bool _assistOpen;
    private bool _suppressTextChange;
    private bool _pendingScrollToEnd;
    private bool _hasRendered;
    private string _lastDataContextKey = "";
    private ScrollViewer? _hookedScroll;
    private SearchResult? _renderedResult;
    private string? _renderedError;
    private bool _renderedLoading;
    private SearchType _renderedType;

    public SearchView()
    {
        _searchBox = new TextBox
        {
            Watermark = "搜索歌曲、歌手、专辑、歌单",
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        _searchBox.KeyDown += OnSearchBoxKeyDown;
        _searchBox.TextChanged += OnSearchBoxTextChanged;
        _searchBox.GotFocus += (_, _) =>
        {
            _assistOpen = true;
            _ = _assist.LoadHotTermsAsync();
            RenderAssist();
        };

        _clearButton = new Button
        {
            Content = "\uE711",
            FontFamily = IconFont,
            FontSize = 12,
            IsVisible = false,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(4),
            Foreground = CTColors.TextSecondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        _clearButton.Click += (_, _) => ClearSearch();

        var bar = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        bar.Children.Add(new TextBlock
        {
            Text = "\uE721",
            FontFamily = IconFont,
            Foreground = CTColors.TextSecondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, CTSpacing.Sm, 0),
        });
        Grid.SetColumn(_searchBox, 1);
        bar.Children.Add(_searchBox);
        Grid.SetColumn(_clearButton, 2);
        bar.Children.Add(_clearButton);

        var barBorder = new Border
        {
            Padding = new Thickness(CTSpacing.Md),
            Background = CTColors.PanelBrush,
            CornerRadius = new CornerRadius(CTRadius.Medium),
            Margin = new Thickness(CTSpacing.Lg, CTSpacing.Lg, CTSpacing.Lg, 0),
            Child = bar,
        };

        var searchArea = new StackPanel { Spacing = 0 };
        searchArea.Children.Add(barBorder);
        _assistHost.Margin = new Thickness(CTSpacing.Lg, CTSpacing.Xs, CTSpacing.Lg, 0);
        searchArea.Children.Add(_assistHost);

        _typePicker.Margin = new Thickness(CTSpacing.Lg, CTSpacing.Md, CTSpacing.Lg, CTSpacing.Md);
        RenderTypePicker();

        _root.RowDefinitions = new RowDefinitions("Auto,Auto,*,Auto");
        _root.Background = CTColors.BackgroundBrush;
        _root.Children.Add(searchArea);
        Grid.SetRow(_typePicker, 1);
        _root.Children.Add(_typePicker);
        _resultHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _resultHost.VerticalContentAlignment = VerticalAlignment.Stretch;
        Grid.SetRow(_resultHost, 2);
        _root.Children.Add(_resultHost);
        _footerHost.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        Grid.SetRow(_footerHost, 3);
        _root.Children.Add(_footerHost);

        Content = _root;

        _session.PropertyChanged += (_, _) => Post(Render);
        _assist.PropertyChanged += (_, _) => Post(RenderAssist);
        App.PropertyChanged += OnAppPropertyChanged;
        AttachedToVisualTree += (_, _) => Attach();
        DetachedFromVisualTree += (_, _) => _session.CancelInFlight();
        _lastDataContextKey = App.DataContextKey;

        RenderTypePicker();
        Render();
        RenderAssist();
        _ = _assist.LoadHotTermsAsync();
    }

    public void OnActivated()
    {
    }

    private void Attach()
    {
        var incoming = App.SearchQuery.Trim();
        if (incoming.Length == 0) return;
        SyncDraft(incoming);
        if (_session.ActiveQuery != incoming) Submit();
    }

    private void OnAppPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppState.DataContextKey):
            case nameof(AppState.Account):
            case nameof(AppState.IsLoggedIn):
            case nameof(AppState.CurrentAccountGeneration):
                Post(RefreshDataContext);
                break;
            case nameof(AppState.SearchQuery):
                Post(() => ApplyExternalQuery(App.SearchQuery));
                break;
        }
    }

    private void RefreshDataContext()
    {
        var key = App.DataContextKey;
        if (key == _lastDataContextKey) return;
        _lastDataContextKey = key;
        _session.RefreshDataContext(_searchType);
    }

    private void ApplyExternalQuery(string query)
    {
        var incoming = query.Trim();
        if (incoming.Length == 0) return;
        if (_session.ActiveQuery == incoming)
        {
            SyncDraft(incoming);
            return;
        }
        SyncDraft(incoming);
        Submit();
    }

    private void OnSearchBoxTextChanged(object? sender, TextChangedEventArgs e)
    {
        if (_suppressTextChange) return;
        var text = _searchBox.Text ?? "";
        _session.DraftQuery = text;
        _clearButton.IsVisible = text.Length > 0;
        if (!_searchBox.IsFocused) return;
        _assistOpen = true;
        _assist.QuerySuggestions(text);
        RenderAssist();
    }

    private void OnSearchBoxKeyDown(object? sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Enter:
                e.Handled = true;
                Submit();
                break;
            case Key.Escape:
                e.Handled = true;
                CloseAssist();
                break;
        }
    }

    private void SyncDraft(string text)
    {
        _suppressTextChange = true;
        _searchBox.Text = text;
        _suppressTextChange = false;
        _clearButton.IsVisible = text.Length > 0;
        _session.DraftQuery = text;
    }

    private void Submit()
    {
        var keyword = (_searchBox.Text ?? "").Trim();
        if (keyword.Length == 0) return;
        _session.DraftQuery = keyword;
        _assist.RecordSearch(keyword);
        if (App.SearchQuery != keyword) App.SearchQuery = keyword;
        CloseAssist();
        _pendingScrollToEnd = false;
        _session.Submit(_searchType);
        Render();
    }

    private void ClearSearch()
    {
        _suppressTextChange = true;
        _searchBox.Text = "";
        _suppressTextChange = false;
        _clearButton.IsVisible = false;
        _session.Reset();
        _assist.ClearSuggestions();
        CloseAssist();
        Render();
    }

    private void SwitchType(SearchType type)
    {
        if (_searchType == type) return;
        _searchType = type;
        RenderTypePicker();
        CloseAssist();
        if ((_searchBox.Text ?? "").Trim().Length == 0)
        {
            _session.Reset();
            Render();
        }
        else
        {
            Submit();
        }
    }

    private void CloseAssist()
    {
        _assistOpen = false;
        RenderAssist();
    }

    private void RenderTypePicker()
    {
        _typePicker.Children.Clear();
        foreach (var type in SearchTypeExtensions.All)
        {
            var selected = type == _searchType;
            var button = new Button
            {
                Content = type.DisplayName(),
                Background = selected ? CTColors.AccentBrush : CTColors.OverlayBrush,
                Foreground = selected ? Brushes.White : CTColors.TextPrimaryBrush,
                BorderThickness = new Thickness(0),
                CornerRadius = new CornerRadius(CTRadius.Small),
                Padding = new Thickness(14, 6),
            };
            var captured = type;
            button.Click += (_, _) => SwitchType(captured);
            _typePicker.Children.Add(button);
        }
    }

    private void RenderAssist()
    {
        if (!_assistOpen)
        {
            _assistHost.IsVisible = false;
            _assistHost.Child = null;
            return;
        }

        var stack = new StackPanel { Spacing = 0 };
        var closeRow = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        var close = new Button
        {
            Content = "\uE711",
            FontFamily = IconFont,
            FontSize = 12,
            Classes = { "toolbar" },
        };
        close.Click += (_, _) => CloseAssist();
        Grid.SetColumn(close, 1);
        closeRow.Children.Add(close);
        stack.Children.Add(closeRow);

        var keyword = (_session.DraftQuery ?? "").Trim();
        if (keyword.Length > 0)
        {
            stack.Children.Add(BuildSuggestions());
        }
        else
        {
            stack.Children.Add(BuildHistory());
            stack.Children.Add(Divider());
            stack.Children.Add(BuildHotTerms());
        }

        _assistHost.Child = new Border
        {
            Background = CTColors.PanelBrush,
            BorderBrush = CTColors.OverlayBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(CTRadius.Medium),
            Child = stack,
        };
        _assistHost.IsVisible = true;
    }

    private Control BuildSuggestions()
    {
        if (_assist.IsLoadingSuggestions && _assist.Suggestions.Count == 0)
        {
            return SectionMessage("搜索中…");
        }
        if (_assist.Suggestions.Count == 0)
        {
            return SectionMessage("没有联想结果");
        }
        var rows = new StackPanel { Spacing = 0 };
        foreach (var suggestion in _assist.Suggestions)
        {
            rows.Children.Add(BuildSuggestionRow(suggestion));
        }
        return new ScrollViewer { MaxHeight = 320, Content = rows };
    }

    private Control BuildSuggestionRow(SearchSuggestion suggestion)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("20,*,Auto") };
        grid.Children.Add(new TextBlock
        {
            Text = KindGlyph(suggestion.SuggestionKind),
            FontFamily = IconFont,
            FontSize = 12,
            Foreground = CTColors.TextSecondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });

        var text = new StackPanel { Spacing = 1 };
        text.Children.Add(new TextBlock
        {
            Text = suggestion.Title,
            FontWeight = FontWeight.Medium,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        if (!string.IsNullOrEmpty(suggestion.Subtitle))
        {
            text.Children.Add(new TextBlock
            {
                Text = suggestion.Subtitle,
                Classes = { "secondary" },
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
        }
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var label = new TextBlock
        {
            Text = KindLabel(suggestion.SuggestionKind),
            Classes = { "secondary" },
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(CTSpacing.Sm, 0, 0, 0),
        };
        Grid.SetColumn(label, 2);
        grid.Children.Add(label);

        var button = new Button
        {
            Content = grid,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(CTSpacing.Lg, CTSpacing.Sm),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        button.Click += (_, _) => PickSuggestion(suggestion);
        return button;
    }

    private Control BuildHistory()
    {
        var stack = new StackPanel { Spacing = 0 };
        var header = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("*,Auto"),
            Margin = new Thickness(CTSpacing.Lg, CTSpacing.Md, CTSpacing.Lg, CTSpacing.Xs),
        };
        header.Children.Add(new TextBlock
        {
            Text = "搜索历史",
            Classes = { "caption" },
            Foreground = CTColors.TextSecondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (_assist.History.Count > 0)
        {
            var clear = UIComponents.LinkButton("清空", () =>
            {
                _assist.ClearHistory();
                RenderAssist();
            });
            Grid.SetColumn(clear, 1);
            header.Children.Add(clear);
        }
        stack.Children.Add(header);

        if (_assist.History.Count == 0)
        {
            stack.Children.Add(SectionMessage("暂无搜索历史"));
            return stack;
        }

        var rows = new StackPanel { Spacing = 0 };
        foreach (var term in _assist.History)
        {
            var captured = term;
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
            var pick = new Button
            {
                Content = captured,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Foreground = CTColors.TextPrimaryBrush,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Padding = new Thickness(CTSpacing.Lg, CTSpacing.Xs),
            };
            pick.Click += (_, _) => PickTerm(captured);
            row.Children.Add(pick);

            var remove = new Button
            {
                Content = "\uE711",
                FontFamily = IconFont,
                FontSize = 11,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Foreground = CTColors.TextSecondaryBrush,
                Padding = new Thickness(6),
                Margin = new Thickness(0, 0, CTSpacing.Sm, 0),
            };
            remove.Click += (_, _) =>
            {
                _assist.RemoveHistory(captured);
                RenderAssist();
            };
            Grid.SetColumn(remove, 1);
            row.Children.Add(remove);
            rows.Children.Add(row);
        }
        return new ScrollViewer { MaxHeight = 160, Content = rows };
    }

    private Control BuildHotTerms()
    {
        var stack = new StackPanel { Spacing = 0 };
        var header = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("*,Auto"),
            Margin = new Thickness(CTSpacing.Lg, 0, CTSpacing.Lg, CTSpacing.Xs),
        };
        header.Children.Add(new TextBlock
        {
            Text = "热门搜索",
            Classes = { "caption" },
            Foreground = CTColors.TextSecondaryBrush,
            VerticalAlignment = VerticalAlignment.Center,
        });
        if (_assist.IsLoadingHot)
        {
            var progress = new ProgressBar
            {
                IsIndeterminate = true,
                Width = 60,
                Height = 4,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(progress, 1);
            header.Children.Add(progress);
        }
        stack.Children.Add(header);

        if (_assist.HotError is { } error)
        {
            var row = new Grid
            {
                ColumnDefinitions = new ColumnDefinitions("*,Auto"),
                Margin = new Thickness(CTSpacing.Lg, 0, CTSpacing.Lg, CTSpacing.Md),
            };
            row.Children.Add(new TextBlock
            {
                Text = error,
                Classes = { "caption" },
                Foreground = CTColors.TextSecondaryBrush,
                TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center,
            });
            var retry = UIComponents.LinkButton(L10n.Common.Retry, () => _ = _assist.LoadHotTermsAsync());
            Grid.SetColumn(retry, 1);
            row.Children.Add(retry);
            stack.Children.Add(row);
            return stack;
        }

        if (_assist.HotTerms.Count == 0 && !_assist.IsLoadingHot)
        {
            stack.Children.Add(SectionMessage("暂无热搜数据"));
            return stack;
        }

        var wrap = new WrapPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(CTSpacing.Lg, 0, CTSpacing.Lg, CTSpacing.Md),
        };
        foreach (var term in _assist.HotTerms)
        {
            var captured = term;
            var text = string.IsNullOrEmpty(term.DisplayPrefix) ? term.Keyword : $"{term.DisplayPrefix} {term.Keyword}";
            var button = new Button
            {
                Content = text,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Foreground = CTColors.TextSecondaryBrush,
                FontSize = 12,
                Padding = new Thickness(6, 2),
                Width = 200,
                HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            button.Click += (_, _) => PickTerm(captured.Keyword);
            wrap.Children.Add(button);
        }
        return new ScrollViewer
        {
            MaxHeight = 200,
            Content = wrap,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
    }

    private void PickTerm(string term)
    {
        SyncDraft(term);
        CloseAssist();
        Submit();
    }

    private void PickSuggestion(SearchSuggestion suggestion)
    {
        CloseAssist();
        switch (suggestion.SuggestionKind)
        {
            case SearchSuggestion.Kind.Song:
                _searchType = SearchType.Song;
                RenderTypePicker();
                SyncDraft(suggestion.Title);
                Submit();
                break;
            case SearchSuggestion.Kind.Artist:
                App.OpenArtist(suggestion.TargetID);
                break;
            case SearchSuggestion.Kind.Album:
                App.OpenAlbum(suggestion.TargetID);
                break;
            default:
                App.OpenPlaylist(suggestion.TargetID);
                break;
        }
    }

    private void Render()
    {
        var result = _session.Result;
        var loading = _session.IsLoading;
        var error = _session.ErrorMessage;
        var type = _session.DisplayType;
        if (!_hasRendered ||
            !ReferenceEquals(_renderedResult, result) ||
            _renderedLoading != loading ||
            _renderedError != error ||
            _renderedType != type)
        {
            _hasRendered = true;
            _renderedResult = result;
            _renderedLoading = loading;
            _renderedError = error;
            _renderedType = type;
            _resultHost.Content = BuildResults();
            ScrollToEndAfterRebuild();
        }
        _footerHost.Content = BuildFooter();
    }

    private Control BuildResults()
    {
        if (_session.IsLoading)
        {
            return UIComponents.StatusPanel("加载中…", showSpinner: true);
        }
        if (_session.ErrorMessage is { } error)
        {
            return UIComponents.ErrorPanel(error, () => _session.Retry(_searchType));
        }
        if (_session.Result is not { } result)
        {
            return UIComponents.StatusPanel("搜索音乐");
        }
        if (result.IsEmpty)
        {
            return UIComponents.StatusPanel("没有找到相关结果");
        }
        return BuildResultList(result, _session.DisplayType);
    }

    private Control BuildResultList(SearchResult result, SearchType type)
    {
        switch (type)
        {
            case SearchType.Song:
            {
                var list = new SongListView();
                list.SetSongs(result.Songs);
                HookScrollLoadMore(list);
                return list;
            }
            case SearchType.Artist:
            {
                var wrap = new WrapPanel
                {
                    Orientation = Orientation.Horizontal,
                    Margin = new Thickness(CTSpacing.Lg, CTSpacing.Md, CTSpacing.Lg, CTSpacing.Xl),
                };
                foreach (var artist in result.Artists)
                {
                    var card = UIComponents.ArtistCard(artist, item => App.OpenArtist(item.Id));
                    card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
                    wrap.Children.Add(card);
                }
                var scroll = new ScrollViewer
                {
                    Content = wrap,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                };
                HookScrollLoadMore(scroll);
                return scroll;
            }
            case SearchType.Album:
            {
                var wrap = new WrapPanel
                {
                    Orientation = Orientation.Horizontal,
                    Margin = new Thickness(CTSpacing.Lg, CTSpacing.Md, CTSpacing.Lg, CTSpacing.Xl),
                };
                foreach (var album in result.Albums)
                {
                    var card = UIComponents.AlbumCard(album, item => App.OpenAlbum(item.Id));
                    card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
                    wrap.Children.Add(card);
                }
                var scroll = new ScrollViewer
                {
                    Content = wrap,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                };
                HookScrollLoadMore(scroll);
                return scroll;
            }
            default:
            {
                var wrap = new WrapPanel
                {
                    Orientation = Orientation.Horizontal,
                    Margin = new Thickness(CTSpacing.Lg, CTSpacing.Md, CTSpacing.Lg, CTSpacing.Xl),
                };
                foreach (var playlist in result.Playlists)
                {
                    var card = UIComponents.PlaylistCard(playlist, item => App.OpenPlaylist(item.Id));
                    card.Margin = new Thickness(0, 0, CTSpacing.Lg, CTSpacing.Lg);
                    wrap.Children.Add(card);
                }
                var scroll = new ScrollViewer
                {
                    Content = wrap,
                    HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                };
                HookScrollLoadMore(scroll);
                return scroll;
            }
        }
    }

    private void HookScrollLoadMore(Control root)
    {
        if (_hookedScroll is not null)
        {
            _hookedScroll.ScrollChanged -= OnResultScrollChanged;
            _hookedScroll = null;
        }
        Dispatcher.UIThread.Post(() =>
        {
            var scroll = root.GetVisualDescendants().OfType<ScrollViewer>().FirstOrDefault();
            if (scroll is null) return;
            _hookedScroll = scroll;
            scroll.ScrollChanged += OnResultScrollChanged;
        }, DispatcherPriority.Loaded);
    }

    private void OnResultScrollChanged(object? sender, ScrollChangedEventArgs e)
    {
        if (sender is not ScrollViewer scroll) return;
        if (scroll.Extent.Height <= 0 || scroll.Viewport.Height <= 0) return;
        if (scroll.Offset.Y + scroll.Viewport.Height < scroll.Extent.Height - 64) return;
        if (_session.IsLoading || _session.IsLoadingMore) return;
        if (_session.Result?.HasMore != true) return;
        _pendingScrollToEnd = true;
        _session.LoadMore();
    }

    private void ScrollToEndAfterRebuild()
    {
        if (!_pendingScrollToEnd) return;
        _pendingScrollToEnd = false;
        Dispatcher.UIThread.Post(() =>
        {
            if (_hookedScroll is null) return;
            _hookedScroll.Offset = new Vector(
                _hookedScroll.Offset.X,
                Math.Max(0, _hookedScroll.Extent.Height - _hookedScroll.Viewport.Height));
        }, DispatcherPriority.Background);
    }

    private Control BuildFooter()
    {
        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = CTSpacing.Sm,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, CTSpacing.Sm, 0, CTSpacing.Md),
        };
        if (_session.IsLoadingMore)
        {
            panel.Children.Add(new ProgressBar
            {
                IsIndeterminate = true,
                Width = 120,
                Height = 4,
                VerticalAlignment = VerticalAlignment.Center,
            });
            panel.Children.Add(new TextBlock
            {
                Text = "加载中…",
                Classes = { "secondary" },
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        else if (_session.PaginationError is { } error)
        {
            panel.Children.Add(new TextBlock
            {
                Text = error,
                Classes = { "secondary" },
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 360,
                VerticalAlignment = VerticalAlignment.Center,
            });
            panel.Children.Add(UIComponents.LinkButton(L10n.Common.Retry, () => _session.LoadMore()));
        }
        else if (_session.Result?.HasMore == true)
        {
            var button = new Button { Content = "加载更多" };
            button.Click += (_, _) =>
            {
                _pendingScrollToEnd = true;
                _session.LoadMore();
            };
            panel.Children.Add(button);
        }
        return panel;
    }

    private static Border Divider() => new()
    {
        Height = 1,
        Background = CTColors.OverlayBrush,
        Margin = new Thickness(CTSpacing.Lg, CTSpacing.Sm),
    };

    private static Control SectionMessage(string text) => new TextBlock
    {
        Text = text,
        Classes = { "caption" },
        Foreground = CTColors.TextSecondaryBrush,
        Margin = new Thickness(CTSpacing.Lg, CTSpacing.Sm, CTSpacing.Lg, CTSpacing.Md),
    };

    private static string KindGlyph(SearchSuggestion.Kind kind) => kind switch
    {
        SearchSuggestion.Kind.Song => "\uE8D6",
        SearchSuggestion.Kind.Artist => "\uE77B",
        SearchSuggestion.Kind.Album => "\uE8B9",
        _ => "\uE8A5",
    };

    private static string KindLabel(SearchSuggestion.Kind kind) => kind switch
    {
        SearchSuggestion.Kind.Song => "单曲",
        SearchSuggestion.Kind.Artist => "歌手",
        SearchSuggestion.Kind.Album => "专辑",
        _ => "歌单",
    };

    private static void Post(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }
}
