using ClearTone.Core.Models;
using ClearTone.Core.Search;
using Xunit;

namespace ClearTone.Tests;

public class SearchSessionPaginationTests
{
    [Fact]
    public async Task TestAllFourTypesPaginate()
    {
        foreach (var type in new[] { SearchType.Song, SearchType.Artist, SearchType.Album, SearchType.Playlist })
        {
            var provider = new StubMusicProvider { SearchTotalPages = 3 };
            var session = new SearchSession(provider);

            session.DraftQuery = "周杰伦";
            session.Submit(type);
            await TestPolling.UntilAsync(() => !session.IsLoading, $"{type} 首搜未完成");
            Assert.Single(provider.SearchCalls);

            session.LoadMore();
            await TestPolling.UntilAsync(
                () => session.Result is { } result && CountFor(result, type) == 2,
                $"{type} 没有请求第 2 页");
            Assert.Equal(2, provider.SearchCalls.Count);
        }
    }

    private static int CountFor(SearchResult result, SearchType type) => type switch
    {
        SearchType.Song => result.Songs.Count,
        SearchType.Artist => result.Artists.Count,
        SearchType.Album => result.Albums.Count,
        _ => result.Playlists.Count,
    };

    [Fact]
    public async Task TestNonSongTypesWereTheRegression()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 3 };
        var session = new SearchSession(provider);

        session.DraftQuery = "test";
        session.Submit(SearchType.Album);
        await TestPolling.UntilAsync(() => !session.IsLoading, "首搜未完成");

        session.LoadMore();
        await TestPolling.UntilAsync(() => session.Result?.Albums.Count == 2, "专辑第 2 页未追加");

        Assert.Equal(new[] { "test-p1", "test-p2" }, session.Result!.Albums.Select(album => album.Id));
        Assert.Empty(session.Result.Songs);
        Assert.Empty(session.Result.Artists);
        Assert.Empty(session.Result.Playlists);
    }

    [Fact]
    public async Task TestNoPaginationWhenHasMoreIsFalse()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 1 };
        var session = new SearchSession(provider);

        session.DraftQuery = "test";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => !session.IsLoading, "首搜未完成");

        Assert.False(session.Result?.HasMore ?? true);
        session.LoadMore();
        await Task.Delay(50);
        Assert.Single(provider.SearchCalls);
    }

    [Fact]
    public async Task TestPaginationUsesCommittedQueryNotDraft()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 3 };
        var session = new SearchSession(provider);

        session.DraftQuery = "原始词";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => !session.IsLoading, "首搜未完成");

        session.DraftQuery = "改过的词";
        session.LoadMore();
        await TestPolling.UntilAsync(() => provider.SearchCalls.Count == 2, "分页未发出");

        Assert.Equal("原始词", provider.SearchCalls[1].Query);
        Assert.Equal("原始词", session.ActiveQuery);
        Assert.Equal(2, session.Result!.Songs.Count);
    }

    [Fact]
    public async Task TestPaginationLockDropsConcurrentSecondCall()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 5 };
        var session = new SearchSession(provider);

        session.DraftQuery = "test";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => !session.IsLoading, "首搜未完成");

        session.LoadMore();
        session.LoadMore();
        await Task.Delay(120);

        Assert.Equal(2, provider.SearchCalls.Count);
        Assert.Equal(new[] { 1, 2 }, provider.SearchCalls.Select(call => call.Page));
        Assert.Equal(2, session.Result!.Songs.Count);

        session.LoadMore();
        await TestPolling.UntilAsync(() => session.Result?.Songs.Count == 3, "第 3 页未追加");
        Assert.Equal(new[] { 1, 2, 3 }, provider.SearchCalls.Select(call => call.Page).OrderBy(page => page));
    }

    [Fact]
    public void TestIsEmptyRequiresAllFourEmpty()
    {
        var result = new SearchResult();
        Assert.True(result.IsEmpty);

        result.Albums = new List<Album> { new() { Id = "1", Name = "A" } };
        Assert.False(result.IsEmpty);

        result = new SearchResult();
        result.Artists = new List<Artist> { new() { Id = "1", Name = "A" } };
        Assert.False(result.IsEmpty);

        result = new SearchResult();
        result.Playlists = new List<Playlist> { new() { Id = "1", Name = "P", Source = SongSource.Netease } };
        Assert.False(result.IsEmpty);

        result = new SearchResult();
        result.Songs = new List<Song> { new() { Id = "1", Title = "S", Source = SongSource.Netease } };
        Assert.False(result.IsEmpty);
    }

    [Fact]
    public async Task TestResetClearsResultAndBlocksPagination()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 5 };
        var session = new SearchSession(provider);

        session.DraftQuery = "test";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");

        session.Reset();
        Assert.Null(session.Result);
        Assert.Equal("", session.DraftQuery);
        Assert.False(session.HasActiveQuery);

        session.LoadMore();
        await Task.Delay(50);
        Assert.Single(provider.SearchCalls);
    }

    [Fact]
    public async Task TestNewSearchInvalidatesPreviousResult()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 3 };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");

        session.DraftQuery = "B";
        session.Submit(SearchType.Artist);
        await TestPolling.UntilAsync(() => session.Result?.Artists.Count == 1, "新搜索未生效");

        Assert.Equal("B", session.ActiveQuery);
        Assert.Equal(SearchType.Artist, session.DisplayType);
        Assert.Empty(session.Result!.Songs);
        Assert.Single(session.Result.Artists);
    }

    [Fact]
    public async Task TestDisplayTypeFollowsCommittedQuery()
    {
        var provider = new StubMusicProvider { SearchTotalPages = 1 };
        var session = new SearchSession(provider);
        Assert.Equal(SearchType.Song, session.DisplayType);

        session.DraftQuery = "test";
        session.Submit(SearchType.Album);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");
        Assert.Equal(SearchType.Album, session.DisplayType);

        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.DisplayType == SearchType.Song, "displayType 未跟随");
        Assert.Equal(SearchType.Song, session.DisplayType);
    }

    [Fact]
    public async Task TestCancelInFlightRollsBackInFlightPage()
    {
        var hangPage2 = 1;
        var provider = new StubMusicProvider { SearchTotalPages = 5 };
        provider.SearchHandler = async (query, type, page, limit, ct) =>
        {
            if (page == 2 && Volatile.Read(ref hangPage2) == 1)
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, ct);
            }
            return StubMusicProvider.Page(query, type, page, page < 5);
        };
        var session = new SearchSession(provider);

        session.DraftQuery = "test";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => !session.IsLoading, "首搜未完成");
        Assert.Equal(1, session.CurrentPage);

        session.LoadMore();
        Assert.True(session.IsLoadingMore);
        Assert.Equal(2, session.CurrentPage);
        await Task.Delay(30);

        session.CancelInFlight();

        Assert.False(session.IsLoadingMore);
        Assert.Equal(1, session.CurrentPage);

        Volatile.Write(ref hangPage2, 0);
        session.LoadMore();
        await TestPolling.UntilAsync(() => provider.SearchCalls.Count >= 3, "取消后再次翻页未发出");
        Assert.Equal(2, provider.SearchCalls[^1].Page);
    }

    [Fact]
    public async Task TestPaginationFailureKeepsResultAndSurfacesError()
    {
        var failPage2 = 1;
        var provider = new StubMusicProvider { SearchTotalPages = 5 };
        provider.SearchHandler = (query, type, page, limit, ct) =>
        {
            if (page == 2 && Volatile.Read(ref failPage2) == 1)
            {
                return Task.FromException<SearchResult>(MusicException.NetworkUnavailable());
            }
            return Task.FromResult(StubMusicProvider.Page(query, type, page, page < 5));
        };
        var session = new SearchSession(provider);

        session.DraftQuery = "test";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => !session.IsLoading, "首搜未完成");
        var before = session.Result!.Songs.Count;

        session.LoadMore();
        await TestPolling.UntilAsync(() => session.PaginationError is not null, "分页错误未暴露");

        Assert.Null(session.ErrorMessage);
        Assert.NotNull(session.Result);
        Assert.Equal(before, session.Result!.Songs.Count);
        Assert.Equal(1, session.CurrentPage);
        Assert.False(session.IsLoadingMore);

        Volatile.Write(ref failPage2, 0);
        session.LoadMore();
        await TestPolling.UntilAsync(() => session.Result?.Songs.Count == before + 1, "重试未成功");
        Assert.Null(session.PaginationError);
    }

    [Fact]
    public async Task TestFailedNewSearchDoesNotLeaveStaleResult()
    {
        var failB = 1;
        var provider = new StubMusicProvider { SearchTotalPages = 3 };
        provider.SearchHandler = (query, type, page, limit, ct) =>
        {
            if (query == "B" && Volatile.Read(ref failB) == 1)
            {
                return Task.FromException<SearchResult>(MusicException.NetworkUnavailable());
            }
            return Task.FromResult(StubMusicProvider.Page(query, type, page, page < 3));
        };
        var session = new SearchSession(provider);

        session.DraftQuery = "A";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(() => session.Result is not null, "首搜未完成");
        var callsAfterA = provider.SearchCalls.Count;

        session.DraftQuery = "B";
        session.Submit(SearchType.Song);
        await TestPolling.UntilAsync(
            () => !session.IsLoading && session.ErrorMessage is not null,
            "失败查询未结束");

        Assert.Null(session.Result);
        Assert.Equal(callsAfterA + 1, provider.SearchCalls.Count);

        session.LoadMore();
        await Task.Delay(50);
        Assert.Equal(callsAfterA + 1, provider.SearchCalls.Count);
    }
}
