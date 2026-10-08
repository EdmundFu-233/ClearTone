using ClearTone.Core.Discover;
using ClearTone.Core.Models;
using Xunit;

namespace ClearTone.Tests;

public class TopListSessionTests
{
    private static TopList MakeList(string id, string name = "飙升榜") =>
        new() { Id = id, Name = name, TrackCount = 100 };

    [Fact]
    public async Task TestLoadPopulatesLists()
    {
        var source = new StubSocialProvider();
        source.TopListsHandler = ct => Task.FromResult(new List<TopList>
        {
            MakeList("19723756", "飙升榜"),
            MakeList("3779629"),
        });
        var session = new TopListSession(source);

        await session.LoadAsync();

        Assert.Equal(new[] { "19723756", "3779629" }, session.Lists.Select(list => list.Id));
        Assert.Null(session.ErrorMessage);
        Assert.False(session.IsLoading);
    }

    [Fact]
    public async Task TestFailureKeepsExistingListsAndSurfacesError()
    {
        var failing = false;
        var source = new StubSocialProvider();
        source.TopListsHandler = ct => failing
            ? Task.FromException<List<TopList>>(MusicException.NetworkUnavailable())
            : Task.FromResult(new List<TopList> { MakeList("1") });
        var session = new TopListSession(source);
        await session.LoadAsync();
        Assert.Single(session.Lists);

        failing = true;
        await session.LoadAsync();

        Assert.Equal(new[] { "1" }, session.Lists.Select(list => list.Id));
        Assert.NotNull(session.ErrorMessage);
        Assert.False(session.IsLoading);
    }

    [Fact]
    public async Task TestCancelledLoadResetsLoading()
    {
        var source = new StubSocialProvider();
        source.TopListsHandler = async ct =>
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, ct);
            return new List<TopList>();
        };
        var session = new TopListSession(source);

        using var cts = new CancellationTokenSource();
        var task = session.LoadAsync(cts.Token);
        Assert.True(session.IsLoading);

        cts.Cancel();
        await task;

        Assert.False(session.IsLoading);
    }

    [Fact]
    public async Task TestLateResponseFromOlderLoadIsDiscarded()
    {
        var gates = new List<TestGate> { new(), new() };
        var current = new List<TopList> { MakeList("old") };
        var calls = 0;
        var source = new StubSocialProvider();
        source.TopListsHandler = async ct =>
        {
            var index = Interlocked.Increment(ref calls) - 1;
            await gates[index].WaitAsync();
            return Volatile.Read(ref current);
        };
        var session = new TopListSession(source);

        var first = session.LoadAsync();
        await TestPolling.UntilAsync(() => source.TopListCallCount == 1, "第一次请求未发出");
        var second = session.LoadAsync();
        await TestPolling.UntilAsync(() => source.TopListCallCount == 2, "第二次请求未发出");

        Volatile.Write(ref current, new List<TopList> { MakeList("new") });
        gates[1].Open();
        await second;
        Assert.Equal(new[] { "new" }, session.Lists.Select(list => list.Id));

        Volatile.Write(ref current, new List<TopList> { MakeList("old") });
        gates[0].Open();
        await first;

        Assert.Equal(new[] { "new" }, session.Lists.Select(list => list.Id));
        Assert.False(session.IsLoading);
    }
}
