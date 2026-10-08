using ClearTone.Core.Models;
using Xunit;
using ArtistSession = ClearTone.Core.Artist.ArtistProfileSession;
using ArtistModel = ClearTone.Core.Models.Artist;

namespace ClearTone.Tests;

public class ArtistProfileSessionTests
{
    private static Song MakeSong(string id) => new()
    {
        Id = id,
        Title = $"歌{id}",
        Artists = { new ArtistModel { Id = "1", Name = "测试歌手" } },
        Source = SongSource.Netease,
    };

    [Fact]
    public async Task TestSwitchToArtistClearsEverything()
    {
        var provider = new StubArtistProfileProvider();
        provider.EnqueueSongPage(new ArtistSongPage { Songs = { MakeSong("s1") }, Total = 1, HasMore = false });
        var session = new ArtistSession("1", provider);
        await session.LoadProfileAsync();
        await session.LoadSongsAsync();
        Assert.NotEmpty(session.Songs);

        session.SwitchTo("2");

        Assert.Equal("2", session.ArtistID);
        Assert.Null(session.Profile);
        Assert.Empty(session.Songs);
        Assert.Empty(session.Albums);
        Assert.Empty(session.MVs);
        Assert.Null(session.Intro);
        Assert.Empty(session.SimilarArtists);
    }

    [Fact]
    public async Task TestSwitchToSameArtistIsNoOpButDataContextReloadClears()
    {
        var session = new ArtistSession("1", new StubArtistProfileProvider());
        await session.LoadProfileAsync();
        Assert.NotNull(session.Profile);

        session.SwitchTo("1");
        Assert.NotNull(session.Profile);

        session.ReloadForDataContext();
        Assert.Null(session.Profile);
        Assert.Equal("1", session.ArtistID);
    }

    [Fact]
    public async Task TestSwitchToArtistDoesNotStartLoadingOnItsOwn()
    {
        var provider = new StubArtistProfileProvider();
        var session = new ArtistSession("1", provider);

        session.SwitchTo("2");
        Assert.Equal("2", session.ArtistID);
        Assert.Null(session.Profile);

        await session.LoadProfileAsync();
        Assert.NotNull(session.Profile);
    }

    [Fact]
    public async Task TestLoadMoreSongsAdvancesOffsetByLoadedCount()
    {
        var provider = new StubArtistProfileProvider();
        provider.EnqueueSongPage(new ArtistSongPage
        {
            Songs = { MakeSong("s0"), MakeSong("s1"), MakeSong("s2") },
            Total = 9,
            HasMore = true,
        });
        provider.EnqueueSongPage(new ArtistSongPage
        {
            Songs = { MakeSong("s3"), MakeSong("s4"), MakeSong("s5") },
            Total = 9,
            HasMore = false,
        });
        var session = new ArtistSession("1", provider);

        await session.LoadSongsAsync();
        Assert.Equal(new[] { 0 }, provider.RequestedSongOffsets);
        Assert.Equal(3, session.Songs.Count);
        Assert.Equal(9, session.SongsTotal);

        await session.LoadMoreSongsAsync();
        Assert.Equal(new[] { 0, 3 }, provider.RequestedSongOffsets);
        Assert.Equal(new[] { "s0", "s1", "s2", "s3", "s4", "s5" }, session.Songs.Select(song => song.Id));
    }

    [Fact]
    public async Task TestNoMorePagesStopsLoading()
    {
        var provider = new StubArtistProfileProvider();
        provider.EnqueueSongPage(new ArtistSongPage { Songs = { MakeSong("s0") }, Total = 1, HasMore = false });
        var session = new ArtistSession("1", provider);

        await session.LoadSongsAsync();
        Assert.False(session.CanLoadMoreSongs);

        await session.LoadMoreSongsAsync();
        Assert.Equal(new[] { 0 }, provider.RequestedSongOffsets);
    }

    [Fact]
    public async Task TestEmptyListDoesNotLoadMore()
    {
        var provider = new StubArtistProfileProvider();
        provider.EnqueueSongPage(new ArtistSongPage { HasMore = true });
        var session = new ArtistSession("1", provider);

        await session.LoadSongsAsync();
        Assert.False(session.CanLoadMoreSongs);

        await session.LoadMoreSongsAsync();
        Assert.Equal(new[] { 0 }, provider.RequestedSongOffsets);
    }

    [Fact]
    public async Task TestLoadMoreFailureKeepsExistingSongs()
    {
        var provider = new StubArtistProfileProvider();
        provider.EnqueueSongPage(new ArtistSongPage { Songs = { MakeSong("s0") }, Total = 99, HasMore = true });
        var session = new ArtistSession("1", provider);
        await session.LoadSongsAsync();

        provider.FailNextSongPage = true;
        await session.LoadMoreSongsAsync();

        Assert.Equal(new[] { "s0" }, session.Songs.Select(song => song.Id));
        Assert.NotNull(session.SongsError);
        Assert.True(session.CanLoadMoreSongs);
    }

    [Fact]
    public async Task TestSuccessfulPaginationRetryClearsSongsError()
    {
        var provider = new StubArtistProfileProvider();
        provider.EnqueueSongPage(new ArtistSongPage { Songs = { MakeSong("s0") }, Total = 9, HasMore = true });
        provider.EnqueueSongPage(new ArtistSongPage { Songs = { MakeSong("s1") }, Total = 9, HasMore = false });
        var session = new ArtistSession("1", provider);
        await session.LoadSongsAsync();

        provider.FailNextSongPage = true;
        await session.LoadMoreSongsAsync();
        Assert.NotNull(session.SongsError);

        await session.LoadMoreSongsAsync();
        Assert.Null(session.SongsError);
        Assert.Equal(new[] { "s0", "s1" }, session.Songs.Select(song => song.Id));
    }

