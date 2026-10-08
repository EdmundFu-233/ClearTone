using ClearTone.Core.Models;
using ClearTone.Core.Search;
using Xunit;

namespace ClearTone.Tests;

public class SearchSessionTests
{
    private static Song MakeSong(string id) => new()
    {
        Id = id,
        Title = $"歌-{id}",
        Artists = { new Artist { Id = "a1", Name = "Artist" } },
        Source = SongSource.Netease,
    };

    [Fact]
    public async Task TestPaginationUsesCommittedQueryNotDraft()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 2 };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");

        session.DraftQuery = "B";
        session.LoadMore();
        await TestPolling.UntilAsync(() => session.Result?.Songs.Count == 2, "分页结果没有追加进来");

        Assert.Equal(
            new[] { new SearchCall("A", SearchType.Song, 1), new SearchCall("A", SearchType.Song, 2) },
            provider.SearchCalls);
        Assert.Equal("A", session.ActiveQuery);
        Assert.Equal(new[] { "A-p1", "A-p2" }, session.Result!.Songs.Select(song => song.Id));
    }

    [Fact]
    public async Task TestPaginationUsesCommittedType()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 2 };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Album);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");

        session.LoadMore();
        await TestPolling.UntilAsync(() => provider.SearchCalls.Count == 2, "分页未发出");

        Assert.Equal(new[] { SearchType.Album, SearchType.Album }, provider.SearchCalls.Select(call => call.Type));
        Assert.Equal(SearchType.Album, session.DisplayType);
    }

    [Fact]
    public async Task TestDisplayTypeFollowsCommittedType()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 2 };
        var session = new SearchSession(provider);
        Assert.Equal(SearchType.Song, session.DisplayType);

        session.DraftQuery = "A";
        session.Submit(SearchType.Playlist);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");
        Assert.Equal(SearchType.Playlist, session.DisplayType);

        session.Reset();
        Assert.Equal(SearchType.Song, session.DisplayType);
    }

    [Fact]
    public async Task TestResetDiscardsInFlightSearch()
    {
        var gate = new TestGate();
        var provider = new StubMusicProvider();
        provider.SearchHandler = async (query, type, page, limit, ct) =>
        {
            await gate.WaitAsync();
            return StubMusicProvider.Page(query, type, page, false);
        };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Song);
        Assert.True(session.IsLoading);
        Assert.Null(session.Result);

        session.Reset();
        Assert.Null(session.Result);
        Assert.False(session.IsLoading);
        Assert.Equal("", session.DraftQuery);

        gate.Open();
        await Task.Delay(200);

        Assert.Null(session.Result);
        Assert.False(session.IsLoading);
        Assert.Null(session.ErrorMessage);
        Assert.Null(session.ActiveQuery);
    }

    [Fact]
    public async Task TestResetDiscardsInFlightPagination()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 3 };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");

        var gate = new TestGate();
        provider.SearchHandler = async (query, type, page, limit, ct) =>
        {
            await gate.WaitAsync();
            return StubMusicProvider.Page(query, type, page, false);
        };

        session.LoadMore();
        await Task.Delay(50);
        session.Reset();
        gate.Open();
        await Task.Delay(200);

        Assert.Null(session.Result);
        Assert.Equal(1, session.CurrentPage);
    }

    [Fact]
    public async Task TestLoadMoreIsNoopAfterReset()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 3 };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");
        var before = provider.SearchCalls.Count;

        session.Reset();
        session.LoadMore();
        await Task.Delay(100);

        Assert.Equal(before, provider.SearchCalls.Count);
    }

    [Fact]
    public async Task TestStaleSearchResponseIsDiscarded()
    {
        var gateA = new TestGate();
        var gateB = new TestGate();
        var provider = new StubMusicProvider();
        provider.SearchHandler = async (query, type, page, limit, ct) =>
        {
            if (query == "A") await gateA.WaitAsync();
            else await gateB.WaitAsync();
            return StubMusicProvider.Page(query, type, page, false);
        };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Song);
        session.DraftQuery = "B";
        session.Submit(SearchType.Song);

        gateB.Open();
        await TestPolling.UntilAsync(() => session.Result is not null, "后发搜索未完成");
        Assert.Equal(new[] { "B-p1" }, session.Result!.Songs.Select(song => song.Id));

        gateA.Open();
        await Task.Delay(200);

        Assert.Equal(new[] { "B-p1" }, session.Result!.Songs.Select(song => song.Id));
        Assert.Equal("B", session.ActiveQuery);
    }

    [Fact]
    public async Task TestCancelInFlightDiscardsUncommittedSearch()
    {
        var gate = new TestGate();
        var provider = new StubMusicProvider { SearchTotalPages = 2 };
        provider.SearchHandler = async (query, type, page, limit, ct) =>
        {
            if (query == "B") await gate.WaitAsync();
            return StubMusicProvider.Page(query, type, page, false);
        };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");

        session.DraftQuery = "B";
        session.Submit(SearchType.Song);
        Assert.True(session.IsLoading);

        session.CancelInFlight();
        Assert.False(session.IsLoading);
        Assert.Null(session.Result);
        Assert.Null(session.ActiveQuery);

        gate.Open();
        await Task.Delay(200);
        Assert.Null(session.Result);
    }

    [Fact]
    public async Task TestCancelInFlightKeepsSettledResult()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 2 };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");
        Assert.False(session.IsLoading);

        session.CancelInFlight();

        Assert.Equal(new[] { "A-p1" }, session.Result!.Songs.Select(song => song.Id));
        Assert.Equal("A", session.ActiveQuery);
        Assert.False(session.IsLoading);
    }

    [Fact]
    public async Task TestRetryRerunsCommittedQuery()
    {
        var remainingFailures = 1;
        var provider = new StubMusicProvider { SearchTotalPages = 2 };
        provider.SearchHandler = (query, type, page, limit, ct) =>
        {
            if (Interlocked.Exchange(ref remainingFailures, 0) == 1)
            {
                return Task.FromException<SearchResult>(MusicException.NetworkUnavailable());
            }
            return Task.FromResult(StubMusicProvider.Page(query, type, page, false));
        };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.ErrorMessage is not null, "失败未暴露");

        session.DraftQuery = "B";
        session.Retry(SearchType.Song);
        await TestPolling.UntilAsync(() => session.Result is not null, "重试未完成");

        Assert.Equal(
            new[] { new SearchCall("A", SearchType.Song, 1), new SearchCall("A", SearchType.Song, 1) },
            provider.SearchCalls);
    }

    [Fact]
    public async Task TestRefreshDataContextPrefersDraft()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 2 };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");

        session.DraftQuery = "B";
        session.RefreshDataContext(SearchType.Album);
        await TestPolling.UntilAsync(() => provider.SearchCalls.Count == 2, "重搜未发出");

        Assert.Equal(
            new[] { new SearchCall("A", SearchType.Song, 1), new SearchCall("B", SearchType.Album, 1) },
            provider.SearchCalls);
    }

    [Fact]
    public async Task TestRefreshDataContextFallsBackToCommittedQuery()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 2 };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");

        session.DraftQuery = "";
        session.RefreshDataContext(SearchType.Song);
        await TestPolling.UntilAsync(() => provider.SearchCalls.Count == 2, "重搜未发出");

        Assert.Equal(
            new[] { new SearchCall("A", SearchType.Song, 1), new SearchCall("A", SearchType.Song, 1) },
            provider.SearchCalls);
    }

    [Fact]
    public async Task TestRefreshDataContextWithoutResultsIsNoop()
    {
        var provider = new StubMusicProvider();
        var session = new SearchSession(provider);

        session.RefreshDataContext(SearchType.Song);
        await Task.Delay(100);

        Assert.Empty(provider.SearchCalls);
    }

    [Fact]
    public async Task TestSubmitIgnoresBlankDraft()
    {
        var provider = new StubMusicProvider();
        var session = new SearchSession(provider);

        session.DraftQuery = "   ";
        session.Submit(SearchType.Song);
        await Task.Delay(100);

        Assert.Empty(provider.SearchCalls);
        Assert.False(session.IsLoading);
        Assert.Null(session.Result);
    }

    [Fact]
    public async Task TestSubmitTrimsWhitespace()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 2 };
        var session = new SearchSession(provider);

        session.DraftQuery = "  周杰伦 ";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");

        Assert.Equal(new[] { new SearchCall("周杰伦", SearchType.Song, 1) }, provider.SearchCalls);
        Assert.Equal("周杰伦", session.ActiveQuery);
    }
}
