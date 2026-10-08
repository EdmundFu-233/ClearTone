namespace ClearTone.Core.Models;

public record ArtistProfile
{
    public Artist Artist { get; set; } = new();
    public string? BriefDescription { get; set; }
    public int AlbumCount { get; set; }
    public int SongCount { get; set; }
    public int MvCount { get; set; }
    public int VideoCount { get; set; }
    public List<string> IdentifyTags { get; set; } = new();
    public bool? IsFollowed { get; set; }
}

public record ArtistIntroSection
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public string Body { get; set; } = "";
}

public record ArtistIntro
{
    public string? BriefDescription { get; set; }
    public List<ArtistIntroSection> Sections { get; set; } = new();
    public bool IsEmpty => Sections.Count == 0 && string.IsNullOrEmpty(BriefDescription);
}

public record ArtistSongPage
{
    public List<Song> Songs { get; set; } = new();
    public int Total { get; set; }
    public bool HasMore { get; set; }

    public static readonly ArtistSongPage Empty = new();
}

public record ArtistAlbumPage
{
    public List<Album> Albums { get; set; } = new();
    public bool? IsFollowed { get; set; }
    public bool HasMore { get; set; }

    public static readonly ArtistAlbumPage Empty = new();
}

public record ArtistMV
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string? ArtistName { get; set; }
    public string? CoverURL { get; set; }
    public double Duration { get; set; }
    public int PlayCount { get; set; }
    public DateTimeOffset? PublishDate { get; set; }
}

public record ArtistMVPage
{
    public List<ArtistMV> Mvs { get; set; } = new();
    public bool HasMore { get; set; }

    public static readonly ArtistMVPage Empty = new();
}

public interface IArtistProfileProvider
{
    Task<ArtistProfile> FetchArtistProfileAsync(string id, CancellationToken ct = default);
    Task<List<Song>> FetchHotArtistSongsAsync(string id, CancellationToken ct = default);
    Task<ArtistSongPage> FetchArtistSongsAsync(string id, int offset, int limit = 50, string order = "hot", CancellationToken ct = default);
    Task<ArtistAlbumPage> FetchArtistAlbumsAsync(string id, int offset, int limit = 30, CancellationToken ct = default);
    Task<ArtistMVPage> FetchArtistMVsAsync(string id, int offset, int limit = 30, CancellationToken ct = default);
    Task<ArtistIntro> FetchArtistIntroAsync(string id, CancellationToken ct = default);
    Task<List<Artist>> FetchSimilarArtistsAsync(string artistID, CancellationToken ct = default);
}