    [Fact]
    public async Task TestFirstPageFailureSetsError()
    {
        var provider = new StubArtistProfileProvider { FailProfile = true };
        var session = new ArtistSession("1", provider);

        await session.LoadProfileAsync();

        Assert.NotNull(session.ProfileError);
        Assert.Null(session.Profile);
    }

    [Fact]
    public async Task TestDuplicateSongsAcrossPagesAreDeduplicated()
    {
        var provider = new StubArtistProfileProvider();
        provider.EnqueueSongPage(new ArtistSongPage
        {
            Songs = { MakeSong("a"), MakeSong("b") },
            Total = 3,
            HasMore = true,
        });
        provider.EnqueueSongPage(new ArtistSongPage
        {
            Songs = { MakeSong("a"), MakeSong("c") },
            Total = 3,
            HasMore = false,
        });
        var session = new ArtistSession("1", provider);

        await session.LoadSongsAsync();
        await session.LoadMoreSongsAsync();

        Assert.Equal(new[] { "a", "b", "c" }, session.Songs.Select(song => song.Id));
    }

    [Fact]
    public async Task TestLateResponseFromPreviousArtistIsDiscarded()
    {
        var gate = new TestGate();
        var provider = new StubArtistProfileProvider { SongGate = gate };
        provider.EnqueueSongPage(new ArtistSongPage { Songs = { MakeSong("old") }, HasMore = false });
        var session = new ArtistSession("1", provider);

        var task = session.LoadSongsAsync();
        await TestPolling.UntilAsync(() => provider.RequestedSongOffsets.Count == 1, "歌曲请求未发出");

        session.SwitchTo("2");
        gate.Open();
        await task;

        Assert.Empty(session.Songs);
        Assert.Null(session.SongsError);
    }

    [Fact]
    public async Task TestLateAlbumPageFromPreviousArtistIsDiscarded()
    {
        var gate = new TestGate();
        var provider = new StubArtistProfileProvider { AlbumGate = gate };
        provider.EnqueueAlbumPage(new ArtistAlbumPage
        {
            Albums = { new Album { Id = "1", Name = "A" } },
            IsFollowed = true,
            HasMore = false,
        });
        var session = new ArtistSession("1", provider);

        var task = session.LoadAlbumsAsync();
        await TestPolling.UntilAsync(() => provider.RequestedAlbumOffsets.Count == 1, "专辑请求未发出");

        session.SwitchTo("2");
        gate.Open();
        await task;

        Assert.Empty(session.Albums);
        Assert.Null(session.IsFollowed);
    }

    [Fact]
    public async Task TestFollowedInitializesFromAlbumPage()
    {
        var provider = new StubArtistProfileProvider();
        provider.EnqueueAlbumPage(new ArtistAlbumPage
        {
            Albums = { new Album { Id = "1", Name = "A" } },
            IsFollowed = true,
            HasMore = false,
        });
        var session = new ArtistSession("1", provider);

        await session.LoadAlbumsAsync();

        Assert.True(session.IsFollowed);
    }

    [Fact]
    public async Task TestLaterPagesDoNotClearFollowedState()
    {
        var provider = new StubArtistProfileProvider();
        provider.EnqueueAlbumPage(new ArtistAlbumPage
        {
            Albums = { new Album { Id = "1", Name = "A" } },
            IsFollowed = true,
            HasMore = true,
        });
        provider.EnqueueAlbumPage(new ArtistAlbumPage
        {
            Albums = { new Album { Id = "2", Name = "B" } },
            IsFollowed = null,
            HasMore = false,
        });
        var session = new ArtistSession("1", provider);

        await session.LoadAlbumsAsync();
        await session.LoadMoreAlbumsAsync();

        Assert.True(session.IsFollowed);
    }

    [Fact]
    public void TestSetFollowedUpdatesLocalState()
    {
        var session = new ArtistSession("1", new StubArtistProfileProvider());

        session.SetFollowed(true);

        Assert.True(session.IsFollowed);
    }

    [Fact]
    public async Task TestSimilarArtistsExcludeSelf()
    {
        var provider = new StubArtistProfileProvider
        {
            SimilarArtists =
            {
                new ArtistModel { Id = "1", Name = "自己" },
                new ArtistModel { Id = "2", Name = "相似甲" },
                new ArtistModel { Id = "3", Name = "相似乙" },
            },
        };
        var session = new ArtistSession("1", provider);

        await session.LoadHighlightsAsync();

        Assert.Equal(new[] { "2", "3" }, session.SimilarArtists.Select(artist => artist.Id));
    }

    [Fact]
    public async Task TestHighlightsFailureIsSilent()
    {
        var provider = new StubArtistProfileProvider { FailHighlights = true };
        var session = new ArtistSession("1", provider);

        await session.LoadHighlightsAsync();

        Assert.Empty(session.HotSongs);
        Assert.Empty(session.SimilarArtists);
        Assert.False(session.IsLoadingHighlights);
        Assert.Null(session.ProfileError);
    }
}
