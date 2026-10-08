using ClearTone.Core.Models;

namespace ClearTone.Tests;

public sealed class StubArtistProfileProvider : IArtistProfileProvider
{
    private readonly object _gate = new();
    private readonly Queue<ArtistSongPage> _songPages = new();
    private readonly Queue<ArtistAlbumPage> _albumPages = new();
    private readonly Queue<ArtistMVPage> _mvPages = new();
    private readonly List<int> _songOffsets = new();
    private readonly List<int> _albumOffsets = new();
    private readonly List<int> _mvOffsets = new();

    public ArtistProfile Profile { get; set; } = new()
    {
        Artist = new Artist { Id = "1", Name = "测试歌手" },
        BriefDescription = "简介",
        AlbumCount = 2,
        SongCount = 10,
        MvCount = 1,
    };

    public ArtistIntro Intro { get; set; } = new();
    public List<Song> HotSongs { get; set; } = new();
    public List<Artist> SimilarArtists { get; set; } = new();

    public bool FailProfile { get; set; }
    public bool FailSongPage { get; set; }
    public bool FailNextSongPage { get; set; }
    public bool FailHighlights { get; set; }

    public TestGate? SongGate { get; set; }
    public TestGate? AlbumGate { get; set; }

    public IReadOnlyList<int> RequestedSongOffsets
    {
        get { lock (_gate) return _songOffsets.ToList(); }
    }

    public IReadOnlyList<int> RequestedAlbumOffsets
    {
        get { lock (_gate) return _albumOffsets.ToList(); }
    }

    public IReadOnlyList<int> RequestedMVOffsets
    {
        get { lock (_gate) return _mvOffsets.ToList(); }
    }

    public void EnqueueSongPage(ArtistSongPage page)
    {
        lock (_gate) _songPages.Enqueue(page);
    }

    public void EnqueueAlbumPage(ArtistAlbumPage page)
    {
        lock (_gate) _albumPages.Enqueue(page);
    }

    public void EnqueueMVPage(ArtistMVPage page)
    {
        lock (_gate) _mvPages.Enqueue(page);
    }

    public async Task<ArtistProfile> FetchArtistProfileAsync(string id, CancellationToken ct = default)
    {
        await Task.Yield();
        if (FailProfile) throw MusicException.NotLoggedIn();
        return Profile;
    }

    public async Task<List<Song>> FetchHotArtistSongsAsync(string id, CancellationToken ct = default)
    {
        await Task.Yield();
        if (FailHighlights) throw MusicException.InvalidResponse();
        return HotSongs;
    }

    public async Task<ArtistSongPage> FetchArtistSongsAsync(string id, int offset, int limit = 50, string order = "hot", CancellationToken ct = default)
    {
        lock (_gate) _songOffsets.Add(offset);
        if (SongGate is { } gate) await gate.WaitAsync().ConfigureAwait(false);
        if (FailSongPage || FailNextSongPage)
        {
            FailNextSongPage = false;
            throw MusicException.ApiError(524, "风控");
        }
        lock (_gate) return _songPages.Count > 0 ? _songPages.Dequeue() : new ArtistSongPage();
    }

    public async Task<ArtistAlbumPage> FetchArtistAlbumsAsync(string id, int offset, int limit = 30, CancellationToken ct = default)
    {
        lock (_gate) _albumOffsets.Add(offset);
        if (AlbumGate is { } gate) await gate.WaitAsync().ConfigureAwait(false);
        lock (_gate) return _albumPages.Count > 0 ? _albumPages.Dequeue() : new ArtistAlbumPage();
    }

    public async Task<ArtistMVPage> FetchArtistMVsAsync(string id, int offset, int limit = 30, CancellationToken ct = default)
    {
        lock (_gate) _mvOffsets.Add(offset);
        await Task.Yield();
        lock (_gate) return _mvPages.Count > 0 ? _mvPages.Dequeue() : new ArtistMVPage();
    }

    public async Task<ArtistIntro> FetchArtistIntroAsync(string id, CancellationToken ct = default)
    {
        await Task.Yield();
        return Intro;
    }

    public async Task<List<Artist>> FetchSimilarArtistsAsync(string artistID, CancellationToken ct = default)
    {
        await Task.Yield();
        if (FailHighlights) throw MusicException.InvalidResponse();
        return SimilarArtists;
    }
}
