using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ClearTone.Core;
using ClearTone.Core.Logging;
using ClearTone.Core.Models;
using ClearTone.Core.Networking;
using ClearTone.Core.Security;

namespace ClearTone.Providers.Netease;

public sealed partial class NeteaseProvider : IMusicProvider
{
    public static readonly NeteaseProvider Shared = new();

    public string Identifier => "netease";
    public string DisplayName => "网易云音乐";

    public event Action? SessionExpired;

    private readonly HttpClient _session;
    private readonly HttpClient _probeClient;

    private readonly object _cacheGate = new();
    private readonly Dictionary<string, CacheEntry> _responseCache = new(StringComparer.Ordinal);
    private long _responseCacheBytes;
    private int _responseCacheGeneration;

    private readonly object _playlistGate = new();
    private readonly Dictionary<string, (List<Song> Songs, DateTime CachedAt)> _playlistTrackCache = new(StringComparer.Ordinal);

    private readonly object _reachGate = new();
    private readonly Dictionary<string, DateTime> _reachCache = new(StringComparer.Ordinal);

    private readonly SessionExpiryGuard _sessionGuard = new();

    private const int ResponseCacheEntryLimit = 128;
    private const long ResponseCacheByteLimit = 32L * 1024 * 1024;
    private static readonly TimeSpan PlaylistTrackCacheTtl = TimeSpan.FromSeconds(600);
    private const int PlaylistTrackCacheLimit = 8;
    private static readonly TimeSpan ReachCacheTtl = TimeSpan.FromSeconds(180);
    private const int DetailBatchSize = 500;

    public NeteaseProvider()
    {
        var handler = new SocketsHttpHandler
        {
            UseCookies = false,
            UseProxy = false,
            ConnectTimeout = TimeSpan.FromSeconds(10),
        };
        _session = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };

