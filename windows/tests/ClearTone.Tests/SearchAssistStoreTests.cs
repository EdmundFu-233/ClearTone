using ClearTone.Core.Models;
using ClearTone.Core.Search;
using Xunit;

namespace ClearTone.Tests;

public class SearchAssistStoreTests
{
    private static SearchAssistStore MakeStore(
        StubSocialProvider? source = null,
        InMemorySearchAssistPersistence? persistence = null) =>
        new(persistence ?? new InMemorySearchAssistPersistence(), source ?? new StubSocialProvider());

    [Fact]
    public void TestEmptyKeywordClearsSuggestions()
    {
        var store = MakeStore();

        store.QuerySuggestions("");
        Assert.Empty(store.Suggestions);
        Assert.False(store.IsLoadingSuggestions);

        store.QuerySuggestions("   ");
        Assert.Empty(store.Suggestions);
    }

    [Fact]
    public async Task TestSuggestionsAreDebounced()
    {
        var source = new StubSocialProvider();
        source.SearchSuggestionsHandler = (keyword, ct) => Task.FromResult(new List<SearchSuggestion>
        {
            new() { SuggestionKind = SearchSuggestion.Kind.Song, Title = "周杰伦", TargetID = "1" },
        });
        var store = MakeStore(source);

        foreach (var partial in new[] { "周", "周杰", "周杰伦", "周杰伦的" })
        {
            store.QuerySuggestions(partial);
        }

        Assert.Empty(source.SuggestionCalls);
        Assert.Empty(store.Suggestions);

        await Task.Delay(600);

        Assert.Equal(new[] { "周杰伦的" }, source.SuggestionCalls);
        Assert.Single(store.Suggestions);
        Assert.False(store.IsLoadingSuggestions);
    }

    [Fact]
    public async Task TestSuggestionFailureIsSilent()
    {
        var source = new StubSocialProvider();
        source.SearchSuggestionsHandler = (keyword, ct) =>
            Task.FromException<List<SearchSuggestion>>(MusicException.NetworkUnavailable());
        var store = MakeStore(source);

        store.QuerySuggestions("test");
        await Task.Delay(600);

        Assert.Empty(store.Suggestions);
        Assert.False(store.IsLoadingSuggestions);
    }

    [Fact]
    public async Task TestHotTermsAreCachedInStore()
    {
        var source = new StubSocialProvider();
        source.HotSearchTermsHandler = ct => Task.FromResult(new List<HotSearchTerm>
        {
            new() { Keyword = "周杰伦", Score = 100 },
        });
        var store = MakeStore(source);

        await store.LoadHotTermsAsync();
        await store.LoadHotTermsAsync();

        Assert.Equal(1, source.HotCallCount);
        Assert.Single(store.HotTerms);
    }

    [Fact]
    public async Task TestClearSuggestionsResetsState()
    {
        var source = new StubSocialProvider();
        source.SearchSuggestionsHandler = (keyword, ct) => Task.FromResult(new List<SearchSuggestion>
        {
            new() { Title = keyword, TargetID = "1" },
        });
        var store = MakeStore(source);

        store.QuerySuggestions("test");
        store.ClearSuggestions();
        Assert.Empty(store.Suggestions);

        await Task.Delay(600);
        Assert.Empty(store.Suggestions);
    }

    [Fact]
    public void TestRecordSearchPrependsAndDeduplicates()
    {
        var store = MakeStore();

        store.RecordSearch("周杰伦");
        store.RecordSearch("林俊杰");
        Assert.Equal(new[] { "林俊杰", "周杰伦" }, store.History);

        store.RecordSearch("周杰伦");
        Assert.Equal(new[] { "周杰伦", "林俊杰" }, store.History);
    }

    [Fact]
    public void TestRecordSearchIsCaseInsensitive()
    {
        var store = MakeStore();

        store.RecordSearch("Adele");
        store.RecordSearch("adele");

        Assert.Single(store.History);
        Assert.Equal("adele", store.History[0]);
    }

    [Fact]
    public void TestBlankSearchIsNotRecorded()
    {
        var store = MakeStore();

        store.RecordSearch("");
        store.RecordSearch("   \n ");

        Assert.Empty(store.History);
    }

    [Fact]
    public void TestHistoryIsCapped()
    {
        var store = MakeStore();

        for (var index = 0; index < 40; index++)
        {
            store.RecordSearch($"词{index}");
        }

        Assert.Equal(20, store.History.Count);
        Assert.Equal("词39", store.History[0]);
    }

    [Fact]
    public void TestRemoveAndClearHistory()
    {
        var store = MakeStore();

        store.RecordSearch("A");
        store.RecordSearch("B");
        store.RemoveHistory("A");
        Assert.Equal(new[] { "B" }, store.History);

        store.ClearHistory();
        Assert.Empty(store.History);
    }

    [Fact]
    public void TestHistoryPersists()
    {
        var persistence = new InMemorySearchAssistPersistence();
        var store = MakeStore(persistence: persistence);
        store.RecordSearch("持久化测试");

        var reloaded = MakeStore(persistence: persistence);

        Assert.Equal(new[] { "持久化测试" }, reloaded.History);
    }

    [Fact]
    public async Task TestCancelledHotTermsLoadDoesNotStickSpinner()
    {
        var source = new StubSocialProvider();
        source.HotSearchTermsHandler = ct =>
        {
            ct.ThrowIfCancellationRequested();
            return Task.FromResult(new List<HotSearchTerm> { new() { Keyword = "周杰伦", Score = 100 } });
        };
        var store = MakeStore(source);

        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await store.LoadHotTermsAsync(cts.Token);

        Assert.False(store.IsLoadingHot);

        await store.LoadHotTermsAsync();
        Assert.Equal(2, source.HotCallCount);
        Assert.Single(store.HotTerms);
    }

    [Fact]
    public async Task TestHotTermsFailureIsSurfacedAndRetryable()
    {
        var failing = true;
        var source = new StubSocialProvider();
        source.HotSearchTermsHandler = ct => failing
            ? Task.FromException<List<HotSearchTerm>>(MusicException.NetworkUnavailable())
            : Task.FromResult(new List<HotSearchTerm> { new() { Keyword = "重试", Score = 1 } });
        var store = MakeStore(source);

        await store.LoadHotTermsAsync();
        Assert.NotNull(store.HotError);
        Assert.False(store.IsLoadingHot);

        failing = false;
        await store.LoadHotTermsAsync();
        Assert.Null(store.HotError);
        Assert.Single(store.HotTerms);
    }

    [Fact]
    public void TestRemoveHistoryIsCaseInsensitive()
    {
        var store = MakeStore();

        store.RecordSearch("周杰伦");
        store.RemoveHistory("周杰伦");
        Assert.Empty(store.History);

        store.RecordSearch("Adele");
        store.RemoveHistory("adele");
        Assert.Empty(store.History);
    }

    [Fact]
    public void TestHistoryIsCappedOnLoad()
    {
        var persistence = new InMemorySearchAssistPersistence
        {
            StoredHistory = Enumerable.Range(0, 40).Select(index => $"旧词{index}").ToList(),
        };

        var store = MakeStore(persistence: persistence);

        Assert.Equal(20, store.History.Count);
        Assert.Equal("旧词0", store.History[0]);
        Assert.Equal("旧词19", store.History[19]);
    }
}
