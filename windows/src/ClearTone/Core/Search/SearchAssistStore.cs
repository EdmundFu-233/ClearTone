using ClearTone.Core.Models;
using ClearTone.Core.Persistence;
using ClearTone.Providers.Netease;
using CommunityToolkit.Mvvm.ComponentModel;

namespace ClearTone.Core.Search;

public interface ISearchAssistPersistence
{
    List<string> LoadHistory();
    void SaveHistory(List<string> history);
}

internal sealed class PersistenceStoreSearchAssistPersistence : ISearchAssistPersistence
{
    private const string HistoryKey = "searchAssistHistory";

    public List<string> LoadHistory() =>
        PersistenceStore.Shared.LoadSetting<List<string>>(HistoryKey) ?? new List<string>();

    public void SaveHistory(List<string> history) =>
        PersistenceStore.Shared.SaveSetting(history, HistoryKey);
}

public sealed class SearchAssistStore : ObservableObject
{
    private static readonly TimeSpan DebounceInterval = TimeSpan.FromMilliseconds(250);
    private const int HistoryLimit = 20;

    private readonly object _gate = new();
    private readonly IMusicSocialProvider _source;
    private readonly ISearchAssistPersistence _persistence;

    private List<SearchSuggestion> _suggestions = new();
    private bool _isLoadingSuggestions;
    private List<HotSearchTerm> _hotTerms = new();
    private bool _isLoadingHot;
    private string? _hotError;
    private List<string> _history = new();

    private int _suggestionToken;
    private CancellationTokenSource? _debounceCts;
    private CancellationTokenSource? _suggestionsCts;

    public SearchAssistStore(ISearchAssistPersistence? persistence = null, IMusicSocialProvider? source = null)
    {
        _persistence = persistence ?? new PersistenceStoreSearchAssistPersistence();
        _source = source ?? (IMusicSocialProvider)NeteaseProvider.Shared;
        var stored = _persistence.LoadHistory();
        _history = stored.Count > HistoryLimit ? stored.Take(HistoryLimit).ToList() : stored;
    }

    public IReadOnlyList<SearchSuggestion> Suggestions
    {
        get { lock (_gate) return _suggestions; }
    }

    public bool IsLoadingSuggestions
    {
        get { lock (_gate) return _isLoadingSuggestions; }
    }

    public IReadOnlyList<HotSearchTerm> HotTerms
    {
        get { lock (_gate) return _hotTerms; }
    }

    public bool IsLoadingHot
    {
        get { lock (_gate) return _isLoadingHot; }
    }

    public string? HotError
    {
        get { lock (_gate) return _hotError; }
    }

    public IReadOnlyList<string> History
    {
        get { lock (_gate) return _history; }
    }

    public void QuerySuggestions(string keyword)
    {
        int token;
        CancellationTokenSource cts;
        lock (_gate)
        {
            _debounceCts?.Cancel();
            _debounceCts = null;
            _suggestionsCts?.Cancel();
            _suggestionsCts = null;
            var trimmed = keyword.Trim();
            if (trimmed.Length == 0)
            {
                _suggestionToken++;
                _suggestions = new List<SearchSuggestion>();
                _isLoadingSuggestions = false;
                OnPropertyChanged(nameof(Suggestions));
                OnPropertyChanged(nameof(IsLoadingSuggestions));
                return;
            }
            token = ++_suggestionToken;
            cts = new CancellationTokenSource();
            _debounceCts = cts;
        }
        _ = DebouncedFetchAsync(keyword.Trim(), token, cts);
    }

    private async Task DebouncedFetchAsync(string keyword, int token, CancellationTokenSource cts)
    {
        try
        {
            await Task.Delay(DebounceInterval, cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (cts.Token.IsCancellationRequested) return;
        await FetchSuggestionsAsync(keyword, token, cts).ConfigureAwait(false);
    }

    private async Task FetchSuggestionsAsync(string keyword, int token, CancellationTokenSource cts)
    {
        lock (_gate)
        {
            if (token != _suggestionToken) return;
            _suggestionsCts = cts;
            _isLoadingSuggestions = true;
            OnPropertyChanged(nameof(IsLoadingSuggestions));
        }
        try
        {
            var loaded = await _source.FetchSearchSuggestionsAsync(keyword, cts.Token).ConfigureAwait(false);
            lock (_gate)
            {
                if (token != _suggestionToken || cts.Token.IsCancellationRequested) return;
                _suggestions = loaded;
                OnPropertyChanged(nameof(Suggestions));
            }
        }
        catch (Exception)
        {
            lock (_gate)
            {
                if (token != _suggestionToken) return;
                _suggestions = new List<SearchSuggestion>();
                OnPropertyChanged(nameof(Suggestions));
            }
        }
        finally
        {
            lock (_gate)
            {
                if (ReferenceEquals(_suggestionsCts, cts)) _suggestionsCts = null;
                if (token == _suggestionToken)
                {
                    _isLoadingSuggestions = false;
                    OnPropertyChanged(nameof(IsLoadingSuggestions));
                }
            }
        }
    }

    public void ClearSuggestions()
    {
        lock (_gate)
        {
            _debounceCts?.Cancel();
            _debounceCts = null;
            _suggestionsCts?.Cancel();
            _suggestionsCts = null;
            _suggestionToken++;
            _suggestions = new List<SearchSuggestion>();
            _isLoadingSuggestions = false;
            OnPropertyChanged(nameof(Suggestions));
            OnPropertyChanged(nameof(IsLoadingSuggestions));
        }
    }

    public async Task LoadHotTermsAsync(CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_hotTerms.Count > 0 || _isLoadingHot) return;
            _isLoadingHot = true;
            _hotError = null;
            OnPropertyChanged(nameof(IsLoadingHot));
            OnPropertyChanged(nameof(HotError));
        }
        try
        {
            var loaded = await _source.FetchHotSearchTermsAsync(ct).ConfigureAwait(false);
            lock (_gate)
            {
                if (ct.IsCancellationRequested) return;
                _hotTerms = loaded;
                OnPropertyChanged(nameof(HotTerms));
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (ct.IsCancellationRequested) return;
                _hotError = error.CtUserMessage();
                OnPropertyChanged(nameof(HotError));
            }
        }
        finally
        {
            lock (_gate)
            {
                _isLoadingHot = false;
                OnPropertyChanged(nameof(IsLoadingHot));
            }
        }
    }

    public void RecordSearch(string keyword)
    {
        var trimmed = keyword.Trim();
        if (trimmed.Length == 0) return;
        lock (_gate)
        {
            _history.RemoveAll(item => string.Equals(item, trimmed, StringComparison.OrdinalIgnoreCase));
            _history.Insert(0, trimmed);
            if (_history.Count > HistoryLimit)
            {
                _history = _history.Take(HistoryLimit).ToList();
            }
            OnPropertyChanged(nameof(History));
            _persistence.SaveHistory(new List<string>(_history));
        }
    }

    public void RemoveHistory(string keyword)
    {
        lock (_gate)
        {
            _history.RemoveAll(item => string.Equals(item, keyword, StringComparison.OrdinalIgnoreCase));
            OnPropertyChanged(nameof(History));
            _persistence.SaveHistory(new List<string>(_history));
        }
    }

    public void ClearHistory()
    {
        lock (_gate)
        {
            _history = new List<string>();
            OnPropertyChanged(nameof(History));
            _persistence.SaveHistory(new List<string>());
        }
    }
}