        var probeHandler = new SocketsHttpHandler
        {
            UseCookies = false,
            UseProxy = false,
            ConnectTimeout = TimeSpan.FromSeconds(3),
        };
        _probeClient = new HttpClient(probeHandler) { Timeout = TimeSpan.FromSeconds(4) };
    }

    private sealed record CacheEntry(byte[] Data, DateTime ExpiresAt);

    // MARK: - 凭据

    public static string? LoadLoginCookie()
    {
        var raw = CredentialStore.Shared.Load(CredentialKey.NeteaseCookie);
        if (raw is null) return null;
        var normalized = NeteaseCookieNormalizer.Normalize(raw);
        return normalized.Length == 0 ? null : normalized;
    }

    private static string RequireUserID()
    {
        var userID = CredentialStore.Shared.Load(CredentialKey.NeteaseUserID);
        if (string.IsNullOrEmpty(userID)) throw MusicException.NotLoggedIn();
        return userID;
    }

    // MARK: - 认证

    public async Task<string> FetchQRCodeKeyAsync(CancellationToken ct = default)
    {
        var data = await RequestAsync("/login/qr/key", new Dictionary<string, string> { ["randomCNIP"] = "true" }, ct: ct);
        var json = ParseJson(data);
        var key = json.Prop("data").Prop("unikey").AsString();
        if (key is null) throw MusicException.InvalidResponse();
        return key;
    }

    public async Task<string> FetchQRCodeImageAsync(string key, CancellationToken ct = default)
    {
        var data = await RequestAsync("/login/qr/create", new Dictionary<string, string>
        {
            ["key"] = key,
            ["qrimg"] = "true",
        }, ct: ct);
        var json = ParseJson(data);
        var qrimg = json.Prop("data").Prop("qrimg").AsString();
        if (qrimg is null) throw MusicException.InvalidResponse();
        return qrimg;
    }

    public async Task<QRLoginStatus> CheckQRCodeStatusAsync(string key, CancellationToken ct = default)
    {
        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString();
        var data = await RequestAsync("/login/qr/check", new Dictionary<string, string>
        {
            ["key"] = key,
            ["timestamp"] = timestamp,
            ["randomCNIP"] = "true",
        }, ct: ct);
        var json = ParseJson(data);
        var code = json.Prop("code").AsInt();
        if (code is null) throw MusicException.InvalidResponse();

        return code switch
        {
            800 => new QRLoginStatus.Expired(),
            801 => new QRLoginStatus.WaitingScan(),
            802 => new QRLoginStatus.ScannedWaitingConfirm(),
            803 => json.Prop("cookie").AsString() is { } cookie
                ? new QRLoginStatus.Success(cookie)
                : throw MusicException.InvalidResponse(),
            _ => new QRLoginStatus.Failed(json.Prop("message").AsString() ?? "未知错误"),
        };
    }

    public async Task LogoutAsync(CancellationToken ct = default)
    {
        try
        {
            var cookie = LoadLoginCookie();
            await RequestAsync("/logout", cookie: cookie, method: "POST", ct: ct);
        }
        finally
        {
            CredentialStore.Shared.Delete(CredentialKey.NeteaseCookie);
            CredentialStore.Shared.Delete(CredentialKey.NeteaseUserID);
            ResetSessionGuard();
            ClearCache();
        }
    }

    public void ResetSessionGuard()
    {
        lock (_sessionGuard) _sessionGuard.Reset();
    }

    public async Task<AccountInfo?> FetchAccountInfoAsync(CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie();
        if (cookie is null) return null;
        return await FetchAccountInfoAsync(cookie, ct).ConfigureAwait(false);
    }

    internal async Task<AccountInfo?> FetchAccountInfoAsync(string cookie, CancellationToken ct = default)
    {
        var data = await RequestAsync("/user/account", cookie: cookie, ct: ct);
        var json = ParseJson(data);
        var account = json.Prop("account");
        var profile = json.Prop("profile");
        if (account is null || profile is null) return null;

        var userID = account.Value.Prop("id").AsIDString() ?? "";
        var nickname = profile.Value.Prop("nickname").AsString() ?? "未知用户";
        var avatarURL = profile.Value.Prop("avatarUrl").AsString();
        var vipType = account.Value.Prop("vipType").AsInt() ?? 0;
        return new AccountInfo
        {
            UserID = userID,
            Nickname = nickname,
            AvatarURL = avatarURL,
            IsVIP = vipType > 0,
        };
    }

    // MARK: - 搜索

    public async Task<SearchResult> SearchAsync(string query, SearchType type, int page, int limit, CancellationToken ct = default)
    {
        var typeCode = type switch
        {
            SearchType.Song => 1,
            SearchType.Artist => 100,
            SearchType.Album => 10,
            _ => 1000,
        };

        var data = await RequestAsync("/cloudsearch", new Dictionary<string, string>
        {
            ["keywords"] = query,
            ["type"] = typeCode.ToString(),
            ["limit"] = limit.ToString(),
            ["offset"] = ((page - 1) * limit).ToString(),
        }, cacheTtl: TimeSpan.FromSeconds(120), ct: ct);
        var json = ParseJson(data);
        var result = json.Prop("result");
        if (result is null) throw MusicException.InvalidResponse();

        var searchResult = new SearchResult();
        switch (type)
        {
            case SearchType.Song:
                searchResult.Songs = result.Value.Prop("songs").AsArray().CompactMap(MapSong);
                searchResult.TotalCount = result.Value.Prop("songCount").AsInt() ?? 0;
                break;
            case SearchType.Artist:
                searchResult.Artists = result.Value.Prop("artists").AsArray()?.Select(MapArtist).ToList()
                    ?? new List<Artist>();
                searchResult.TotalCount = result.Value.Prop("artistCount").AsInt() ?? 0;
                break;
            case SearchType.Album:
                searchResult.Albums = result.Value.Prop("albums").AsArray()
                    .CompactMap(element => MapAlbum(element));
                searchResult.TotalCount = result.Value.Prop("albumCount").AsInt() ?? 0;
                break;
            default:
                searchResult.Playlists = result.Value.Prop("playlists").AsArray()
                    .CompactMap(element => MapPlaylist(element));
                searchResult.TotalCount = result.Value.Prop("playlistCount").AsInt() ?? 0;
                break;
        }

        searchResult.HasMore = result.Value.Prop("hasMore").AsBool() ?? (page * limit < searchResult.TotalCount);
        return searchResult;
    }

    // MARK: - 歌单 / 专辑 / 歌手

    public async Task<PlaylistDetail> FetchPlaylistDetailAsync(string id, CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie() ?? "";
        var data = await RequestAsync("/playlist/detail", new Dictionary<string, string> { ["id"] = id },
            cookie, TimeSpan.FromSeconds(300), ct: ct);
        var json = ParseJson(data);
        var playlistDict = json.Prop("playlist");
        if (playlistDict is null) throw MusicException.InvalidResponse();

        var playlist = MapPlaylist(playlistDict.Value);
        var trackIds = playlistDict.Value.Prop("trackIds").AsArray()?.Count ?? 0;
        var totalCount = playlistDict.Value.Prop("trackCount").AsInt() ?? trackIds;
        var tracks = playlistDict.Value.Prop("tracks").AsArray().CompactMap(MapSong);
        return new PlaylistDetail
        {
            Playlist = playlist,
            Tracks = tracks,
            TotalTrackCount = totalCount,
        };
    }

    public async Task<List<Song>> FetchPlaylistTracksAsync(string id, int page, int limit, CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie() ?? "";
        var data = await RequestAsync("/playlist/track/all", new Dictionary<string, string>
        {
            ["id"] = id,
            ["limit"] = limit.ToString(),
            ["offset"] = ((page - 1) * limit).ToString(),
        }, cookie, TimeSpan.FromSeconds(300), ct: ct);
        var json = ParseJson(data);
        var songs = json.Prop("songs").AsArray();
        if (songs is null) throw MusicException.InvalidResponse();
        return songs.CompactMap(MapSong);
    }

    public List<Song>? CachedPlaylistTracks(string id)
    {
        lock (_playlistGate)
        {
            if (!_playlistTrackCache.TryGetValue(id, out var entry)) return null;
            if (DateTime.UtcNow - entry.CachedAt >= PlaylistTrackCacheTtl)
            {
                _playlistTrackCache.Remove(id);
                return null;
            }
            return entry.Songs;
        }
    }

    private void StorePlaylistTracks(List<Song> songs, string id)
    {
        lock (_playlistGate)
        {
            _playlistTrackCache[id] = (songs, DateTime.UtcNow);
            if (_playlistTrackCache.Count <= PlaylistTrackCacheLimit) return;
            var overflow = _playlistTrackCache.Count - PlaylistTrackCacheLimit;
            foreach (var key in _playlistTrackCache.OrderBy(pair => pair.Value.CachedAt).Take(overflow).Select(pair => pair.Key).ToList())
            {
                _playlistTrackCache.Remove(key);
            }
        }
    }

    public async IAsyncEnumerable<List<Song>> StreamPlaylistTracksAsync(
        string id,
        int totalCount,
        int pageSize = 100,
        int maxConcurrent = 4,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
    {
        var pageCount = Math.Max(1, (int)Math.Ceiling((double)totalCount / pageSize));
        var pending = new Dictionary<int, Task<List<Song>>>();
        var nextToStart = 1;
        var assembled = new List<Song>();

        while (nextToStart <= pageCount && nextToStart <= maxConcurrent)
        {
            pending[nextToStart] = FetchPlaylistTracksAsync(id, nextToStart, pageSize, ct);
            nextToStart++;
        }

        for (var nextToYield = 1; nextToYield <= pageCount; nextToYield++)
        {
            if (!pending.TryGetValue(nextToYield, out var task))
            {
                task = FetchPlaylistTracksAsync(id, nextToYield, pageSize, ct);
            }
            var songs = await task.ConfigureAwait(false);
            pending.Remove(nextToYield);
            assembled.AddRange(songs);
            yield return songs;

            if (nextToStart <= pageCount)
            {
                pending[nextToStart] = FetchPlaylistTracksAsync(id, nextToStart, pageSize, ct);
                nextToStart++;
            }
        }

        StorePlaylistTracks(assembled, id);
    }

    public async Task<PlaylistDetail> FetchAlbumDetailAsync(string id, CancellationToken ct = default)
    {
        var data = await RequestAsync("/album", new Dictionary<string, string> { ["id"] = id },
            cacheTtl: TimeSpan.FromSeconds(600), ct: ct);
        var json = ParseJson(data);
        var albumDict = json.Prop("album");
        if (albumDict is null) throw MusicException.InvalidResponse();

        var album = MapAlbum(albumDict.Value);
        var songs = json.Prop("songs").AsArray().CompactMap(MapSong);
        var albumArtist = albumDict.Value.Prop("artist");
        string? artistID = null;
        if (albumArtist is { } artist)
        {
            var raw = artist.Prop("id").AsIDString();
            if (raw is not null && raw != "0") artistID = raw;
        }

        var playlist = new Playlist
        {
            Id = album.Id,
            Name = album.Name,
            CoverURL = album.CoverURL,
            TrackCount = songs.Count,
            CreatorName = albumArtist?.Prop("name").AsString(),
            Source = SongSource.Netease,
        };
        return new PlaylistDetail
        {
            Playlist = playlist,
            Tracks = songs,
            TotalTrackCount = songs.Count,
            ArtistID = artistID,
        };
    }

    public async Task<ArtistDetail> FetchArtistDetailAsync(string id, CancellationToken ct = default)
    {
        var profileTask = RequestAsync("/artist/detail", new Dictionary<string, string> { ["id"] = id },
            cacheTtl: TimeSpan.FromSeconds(600), ct: ct);
        var songsTask = RequestAsync("/artist/top/song", new Dictionary<string, string> { ["id"] = id },
            cacheTtl: TimeSpan.FromSeconds(600), ct: ct);
        var albumsTask = RequestAsync("/artist/album", new Dictionary<string, string> { ["id"] = id, ["limit"] = "20" },
            cacheTtl: TimeSpan.FromSeconds(600), ct: ct);
        await Task.WhenAll(profileTask, songsTask, albumsTask).ConfigureAwait(false);

        var profileJson = ParseJson(await profileTask.ConfigureAwait(false));
        var artistDict = profileJson.Prop("data").Prop("artist");
        if (artistDict is null) throw MusicException.InvalidResponse();
        var artist = MapArtist(artistDict.Value);

        var songsJson = ParseJson(await songsTask.ConfigureAwait(false));
        var hotSongs = songsJson.Prop("songs").AsArray().CompactMap(MapSong);

        var albumsJson = ParseJson(await albumsTask.ConfigureAwait(false));
        var albums = albumsJson.Prop("hotAlbums").AsArray().CompactMap(MapAlbum);

        return new ArtistDetail { Artist = artist, HotSongs = hotSongs, Albums = albums };
    }

    // MARK: - 播放地址

    public async Task<PlayableURL> FetchPlayableURLAsync(string songID, QualityLevel quality, CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie() ?? "";
        var level = quality switch
        {
            QualityLevel.Standard => "standard",
            QualityLevel.Higher => "higher",
            QualityLevel.ExHigh => "exhigh",
            QualityLevel.Lossless => "lossless",
            QualityLevel.HiRes => "hires",
            _ => "standard",
        };

        Uri? standardUrl = null;
        AudioQuality? standardQuality = null;
        var standardIsPreview = false;
        long? standardSizeBytes = null;

        try
        {
            var data = await RequestAsync("/song/url/v1", new Dictionary<string, string>
            {
                ["id"] = songID,
                ["level"] = level,
            }, cookie, TimeSpan.FromSeconds(240), ct: ct);
            var json = ParseJson(data);
            var first = json.Prop("data").AsArray()?.FirstOrDefault();
            if (first is { } song)
            {
                var urlString = song.Prop("url").AsString();
                if (urlString is not null && Uri.TryCreate(urlString, UriKind.Absolute, out var raw))
                {
                    var primary = UpgradeToHttps(raw);
                    var br = song.Prop("br").AsInt();
                    var hasTrial = song.Prop("freeTrialInfo") is { ValueKind: JsonValueKind.Object };
                    var isPreview = hasTrial || br == 128012 || br == 128018;
                    standardUrl = primary;
                    standardIsPreview = isPreview;
                    standardSizeBytes = song.Prop("size").AsLong();
                    var bitrate = br is { } rate && rate / 1000 > 0 ? rate / 1000 : (int?)null;
                    standardQuality = new AudioQuality
                    {
                        Level = QualityLevelExtensions.FromAPIValue(song.Prop("level").AsString()),
                        Bitrate = bitrate,
                        SampleRate = song.Prop("sr").AsInt(),
                        IsActual = true,
                        Codec = CodecName(song.Prop("encodeType").AsString(), primary),
                    };
                    if (!isPreview && await IsStreamReachableAsync(primary, ct).ConfigureAwait(false))
                    {
                        return new PlayableURL
                        {
                            Url = primary,
                            Quality = standardQuality,
                            SizeBytes = standardSizeBytes,
                        };
                    }
                }
            }
        }
        catch (MusicException error) when (error.Kind != MusicErrorKind.Cancelled)
        {
        }

        ct.ThrowIfCancellationRequested();

        foreach (var source in new[] { "unm", "gdmusic" })
        {
            try
            {
                var match = await FetchMatchURLAsync(songID, source, ct).ConfigureAwait(false);
                if (match is null) continue;
                var upgraded = UpgradeToHttps(match);
                if (!await IsStreamReachableAsync(upgraded, ct).ConfigureAwait(false)) continue;
                return new PlayableURL
                {
                    Url = upgraded,
                    Quality = new AudioQuality { Level = QualityLevel.Unknown, IsActual = true },
                };
            }
            catch (MusicException error) when (error.Kind != MusicErrorKind.Cancelled)
            {
            }
        }

        if (standardUrl is not null)
        {
            return new PlayableURL
            {
                Url = standardUrl,
                Quality = standardQuality ?? new AudioQuality { Level = QualityLevel.Unknown, IsActual = true },
                IsPreview = standardIsPreview,
                SizeBytes = standardSizeBytes,
            };
        }
        throw MusicException.NoPlayableURL();
    }

    private async Task<Uri?> FetchMatchURLAsync(string songID, string? source, CancellationToken ct)
    {
        var cookie = LoadLoginCookie() ?? "";
        var query = new Dictionary<string, string> { ["id"] = songID };
        if (!string.IsNullOrEmpty(source)) query["source"] = source;
        var data = await RequestAsync("/song/url/match", query, cookie, TimeSpan.FromSeconds(240), ct: ct);
        var json = ParseJson(data);
        var urlString = json.Prop("data").AsString();
        if (urlString is null) return null;
        return Uri.TryCreate(urlString, UriKind.Absolute, out var url) ? url : null;
    }

    private static Uri UpgradeToHttps(Uri url)
    {
        if (!url.Scheme.Equals("http", StringComparison.OrdinalIgnoreCase)) return url;
        var builder = new UriBuilder(url) { Scheme = "https" };
        return builder.Uri;
    }

    internal async Task<bool> IsStreamReachableAsync(Uri url, CancellationToken ct = default)
    {
        var key = url.AbsoluteUri;
        lock (_reachGate)
        {
            if (_reachCache.TryGetValue(key, out var at) && DateTime.UtcNow - at < ReachCacheTtl)
            {
                return true;
            }
        }

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.TryAddWithoutValidation("Range", "bytes=0-0");
            using var response = await _probeClient
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct)
                .ConfigureAwait(false);
            var ok = (int)response.StatusCode is >= 200 and <= 299;
            if (ok)
            {
                lock (_reachGate) _reachCache[key] = DateTime.UtcNow;
            }
            return ok;
        }
        catch
        {
            return false;
        }
    }

    // MARK: - 歌词

    public async Task<LyricResult> FetchLyricsAsync(string songID, CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie() ?? "";
        var data = await RequestAsync("/lyric/new", new Dictionary<string, string> { ["id"] = songID },
            cookie, TimeSpan.FromSeconds(1800), ct: ct);
        var json = ParseJson(data);

        var lrc = json.Prop("lrc").Prop("lyric").AsString() ?? "";
        var tlyric = json.Prop("tlyric").Prop("lyric").AsString();
        var romalrc = json.Prop("romalrc").Prop("lyric").AsString();
        var yrc = json.Prop("yrc").Prop("lyric").AsString();

        var isPureMusic = lrc.Trim().Length == 0 && string.IsNullOrEmpty(yrc);

        if (!string.IsNullOrEmpty(yrc))
        {
            var lines = LRCParser.ParseYRC(yrc, tlyric, romalrc);
            return new LyricResult { Lines = lines, HasWordTiming = true, IsPureMusic = false };
        }

        var parsed = LRCParser.Parse(lrc, tlyric, romalrc);
        return new LyricResult { Lines = parsed, HasWordTiming = false, IsPureMusic = isPureMusic };
    }

    // MARK: - 用户数据

    public async Task<List<Playlist>> FetchUserPlaylistsAsync(CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie() ?? throw MusicException.NotLoggedIn();
        var userID = RequireUserID();
        var data = await RequestAsync("/user/playlist", new Dictionary<string, string>
        {
            ["uid"] = userID,
            ["limit"] = "1000",
        }, cookie, TimeSpan.FromSeconds(120), ct: ct);
        var json = ParseJson(data);
        var playlists = json.Prop("playlist").AsArray();
        if (playlists is null) throw MusicException.InvalidResponse();
        return playlists.CompactMap(MapPlaylist);
    }

    public async Task<List<string>> FetchLikedSongIDsAsync(CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie() ?? throw MusicException.NotLoggedIn();
        var userID = RequireUserID();
        var data = await RequestAsync("/likelist", new Dictionary<string, string> { ["uid"] = userID },
            cookie, TimeSpan.FromSeconds(60), ct: ct);
        var json = ParseJson(data);
        var ids = json.Prop("ids").AsArray();
        if (ids is null) throw MusicException.InvalidResponse();
        return ids.Select(element => element.AsIDString() ?? "").Where(id => id.Length > 0).ToList();
    }

    public async Task<List<Song>> FetchLikedSongsAsync(CancellationToken ct = default)
    {
        var idStrings = await FetchLikedSongIDsAsync(ct).ConfigureAwait(false);
        if (idStrings.Count == 0) return new List<Song>();
        var cookie = LoadLoginCookie();

        var result = new List<Song>(idStrings.Count);
        for (var start = 0; start < idStrings.Count; start += DetailBatchSize)
        {
            var end = Math.Min(start + DetailBatchSize, idStrings.Count);
            var batch = idStrings.GetRange(start, end - start);
            var detailData = await RequestAsync("/song/detail", new Dictionary<string, string>
            {
                ["ids"] = string.Join(",", batch),
            }, cookie, TimeSpan.FromSeconds(300), ct: ct);
            var songs = ParseJson(detailData).Prop("songs").AsArray();
            if (songs is null) continue;
            result.AddRange(songs.CompactMap(MapSong));
        }
        return result;
    }

    public async Task LikeSongAsync(string id, bool like, CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie() ?? "";
        if (cookie.Length == 0) throw MusicException.NotLoggedIn();
        var userID = CredentialStore.Shared.Load(CredentialKey.NeteaseUserID);
        if (string.IsNullOrEmpty(userID)) throw MusicException.NotLoggedIn();

        var data = await RequestAsync("/song/like", new Dictionary<string, string>
        {
            ["id"] = id,
            ["uid"] = userID,
            ["like"] = like ? "true" : "false",
        }, cookie, method: "POST", ct: ct);
        var json = ParseJson(data);
        var code = json.Prop("code").AsInt();
        if (code != 200)
        {
            throw MusicException.ApiError(code ?? -1, LikeFailureMessage(json));
        }
        InvalidateCache(new[] { "/likelist", "/song/detail", "/user/playlist", "/playlist/detail" });
    }

    public async Task<List<Playlist>> FetchRecommendPlaylistsAsync(CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie() ?? "";
        var data = await RequestAsync("/personalized", new Dictionary<string, string> { ["limit"] = "20" },
            cookie, TimeSpan.FromSeconds(600), ct: ct);
        var json = ParseJson(data);
        var result = json.Prop("result").AsArray();
        if (result is null) throw MusicException.InvalidResponse();
        return result.CompactMap(MapPlaylist);
    }

    public async Task<List<Song>> FetchDailyRecommendSongsAsync(CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie() ?? throw MusicException.NotLoggedIn();
        var data = await RequestAsync("/recommend/songs", cookie: cookie, cacheTtl: TimeSpan.FromSeconds(300), ct: ct);
        var json = ParseJson(data);
        var dailySongs = json.Prop("data").Prop("dailySongs").AsArray();
        if (dailySongs is null) throw MusicException.InvalidResponse();
        return dailySongs.CompactMap(MapSong);
    }

    // MARK: - 电台

    public async Task<List<RadioCategory>> FetchRadioCategoriesAsync(CancellationToken ct = default)
    {
        var data = await RequestAsync("/dj/catelist", cacheTtl: TimeSpan.FromSeconds(3600), ct: ct);
        var json = ParseJson(data);
        var categories = json.Prop("categories").AsArray();
        if (categories is null) throw MusicException.InvalidResponse();
        var result = new List<RadioCategory>();
        foreach (var dict in categories)
        {
            var name = dict.Prop("name").AsString();
            if (name is null) continue;
            var id = dict.Prop("id").AsIDString() ?? "";
            var subs = dict.Prop("sub").AsArray()?
                .Select(element => element.Prop("name").AsString())
                .Where(value => value is not null)
                .Select(value => value!)
                .ToList() ?? new List<string>();
            result.Add(new RadioCategory { Id = id, Name = name, SubCategories = subs });
        }
        return result;
    }

    public async Task<List<RadioStation>> FetchRecommendedRadiosAsync(int limit = 30, CancellationToken ct = default)
    {
        var data = await RequestAsync("/dj/recommend", new Dictionary<string, string> { ["limit"] = limit.ToString() },
            cacheTtl: TimeSpan.FromSeconds(600), ct: ct);
        return ParseRadioStations(data);
    }

    public async Task<List<RadioStation>> FetchHotRadiosAsync(string? categoryID = null, int limit = 30, CancellationToken ct = default)
    {
        var query = new Dictionary<string, string> { ["limit"] = limit.ToString() };
        if (!string.IsNullOrEmpty(categoryID)) query["cat"] = categoryID;
        var data = await RequestAsync("/dj/hot", query, cacheTtl: TimeSpan.FromSeconds(600), ct: ct);
        return ParseRadioStations(data);
    }

    private List<RadioStation> ParseRadioStations(byte[] data)
    {
        var json = ParseJson(data);
        var radios = json.Prop("djRadios").AsArray();
        if (radios is null) throw MusicException.InvalidResponse();
        return radios.CompactMap(MapRadioStation);
    }

    public static RadioStation? MapRadioStation(JsonElement dict)
    {
        var id = dict.Prop("id").AsIDString();
        if (id is null) return null;
        var dj = dict.Prop("dj");
        return new RadioStation
        {
            Id = id,
            Name = dict.Prop("name").AsString() ?? "未命名电台",
            CoverURL = dict.Prop("picUrl").AsString(),
            ProgramCount = dict.Prop("programCount").AsInt() ?? 0,
            SubscriberCount = dict.Prop("subCount").AsInt() ?? 0,
            CreatorName = dj?.Prop("nickname").AsString(),
            CategoryName = dict.Prop("categoryName").AsString() ?? dict.Prop("category").AsString(),
            DescriptionText = dict.Prop("desc").AsString(),
            IsSubscribed = dict.Prop("isSub").AsInt() == 1 || dict.Prop("isSub").AsBool() == true,
        };
    }

    public async Task<List<RadioProgram>> FetchRadioProgramsAsync(string radioID, int page = 1, int limit = 30, CancellationToken ct = default)
    {
        var offset = (page - 1) * limit;
        var data = await RequestAsync("/dj/program", new Dictionary<string, string>
        {
            ["rid"] = radioID,
            ["limit"] = limit.ToString(),
            ["offset"] = offset.ToString(),
        }, cacheTtl: TimeSpan.FromSeconds(300), ct: ct);
        var json = ParseJson(data);
        var programs = json.Prop("programs").AsArray();
        if (programs is null) throw MusicException.InvalidResponse();
        return programs.CompactMap(element => MapRadioProgram(element, null));
    }

    private static RadioProgram? MapRadioProgram(JsonElement dict, string? stationName)
    {
        var id = dict.Prop("id").AsIDString();
        if (id is null) return null;
        var mainSong = dict.Prop("mainSong");
        var song = mainSong is { } main ? MapSong(main) : null;
        var durationMs = dict.Prop("duration").AsLong()
            ?? mainSong?.Prop("duration").AsLong()
            ?? 0;
        return new RadioProgram
        {
            Id = id,
            Title = dict.Prop("name").AsString() ?? song?.Title ?? "未命名节目",
            CoverURL = dict.Prop("coverImgUrl").AsString() ?? song?.CoverURL,
            Duration = durationMs / 1000.0,
            CreateTime = dict.Prop("createTime").AsLong() is { } createTime
                ? DateTimeOffset.FromUnixTimeMilliseconds(createTime)
                : null,
            PlayCount = dict.Prop("playCount").AsInt() ?? 0,
            StationName = stationName,
            Song = song,
        };
    }

    // MARK: - 网络请求基础

    internal async Task<byte[]> RequestAsync(
        string path,
        IReadOnlyDictionary<string, string>? query = null,
        string? cookie = null,
        TimeSpan? cacheTtl = null,
        string method = "GET",
        bool noteAuthRejection = true,
        CancellationToken ct = default)
    {
        var cacheKey = CacheKey(path, query, cookie);
        int generation;
        lock (_cacheGate)
        {
            generation = _responseCacheGeneration;
        }

        if (method == "GET" && cacheTtl is { TotalSeconds: > 0 } && TryGetCachedResponse(cacheKey, out var cached))
        {
            return cached!;
        }

        try
        {
            await HelperProcessManager.Shared.StartIfNeededAsync(ct).ConfigureAwait(false);
            var url = HelperProcessManager.Shared.MakeURL(path, query);
            using var request = new HttpRequestMessage(method == "POST" ? HttpMethod.Post : HttpMethod.Get, url);
            if (method == "POST")
            {
                request.Content = new FormUrlEncodedContent(Array.Empty<KeyValuePair<string, string>>());
            }
            HelperProcessManager.Shared.ApplyAuth(request);
            if (!string.IsNullOrEmpty(cookie))
            {
                request.Headers.TryAddWithoutValidation("X-CT-Cookie", cookie);
            }

            using var response = await _session.SendAsync(request, HttpCompletionOption.ResponseContentRead, ct)
                .ConfigureAwait(false);
            var status = (int)response.StatusCode;
            var data = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);

            if (status is 301 or 403)
            {
                if (noteAuthRejection) NoteSessionRejection();
                throw MusicException.ApiError(status, "网易云拒绝了这次请求（可能被风控），稍后重试");
            }
            if (status == 401) throw MusicException.HelperAuthFailed();
            if (status == 429) throw MusicException.RateLimited();
            if (status is < 200 or > 299) throw MusicException.ApiError(status, $"HTTP {status}");

            if (data.Length <= 64 * 1024 && IsAuthRejectionBody(data))
            {
                if (noteAuthRejection) NoteSessionRejection();
                throw MusicException.ApiError(301, "该接口要求重新登录后才能访问");
            }

            if (method == "GET" && cacheTtl is { TotalSeconds: > 0 } ttl)
            {
                CacheResponse(data, cacheKey, ttl, generation);
            }
            return data;
        }
        catch (MusicException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw MusicException.From(error);
        }
    }

    private static bool IsAuthRejectionBody(byte[] data)
    {
        try
        {
            var json = JsonSerializer.Deserialize<JsonElement>(data);
            return json.Prop("code").AsInt() == 301;
        }
        catch
        {
            return false;
        }
    }

    internal static JsonElement ParseJson(byte[] data)
    {
        try
        {
            return JsonSerializer.Deserialize<JsonElement>(data);
        }
        catch (JsonException)
        {
            throw MusicException.InvalidResponse();
        }
    }

    // MARK: - 会话失效判定

    private void NoteSessionRejection()
    {
        SessionGuardDecision decision;
        lock (_sessionGuard)
        {
            decision = _sessionGuard.NoteRejection();
        }
        if (decision == SessionGuardDecision.ProbeSession)
        {
            _ = Task.Run(ConfirmSessionWithProbeAsync);
        }
    }

    private async Task ConfirmSessionWithProbeAsync()
    {
        bool alive;
        try
        {
            var cookie = LoadLoginCookie();
            var data = await RequestAsync("/user/account", cookie: cookie, noteAuthRejection: false)
                .ConfigureAwait(false);
            var json = ParseJson(data);
            alive = json.Prop("account").Prop("id").HasValue();
        }
        catch
        {
            alive = false;
        }

        SessionGuardDecision decision;
        lock (_sessionGuard)
        {
            decision = _sessionGuard.ResolveProbe(alive);
        }

        switch (decision)
        {
            case SessionGuardDecision.SessionAlive:
                CTLog.General.Info("单接口返回 301/403，但 /user/account 探针正常 —— 判定为风控拒绝，保留登录态");
                break;
            case SessionGuardDecision.SessionExpired:
                CTLog.Security.Warn("/user/account 探针同样失败，判定会话确实失效");
                ClearCache();
                SessionExpired?.Invoke();
                break;
        }
    }

    // MARK: - 缓存维护

    internal static string CacheKey(string path, IReadOnlyDictionary<string, string>? query, string? cookie)
    {
        var queryPart = query is null
            ? ""
            : string.Join("&", query
                .OrderBy(pair => pair.Key, StringComparer.Ordinal)
                .Select(pair =>
                    $"{Encoding.UTF8.GetByteCount(pair.Key)}:{pair.Key}{Encoding.UTF8.GetByteCount(pair.Value)}:{pair.Value}"));
        string scope;
        if (!string.IsNullOrEmpty(cookie))
        {
            scope = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(cookie))).ToLowerInvariant();
        }
        else
        {
            scope = "anon";
        }
        return $"{path}?{queryPart}|{scope}";
    }

    private bool TryGetCachedResponse(string key, out byte[]? data)
    {
        lock (_cacheGate)
        {
            if (_responseCache.TryGetValue(key, out var entry) && entry.ExpiresAt > DateTime.UtcNow)
            {
                data = entry.Data;
                return true;
            }
        }
        data = null;
        return false;
    }

    private void CacheResponse(byte[] data, string key, TimeSpan ttl, int generation)
    {
        if (ttl <= TimeSpan.Zero) return;
        lock (_cacheGate)
        {
            if (generation != _responseCacheGeneration) return;
            if (_responseCache.TryGetValue(key, out var existing)) _responseCacheBytes -= existing.Data.Length;
            _responseCache[key] = new CacheEntry(data, DateTime.UtcNow + ttl);
            _responseCacheBytes += data.Length;
            EnforceResponseCacheLimits();
        }
    }

    private void PruneExpiredCache()
    {
        var now = DateTime.UtcNow;
        var expired = _responseCache.Where(pair => pair.Value.ExpiresAt <= now).Select(pair => pair.Key).ToList();
        foreach (var key in expired)
        {
            _responseCacheBytes -= _responseCache[key].Data.Length;
            _responseCache.Remove(key);
        }
        if (_responseCacheBytes < 0) _responseCacheBytes = 0;
    }

    private void EnforceResponseCacheLimits()
    {
        PruneExpiredCache();
        if (_responseCache.Count <= ResponseCacheEntryLimit && _responseCacheBytes <= ResponseCacheByteLimit) return;
        foreach (var pair in _responseCache.OrderBy(pair => pair.Value.ExpiresAt).ToList())
        {
            if (_responseCache.Count <= ResponseCacheEntryLimit && _responseCacheBytes <= ResponseCacheByteLimit) break;
            _responseCacheBytes -= pair.Value.Data.Length;
            _responseCache.Remove(pair.Key);
        }
    }

    public void InvalidateCache(IReadOnlyList<string> pathPrefixes)
    {
        lock (_cacheGate)
        {
            _responseCacheGeneration += 1;
            if (pathPrefixes.Any(prefix => prefix is "/playlist/track/all" or "/playlist/detail"))
            {
                lock (_playlistGate) _playlistTrackCache.Clear();
            }
            foreach (var prefix in pathPrefixes)
            {
                var hits = _responseCache.Keys
                    .Where(key =>
                    {
                        var path = PathOfCacheKey(key);
                        return path == prefix || path.StartsWith(prefix + "/", StringComparison.Ordinal);
                    })
                    .ToList();
                foreach (var key in hits)
                {
                    _responseCacheBytes -= _responseCache[key].Data.Length;
                    _responseCache.Remove(key);
                }
            }
            if (_responseCacheBytes < 0) _responseCacheBytes = 0;
        }
    }

    public void InvalidateCache(string pathPrefix) => InvalidateCache(new[] { pathPrefix });

    internal static string PathOfCacheKey(string key)
    {
        var cut = key.IndexOfAny(new[] { '?', '|' });
        return cut < 0 ? key : key[..cut];
    }

    public void ClearCache()
    {
        lock (_cacheGate)
        {
            _responseCacheGeneration += 1;
            _responseCache.Clear();
            _responseCacheBytes = 0;
        }
        lock (_reachGate) _reachCache.Clear();
        lock (_playlistGate) _playlistTrackCache.Clear();
    }

    // MARK: - 模型映射

    public static string LikeFailureMessage(JsonElement json)
    {
        var code = json.Prop("code").AsInt() ?? -1;
        var serverText = json.Prop("message").AsString() ?? json.Prop("msg").AsString();
        return code switch
        {
            405 or 524 => $"{serverText ?? "被网易云限流"}。这是账号级限流，连点只会让等待更久，请 {ClearToneConstants.LikeWriteCooldownSeconds} 秒后再试一次",
            _ => serverText ?? "操作失败",
        };
    }

    public static Song? MapSong(JsonElement dict)
    {
        var id = dict.Prop("id").AsIDString();
        if (id is null) return null;
        var title = dict.Prop("name").AsString() ?? "未知歌曲";

        var artists = (dict.Prop("ar").AsArray() ?? dict.Prop("artists").AsArray())
            ?.Select(MapArtist).ToList() ?? new List<Artist>();

        Album? album = null;
        if (dict.Prop("al") is { } al) album = MapAlbum(al);
        else if (dict.Prop("album") is { } albumDict) album = MapAlbum(albumDict);

        var duration = (dict.Prop("dt").AsDouble() ?? dict.Prop("duration").AsDouble() ?? 0) / 1000.0;
        var coverURL = dict.Prop("al").Prop("picUrl").AsString()
            ?? dict.Prop("album").Prop("picUrl").AsString()
            ?? dict.Prop("picUrl").AsString();

        var st = dict.Prop("st").AsInt() ?? 0;
        var isPlayable = st >= 0;

        return new Song
        {
            Id = id,
            Title = title,
            Artists = artists,
            Album = album,
            Duration = duration,
            CoverURL = coverURL,
            IsPlayable = isPlayable,
            UnavailableReason = isPlayable ? null : "歌曲已下架",
            Source = SongSource.Netease,
        };
    }

    public static Artist MapArtist(JsonElement dict)
    {
        var id = dict.Prop("id").AsIDString() ?? "0";
        var name = dict.Prop("name").AsString() ?? "未知歌手";
        var avatarURL = dict.Prop("picUrl").AsString()
            ?? dict.Prop("img1v1Url").AsString()
            ?? dict.Prop("cover").AsString()
            ?? dict.Prop("avatar").AsString();
        var alias = dict.Prop("alias").AsArray()?.Select(element => element.AsString() ?? "").ToList()
            ?? dict.Prop("transNames").AsArray()?.Select(element => element.AsString() ?? "").ToList()
            ?? new List<string>();
        return new Artist { Id = id, Name = name, AvatarURL = avatarURL, Alias = alias };
    }

    public static Album MapAlbum(JsonElement dict)
    {
        return new Album
        {
            Id = dict.Prop("id").AsIDString() ?? "0",
            Name = dict.Prop("name").AsString() ?? "未知专辑",
            CoverURL = dict.Prop("picUrl").AsString(),
        };
    }

    public static Playlist MapPlaylist(JsonElement dict)
    {
        return new Playlist
        {
            Id = dict.Prop("id").AsIDString() ?? "0",
            Name = dict.Prop("name").AsString() ?? "未知歌单",
            CoverURL = dict.Prop("coverImgUrl").AsString() ?? dict.Prop("picUrl").AsString(),
            TrackCount = dict.Prop("trackCount").AsInt() ?? 0,
            CreatorName = dict.Prop("creator").Prop("nickname").AsString(),
            DescriptionText = dict.Prop("description").AsString(),
            IsSubscribed = dict.Prop("subscribed").AsBool() ?? false,
            Source = SongSource.Netease,
        };
    }

    public static string? CodecName(string? encodeType, Uri? url)
    {
        var raw = string.IsNullOrWhiteSpace(encodeType) ? null : encodeType.Trim();
        var token = raw ?? (url is null ? null : Path.GetExtension(url.AbsolutePath).TrimStart('.'));
        if (string.IsNullOrEmpty(token)) return null;
        return token.ToLowerInvariant() switch
        {
            "mp3" => "MP3",
            "aac" or "m4a" or "m4b" => "AAC",
            "flac" => "FLAC",
            "alac" => "ALAC",
            "opus" => "OPUS",
            "wav" or "wave" => "WAV",
            _ => token.ToUpperInvariant(),
        };
    }
}
