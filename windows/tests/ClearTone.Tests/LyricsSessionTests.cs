using ClearTone.Core.Lyrics;
using ClearTone.Core.Models;
using Xunit;

namespace ClearTone.Tests;

public class LyricsSessionTests
{
    private static Song MakeSong(string id) => new()
    {
        Id = id,
        Title = $"歌-{id}",
        Artists = { new Artist { Id = "a1", Name = "人" } },
        Source = SongSource.Netease,
    };

    private static LyricLine Line(double time, string text) => new() { Time = time, Text = text };

    private static LyricResult Result(params string[] texts) => new()
    {
        Lines = texts.Select((text, index) => Line(index, text)).ToList(),
    };

    private static LyricsSession MakeSession(StubMusicProvider provider) => new(_ => provider);

    [Fact]
    public async Task TestLoadPopulatesLinesAndFlags()
    {
        var provider = new StubMusicProvider();
        provider.LyricsHandler = (songID, ct) => Task.FromResult(new LyricResult
        {
            Lines = { Line(0, "第一行"), Line(3, "第二行") },
            HasWordTiming = true,
            IsPureMusic = false,
        });
        var session = MakeSession(provider);

        await session.LoadAsync(MakeSong("1"));

        Assert.Equal(new[] { "第一行", "第二行" }, session.Lines.Select(line => line.Text));
        Assert.True(session.HasWordTiming);
        Assert.False(session.IsPureMusic);
        Assert.Null(session.ErrorMessage);
        Assert.False(session.IsLoading);
    }

    [Fact]
    public async Task TestPureMusicFlagIsSurfaced()
    {
        var provider = new StubMusicProvider();
        provider.LyricsHandler = (songID, ct) => Task.FromResult(new LyricResult
        {
            HasWordTiming = false,
            IsPureMusic = true,
        });
        var session = MakeSession(provider);

        await session.LoadAsync(MakeSong("1"));

        Assert.True(session.IsPureMusic);
        Assert.Empty(session.Lines);
    }

    [Fact]
    public async Task TestNilSongClearsWithoutRequest()
    {
        var provider = new StubMusicProvider();
        provider.LyricsHandler = (songID, ct) => Task.FromResult(Result("旧词"));
        var session = MakeSession(provider);
        await session.LoadAsync(MakeSong("1"));
        Assert.False(session.Lines.Count == 0);

        await session.LoadAsync(null);

        Assert.Empty(session.Lines);
        Assert.False(session.IsLoading);
        Assert.Single(provider.LyricRequests);
    }

    [Fact]
    public async Task TestUnresolvableSongIsSkipped()
    {
        var provider = new StubMusicProvider();
        var session = new LyricsSession(_ => null);

        await session.LoadAsync(MakeSong("1"));

        Assert.Empty(session.Lines);
        Assert.False(session.IsLoading);
        Assert.Empty(provider.LyricRequests);
    }

    [Fact]
    public async Task TestFailureSurfacesErrorAndKeepsLinesEmpty()
    {
        var provider = new StubMusicProvider();
        provider.LyricsHandler = (songID, ct) =>
            Task.FromException<LyricResult>(MusicException.NetworkUnavailable());
        var session = MakeSession(provider);

        await session.LoadAsync(MakeSong("1"));

        Assert.NotNull(session.ErrorMessage);
        Assert.Empty(session.Lines);
        Assert.False(session.IsLoading);
    }

    [Fact]
    public async Task TestSwitchingSongClearsLinesBeforeResponse()
    {
        var provider = new StubMusicProvider();
        provider.LyricsHandler = (songID, ct) => Task.FromResult(Result("A 的词"));
        var session = MakeSession(provider);
        await session.LoadAsync(MakeSong("A"));
        Assert.Equal(new[] { "A 的词" }, session.Lines.Select(line => line.Text));

        var gate = new TestGate();
        provider.LyricsHandler = async (songID, ct) =>
        {
            await gate.WaitAsync();
            return Result("B 的词");
        };
        var task = session.LoadAsync(MakeSong("B"));

        Assert.Empty(session.Lines);
        Assert.True(session.IsLoading);

        gate.Open();
        await task;
        Assert.Equal(new[] { "B 的词" }, session.Lines.Select(line => line.Text));
    }

    [Fact]
    public async Task TestLateResponseFromPreviousSongIsDiscarded()
    {
        var gateA = new TestGate();
        var gateB = new TestGate();
        var provider = new StubMusicProvider();
        provider.LyricsHandler = async (songID, ct) =>
        {
            if (songID == "A")
            {
                await gateA.WaitAsync();
                return Result("A 的词");
            }
            await gateB.WaitAsync();
            return Result("B 的词");
        };
        var session = MakeSession(provider);

        var first = session.LoadAsync(MakeSong("A"));
        await TestPolling.UntilAsync(() => provider.LyricRequests.Count == 1, "A 的请求未发出");
        var second = session.LoadAsync(MakeSong("B"));
        await TestPolling.UntilAsync(() => provider.LyricRequests.Count == 2, "B 的请求未发出");

        gateA.Open();
        await first;
        Assert.Empty(session.Lines);

        gateB.Open();
        await second;
        Assert.Equal(new[] { "B 的词" }, session.Lines.Select(line => line.Text));
    }

    [Fact]
    public async Task TestCancelledLoadResetsLoading()
    {
        var provider = new StubMusicProvider();
        provider.LyricsHandler = async (songID, ct) =>
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, ct);
            return new LyricResult();
        };
        var session = MakeSession(provider);

        using var cts = new CancellationTokenSource();
        var task = session.LoadAsync(MakeSong("1"), cts.Token);
        Assert.True(session.IsLoading);

        cts.Cancel();
        await task;

        Assert.False(session.IsLoading);
        Assert.Null(session.ErrorMessage);
    }

    [Fact]
    public async Task TestResetClearsEverythingSynchronously()
    {
        var provider = new StubMusicProvider();
        provider.LyricsHandler = (songID, ct) => Task.FromResult(new LyricResult
        {
            Lines = { Line(0, "A 的词") },
            HasWordTiming = true,
            IsPureMusic = true,
        });
        var session = MakeSession(provider);
        await session.LoadAsync(MakeSong("A"));
        Assert.NotEmpty(session.Lines);
        Assert.True(session.IsPureMusic);
        Assert.True(session.HasWordTiming);

        session.Reset();

        Assert.Empty(session.Lines);
        Assert.False(session.IsPureMusic);
        Assert.False(session.HasWordTiming);
        Assert.False(session.IsLoading);
        Assert.Null(session.ErrorMessage);
    }

    [Fact]
    public async Task TestAlreadyCancelledLoadDoesNotClearState()
    {
        var provider = new StubMusicProvider();
        provider.LyricsHandler = (songID, ct) => Task.FromResult(Result("A 的词"));
        var session = MakeSession(provider);
        await session.LoadAsync(MakeSong("A"));
        Assert.Equal(new[] { "A 的词" }, session.Lines.Select(line => line.Text));

        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await session.LoadAsync(MakeSong("B"), cts.Token);

        Assert.Equal(new[] { "A 的词" }, session.Lines.Select(line => line.Text));
        Assert.Single(provider.LyricRequests);
    }
}
