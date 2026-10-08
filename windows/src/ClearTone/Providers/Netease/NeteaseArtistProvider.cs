using System.Text.Json;
using ClearTone.Core.Models;

namespace ClearTone.Providers.Netease;

public sealed partial class NeteaseProvider : IArtistProfileProvider
{
    public async Task<ArtistProfile> FetchArtistProfileAsync(string id, CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie();
        var data = await RequestAsync("/artist/detail", new Dictionary<string, string>
        {
            ["id"] = id,
        }, cookie, TimeSpan.FromSeconds(600), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var payload = json.Prop("data");
        var artistDict = payload.Prop("artist");
        if (payload is null || artistDict is null) throw MusicException.InvalidResponse();
        var artist = MapArtist(artistDict.Value);
        var identifyTags = (artistDict.Value.Prop("identifyTag").AsString() ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries)
            .Select(tag => tag.Trim())
            .Where(tag => tag.Length > 0)
            .ToList();
        return new ArtistProfile
        {
            Artist = artist,
            BriefDescription = artistDict.Value.Prop("briefDesc").AsString(),
            AlbumCount = artistDict.Value.Prop("albumSize").AsInt() ?? 0,
            SongCount = artistDict.Value.Prop("musicSize").AsInt() ?? 0,
            MvCount = artistDict.Value.Prop("mvSize").AsInt() ?? 0,
            VideoCount = payload.Value.Prop("videoCount").AsInt() ?? 0,
            IdentifyTags = identifyTags,
            IsFollowed = OptionalBool(artistDict.Value.Prop("followed")),
        };
    }

    public async Task<List<Song>> FetchHotArtistSongsAsync(string id, CancellationToken ct = default)
    {
        var data = await RequestAsync("/artist/top/song", new Dictionary<string, string>
        {
            ["id"] = id,
        }, cacheTtl: TimeSpan.FromSeconds(600), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        return json.Prop("songs").AsArray()?.CompactMap(MapSong) ?? new List<Song>();
    }

    public async Task<ArtistSongPage> FetchArtistSongsAsync(
        string id, int offset, int limit = 50, string order = "hot", CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie();
        var data = await RequestAsync("/artist/songs", new Dictionary<string, string>
        {
            ["id"] = id,
            ["order"] = order,
            ["offset"] = offset.ToString(),
            ["limit"] = limit.ToString(),
        }, cookie, order == "hot" ? TimeSpan.FromSeconds(300) : null, ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var songs = json.Prop("songs").AsArray()?.CompactMap(MapSong) ?? new List<Song>();
        return new ArtistSongPage
        {
            Songs = songs,
            Total = json.Prop("total").AsInt() ?? offset + songs.Count,
            HasMore = json.Prop("more").AsBool() ?? (songs.Count >= limit),
        };
    }

    public async Task<ArtistAlbumPage> FetchArtistAlbumsAsync(
        string id, int offset, int limit = 30, CancellationToken ct = default)
    {
        var data = await RequestAsync("/artist/album", new Dictionary<string, string>
        {
            ["id"] = id,
            ["offset"] = offset.ToString(),
            ["limit"] = limit.ToString(),
            ["total"] = "true",
        }, cacheTtl: TimeSpan.FromSeconds(300), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var albums = json.Prop("hotAlbums").AsArray()?.Select(MapAlbum).ToList() ?? new List<Album>();
        var artistDict = json.Prop("artist");
        return new ArtistAlbumPage
        {
            Albums = albums,
            IsFollowed = OptionalBool(artistDict.Prop("followed")),
            HasMore = json.Prop("more").AsBool() ?? (albums.Count >= limit),
        };
    }

    public async Task<ArtistMVPage> FetchArtistMVsAsync(
        string id, int offset, int limit = 30, CancellationToken ct = default)
    {
        var data = await RequestAsync("/artist/mv", new Dictionary<string, string>
        {
            ["id"] = id,
            ["offset"] = offset.ToString(),
            ["limit"] = limit.ToString(),
            ["total"] = "true",
        }, cacheTtl: TimeSpan.FromSeconds(300), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var mvs = json.Prop("mvs").AsArray()?.CompactMap(MapArtistMV) ?? new List<ArtistMV>();
        return new ArtistMVPage
        {
            Mvs = mvs,
            HasMore = json.Prop("hasMore").AsBool() ?? (mvs.Count >= limit),
        };
    }

    internal static ArtistMV? MapArtistMV(JsonElement dict)
    {
        var id = dict.Prop("id").AsIDString();
        if (id is null) return null;
        var durationMs = dict.Prop("duration").AsLong() ?? 0;
        var publishTime = dict.Prop("publishTime").AsLong();
        return new ArtistMV
        {
            Id = id,
            Name = dict.Prop("name").AsString() ?? "未命名 MV",
            ArtistName = dict.Prop("artistName").AsString(),
            CoverURL = dict.Prop("imgurl16v9").AsString() ?? dict.Prop("imgurl").AsString(),
            Duration = durationMs / 1000.0,
            PlayCount = (int)(dict.Prop("playCount").AsLong() ?? 0),
            PublishDate = publishTime is null
                ? null
                : DateTimeOffset.FromUnixTimeMilliseconds(publishTime.Value),
        };
    }

    public async Task<ArtistIntro> FetchArtistIntroAsync(string id, CancellationToken ct = default)
    {
        var data = await RequestAsync("/artist/desc", new Dictionary<string, string>
        {
            ["id"] = id,
        }, cacheTtl: TimeSpan.FromSeconds(3600), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var sections = new List<ArtistIntroSection>();
        foreach (var entry in json.Prop("introduction").AsArray() ?? new List<JsonElement>())
        {
            var body = entry.Prop("txt").AsString()?.Trim();
            if (string.IsNullOrEmpty(body)) continue;
            var title = (entry.Prop("ti").AsString() ?? "").Trim();
            sections.Add(new ArtistIntroSection { Title = title, Body = body });
        }
        var brief = json.Prop("briefDesc").AsString()?.Trim();
        return new ArtistIntro
        {
            BriefDescription = string.IsNullOrEmpty(brief) ? null : brief,
            Sections = sections,
        };
    }

    internal static bool? OptionalBool(JsonElement? value) => value.AsBool();
}
