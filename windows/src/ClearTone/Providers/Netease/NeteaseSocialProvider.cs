using System.Text.Json;
using ClearTone.Core.Models;
using ClearTone.Core.Security;

namespace ClearTone.Providers.Netease;

public sealed partial class NeteaseProvider : IMusicSocialProvider
{
    private static void RequireWriteSucceeded(JsonElement json, string action)
    {
        var code = json.Prop("code").AsInt();
        if (code is null) throw MusicException.InvalidResponse();
        if (code != 200)
        {
            var message = json.Prop("msg").AsString() ?? json.Prop("message").AsString() ?? "未知错误";
            throw MusicException.ApiError(code.Value, $"{action}失败：{message}");
        }
    }

    private static string RequireLoginCookie()
    {
        var cookie = LoadLoginCookie();
        if (string.IsNullOrEmpty(cookie)) throw MusicException.NotLoggedIn();
        return cookie;
    }

    public async Task SubscribePlaylistAsync(string id, bool subscribe, CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var json = ParseJson(await RequestAsync("/playlist/subscribe", new Dictionary<string, string>
        {
            ["id"] = id,
            ["t"] = subscribe ? "1" : "0",
        }, cookie, method: "POST", ct: ct).ConfigureAwait(false));
        RequireWriteSucceeded(json, subscribe ? "收藏歌单" : "取消收藏");
        InvalidateCache(new[] { "/playlist/detail", "/playlist/track/all", "/user/playlist" });
    }

    public async Task<Playlist> CreatePlaylistAsync(string name, bool isPrivate, CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var trimmed = name.Trim();
        if (trimmed.Length == 0) throw MusicException.InvalidResponse();
        var json = ParseJson(await RequestAsync("/playlist/create", new Dictionary<string, string>
        {
            ["name"] = trimmed,
            ["privacy"] = isPrivate ? "10" : "0",
            ["type"] = "NORMAL",
        }, cookie, method: "POST", ct: ct).ConfigureAwait(false));
        RequireWriteSucceeded(json, "创建歌单");
        var playlist = json.Prop("playlist");
        if (playlist is null) throw MusicException.InvalidResponse();
        InvalidateCache("/user/playlist");
        return MapPlaylist(playlist.Value);
    }

    public async Task DeletePlaylistAsync(string id, CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var ids = id.Split(',', StringSplitOptions.RemoveEmptyEntries);
        if (ids.Length == 0 || ids.Any(part => !part.All(char.IsDigit)))
        {
            throw MusicException.InvalidResponse();
        }
        var json = ParseJson(await RequestAsync("/playlist/delete", new Dictionary<string, string>
        {
            ["id"] = string.Join(",", ids),
        }, cookie, method: "POST", ct: ct).ConfigureAwait(false));
        RequireWriteSucceeded(json, "删除歌单");
        InvalidateCache(new[] { "/user/playlist", "/playlist/detail" });
    }

    public async Task UpdatePlaylistNameAsync(string id, string name, CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var trimmed = name.Trim();
        if (trimmed.Length == 0) throw MusicException.InvalidResponse();
        var json = ParseJson(await RequestAsync("/playlist/name/update", new Dictionary<string, string>
        {
            ["id"] = id,
            ["name"] = trimmed,
        }, cookie, method: "POST", ct: ct).ConfigureAwait(false));
        RequireWriteSucceeded(json, "重命名歌单");
        InvalidateCache(new[] { "/user/playlist", "/playlist/detail" });
    }

    public Task AddSongsToPlaylistAsync(string playlistID, IReadOnlyList<string> songIDs, CancellationToken ct = default) =>
        ManipulatePlaylistTracksAsync("add", playlistID, songIDs, ct);

    public Task RemoveSongsFromPlaylistAsync(string playlistID, IReadOnlyList<string> songIDs, CancellationToken ct = default) =>
        ManipulatePlaylistTracksAsync("del", playlistID, songIDs, ct);

    private async Task ManipulatePlaylistTracksAsync(string op, string playlistID, IReadOnlyList<string> songIDs, CancellationToken ct)
    {
        var cookie = RequireLoginCookie();
        var ids = songIDs.Where(songID => !string.IsNullOrEmpty(songID)).ToList();
        if (ids.Count == 0) return;
        var json = ParseJson(await RequestAsync("/playlist/tracks", new Dictionary<string, string>
        {
            ["op"] = op,
            ["pid"] = playlistID,
            ["tracks"] = string.Join(",", ids),
            ["imme"] = "true",
        }, cookie, method: "POST", ct: ct).ConfigureAwait(false));
        RequireWriteSucceeded(json, op == "add" ? "添加到歌单" : "从歌单移除");
        InvalidateCache(new[] { "/playlist/detail", "/playlist/track/all", "/user/playlist" });
    }

    public Task SubscribeAlbumAsync(string id, bool subscribe, CancellationToken ct = default) =>
        ToggleSubAsync("/album/sub", id, subscribe, "专辑", "id", ct);

    public Task SubscribeArtistAsync(string id, bool subscribe, CancellationToken ct = default) =>
        ToggleSubAsync("/artist/sub", id, subscribe, "歌手", "id", ct);

    public Task SubscribeRadioAsync(string id, bool subscribe, CancellationToken ct = default) =>
        ToggleSubAsync("/dj/sub", id, subscribe, "电台", "rid", ct);

    private async Task ToggleSubAsync(string route, string id, bool subscribe, string action, string queryKey, CancellationToken ct)
    {
        var cookie = RequireLoginCookie();
        var json = ParseJson(await RequestAsync(route, new Dictionary<string, string>
        {
            [queryKey] = id,
            ["t"] = subscribe ? "1" : "0",
        }, cookie, method: "POST", ct: ct).ConfigureAwait(false));
        RequireWriteSucceeded(json, subscribe ? $"收藏{action}" : $"取消收藏{action}");
        InvalidateCache(new[] { "/album", "/artist", "/dj", "/user/playlist" });
    }

    public async Task<List<Playlist>> FetchSubscribedPlaylistsAsync(int limit = 50, CancellationToken ct = default)
    {
        var userID = RequireUserID();
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/user/playlist", new Dictionary<string, string>
        {
            ["uid"] = userID,
            ["limit"] = limit.ToString(),
            ["offset"] = "0",
        }, cookie, TimeSpan.FromSeconds(120), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var list = json.Prop("playlist").AsArray();
        if (list is null) throw MusicException.InvalidResponse();
        return list.Select(dict =>
        {
            var playlist = MapPlaylist(dict);
            playlist.IsSubscribed = (dict.Prop("subCount").AsInt() ?? 0) > 0;
            return playlist;
        }).ToList();
    }

    public async Task<List<Album>> FetchSubscribedAlbumsAsync(int limit = 50, CancellationToken ct = default)
    {
        var userID = RequireUserID();
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/album/sublist", new Dictionary<string, string>
        {
            ["uid"] = userID,
            ["limit"] = limit.ToString(),
        }, cookie, TimeSpan.FromSeconds(300), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var albums = json.Prop("data").AsArray();
        if (albums is null) throw MusicException.InvalidResponse();
        return albums.Select(MapAlbum).ToList();
    }

    public async Task<List<Artist>> FetchSubscribedArtistsAsync(int limit = 50, CancellationToken ct = default)
    {
        var userID = RequireUserID();
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/artist/sublist", new Dictionary<string, string>
        {
            ["uid"] = userID,
            ["limit"] = limit.ToString(),
        }, cookie, TimeSpan.FromSeconds(300), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var artists = json.Prop("data").AsArray();
        if (artists is null) throw MusicException.InvalidResponse();
        return artists.Select(MapArtist).ToList();
    }

    public async Task<RadioStation> FetchRadioStationDetailAsync(string radioID, CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie();
        var data = await RequestAsync("/dj/detail", new Dictionary<string, string>
        {
            ["rid"] = radioID,
        }, cookie, TimeSpan.FromSeconds(600), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var dict = json.Prop("data");
        if (dict is null) throw MusicException.InvalidResponse();
        var station = MapRadioStation(NormalizeRadioStationJson(dict.Value, markSubscribed: false));
        if (station is null) throw MusicException.InvalidResponse();
        return station;
    }

    public async Task<List<RadioStation>> FetchSubscribedRadiosAsync(int limit = 30, CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/dj/sublist", new Dictionary<string, string>
        {
            ["limit"] = limit.ToString(),
            ["offset"] = "0",
        }, cookie, TimeSpan.FromSeconds(300), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var radios = json.Prop("djRadios").AsArray();
        if (radios is null) throw MusicException.InvalidResponse();
        return radios
            .Select(raw => MapRadioStation(NormalizeRadioStationJson(raw, markSubscribed: true)))
            .Where(station => station is not null)
            .Select(station => station!)
            .ToList();
    }

    private static JsonElement NormalizeRadioStationJson(JsonElement dict, bool markSubscribed)
    {
        var patchPic = dict.Prop("picUrl") is null && dict.Prop("pic").AsString() is not null;
        if (!patchPic && !markSubscribed) return dict;
        var map = new Dictionary<string, JsonElement>();
        foreach (var property in dict.EnumerateObject()) map[property.Name] = property.Value.Clone();
        if (patchPic) map["picUrl"] = JsonSerializer.SerializeToElement(dict.Prop("pic").AsString());
        if (markSubscribed) map["isSub"] = JsonSerializer.SerializeToElement(1);
        return JsonSerializer.SerializeToElement(map);
    }

    public async Task<List<TopList>> FetchTopListsAsync(CancellationToken ct = default)
    {
        var data = await RequestAsync("/toplist", cacheTtl: TimeSpan.FromSeconds(3600), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var list = json.Prop("list").AsArray();
        if (list is null) throw MusicException.InvalidResponse();
        var result = new List<TopList>();
        foreach (var dict in list)
        {
            var id = dict.Prop("id").AsIDString();
            if (id is null) continue;
            result.Add(new TopList
            {
                Id = id,
                Name = dict.Prop("name").AsString() ?? "未命名榜单",
                CoverURL = dict.Prop("coverImgUrl").AsString(),
                UpdateFrequency = dict.Prop("updateFrequency").AsString(),
                TrackCount = dict.Prop("trackCount").AsInt() ?? 0,
                PlayCount = dict.Prop("playCount").AsInt() ?? 0,
                DescriptionText = dict.Prop("description").AsString(),
                IconURL = dict.Prop("icon").AsString() ?? dict.Prop("backgroundImageUrl").AsString(),
            });
        }
        return result;
    }

    public async Task<List<Song>> FetchTopSongsAsync(TopSongArea area, CancellationToken ct = default)
    {
        var data = await RequestAsync("/top/song", new Dictionary<string, string>
        {
            ["type"] = area.AreaID().ToString(),
            ["total"] = "true",
        }, cacheTtl: TimeSpan.FromSeconds(600), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var songs = json.Prop("data").Prop("songsData").AsArray();
        if (songs is null) throw MusicException.InvalidResponse();
        return songs.CompactMap(MapSong);
    }

    public async Task<List<Playlist>> FetchHotPlaylistsAsync(
        string? category,
        TopPlaylistOrder order,
        int limit,
        int offset,
        CancellationToken ct = default)
    {
        var query = new Dictionary<string, string>
        {
            ["order"] = order.ApiValue(),
            ["limit"] = limit.ToString(),
            ["offset"] = offset.ToString(),
            ["total"] = "true",
            ["cat"] = string.IsNullOrEmpty(category) ? "全部" : category!,
        };
        var data = await RequestAsync("/top/playlist", query, cacheTtl: TimeSpan.FromSeconds(300), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var playlists = json.Prop("playlists").AsArray();
        if (playlists is null) throw MusicException.InvalidResponse();
        return playlists.Select(MapPlaylist).ToList();
    }

    public async Task<List<PlaylistCategoryGroup>> FetchPlaylistCategoriesAsync(CancellationToken ct = default)
    {
        var data = await RequestAsync("/playlist/catlist", cacheTtl: TimeSpan.FromSeconds(3600), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var categories = json.Prop("categories");
        if (categories is not { ValueKind: JsonValueKind.Object }) throw MusicException.InvalidResponse();
        var groups = new List<PlaylistCategoryGroup>();
        foreach (var property in categories.Value.EnumerateObject())
        {
            var raw = property.Value.AsArray();
            if (raw is null || raw.Count == 0) continue;
            var values = new List<string>();
            var valid = true;
            foreach (var element in raw)
            {
                var text = element.AsString();
                if (text is null)
                {
                    valid = false;
                    break;
                }
                values.Add(text);
            }
            if (!valid) continue;
            groups.Add(new PlaylistCategoryGroup { Name = property.Name, Categories = values });
        }
        return groups.OrderBy(group => CategoryGroupOrder(group.Name)).ToList();
    }

    private static int CategoryGroupOrder(string name)
    {
        var order = new[] { "语种", "风格", "场景", "情感", "主题" };
        var index = Array.IndexOf(order, name);
        return index < 0 ? order.Length : index;
    }

    public async Task<List<string>> FetchHotPlaylistTagsAsync(CancellationToken ct = default)
    {
        var data = await RequestAsync("/playlist/hot", cacheTtl: TimeSpan.FromSeconds(3600), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var tags = json.Prop("tags").AsArray();
        if (tags is null) throw MusicException.InvalidResponse();
        return tags.CompactMap(element => element.Prop("name").AsString());
    }

    public async Task<List<Song>> FetchPersonalFMAsync(CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/personal_fm", cookie: cookie, ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var songs = json.Prop("data").AsArray();
        if (songs is null) throw MusicException.InvalidResponse();
        return songs.CompactMap(MapSong);
    }

    public async Task<List<Playlist>> FetchDailyRecommendPlaylistsAsync(CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/recommend/resource", cookie: cookie, cacheTtl: TimeSpan.FromSeconds(300), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var list = json.Prop("recommend").AsArray();
        if (list is null) throw MusicException.InvalidResponse();
        return list.Select(MapPlaylist).ToList();
    }

    public async Task<List<Song>> FetchNewSongsAsync(int limit = 30, CancellationToken ct = default)
    {
        var data = await RequestAsync("/personalized/newsong", new Dictionary<string, string>
        {
            ["type"] = "recommend",
            ["limit"] = limit.ToString(),
            ["areaId"] = "0",
        }, cacheTtl: TimeSpan.FromSeconds(600), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var list = json.Prop("result").AsArray();
        if (list is null) throw MusicException.InvalidResponse();
        return list.CompactMap(MapSong);
    }

    public async Task<List<Album>> FetchNewAlbumsAsync(int limit = 30, CancellationToken ct = default)
    {
        var data = await RequestAsync("/album/newest", cacheTtl: TimeSpan.FromSeconds(600), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var albums = json.Prop("albums").AsArray();
        if (albums is null) throw MusicException.InvalidResponse();
        return albums.Take(Math.Max(1, limit)).Select(MapAlbum).ToList();
    }

    public async Task<List<Song>> FetchSimilarSongsAsync(string songID, int limit = 30, CancellationToken ct = default)
    {
        var data = await RequestAsync("/simi/song", new Dictionary<string, string>
        {
            ["id"] = songID,
            ["limit"] = limit.ToString(),
            ["offset"] = "0",
        }, cacheTtl: TimeSpan.FromSeconds(600), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var songs = json.Prop("songs").AsArray();
        if (songs is null) throw MusicException.InvalidResponse();
        return songs.CompactMap(MapSong);
    }

    public async Task<List<Artist>> FetchSimilarArtistsAsync(string artistID, CancellationToken ct = default)
    {
        var data = await RequestAsync("/simi/artist", new Dictionary<string, string>
        {
            ["id"] = artistID,
        }, cacheTtl: TimeSpan.FromSeconds(600), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var artists = json.Prop("artists").AsArray() ?? json.Prop("data").AsArray();
        if (artists is null) throw MusicException.InvalidResponse();
        return artists.Select(MapArtist).ToList();
    }

    public async Task<Song?> DislikeDailyRecommendAsync(string songID, CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var json = ParseJson(await RequestAsync("/recommend/songs/dislike", new Dictionary<string, string>
        {
            ["id"] = songID,
        }, cookie, method: "POST", ct: ct).ConfigureAwait(false));
        RequireWriteSucceeded(json, "反馈不喜欢");
        InvalidateCache("/recommend/songs");
        var replacement = json.Prop("data");
        return replacement is null ? null : MapSong(replacement.Value);
    }

    public async Task<List<SearchSuggestion>> FetchSearchSuggestionsAsync(string keyword, CancellationToken ct = default)
    {
        var trimmed = keyword.Trim();
        if (trimmed.Length == 0) return new List<SearchSuggestion>();
        var data = await RequestAsync("/search/suggest", new Dictionary<string, string>
        {
            ["keywords"] = trimmed,
        }, ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var result = json.Prop("result");
        if (result is null) return new List<SearchSuggestion>();
        var output = new List<SearchSuggestion>();
        var sections = new (string Key, SearchSuggestion.Kind Kind)[]
        {
            ("songs", SearchSuggestion.Kind.Song),
            ("artists", SearchSuggestion.Kind.Artist),
            ("albums", SearchSuggestion.Kind.Album),
            ("playlists", SearchSuggestion.Kind.Playlist),
        };
        foreach (var (key, kind) in sections)
        {
            var items = result.Value.Prop(key).AsArray();
            if (items is null) continue;
            foreach (var item in items.Take(5))
            {
                var id = item.Prop("id").AsIDString();
                if (id is null) continue;
                output.Add(new SearchSuggestion
                {
                    SuggestionKind = kind,
                    Title = item.Prop("name").AsString() ?? "",
                    Subtitle = SuggestionSubtitle(item, kind),
                    CoverURL = item.Prop("picUrl").AsString(),
                    TargetID = id,
                });
            }
        }
        return output;
    }

    private static string? SuggestionSubtitle(JsonElement dict, SearchSuggestion.Kind kind)
    {
        var names = dict.Prop("artists").AsArray()?
            .CompactMap(element => element.Prop("name").AsString()) ?? new List<string>();
        switch (kind)
        {
            case SearchSuggestion.Kind.Song:
                if (names.Count == 0) return null;
                var total = (int)((dict.Prop("duration").AsDouble() ?? 0) / 1000);
                return $"{string.Join(" / ", names)} · {total / 60}:{total % 60:D2}";
            case SearchSuggestion.Kind.Artist:
                var size = dict.Prop("albumSize").AsInt();
                return size is null ? null : $"{size} 张专辑";
            case SearchSuggestion.Kind.Album:
                if (names.Count == 0) return null;
                return string.Join(" / ", names);
            default:
                var count = dict.Prop("trackCount").AsInt();
                return count is null ? null : $"{count} 首";
        }
    }

    public async Task<List<HotSearchTerm>> FetchHotSearchTermsAsync(CancellationToken ct = default)
    {
        var data = await RequestAsync("/search/hot", cacheTtl: TimeSpan.FromSeconds(1800), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var dict = json.Prop("result");
        var hots = dict.Prop("hots").AsArray();
        if (dict is null || hots is null) throw MusicException.InvalidResponse();
        var terms = new List<HotSearchTerm>();
        foreach (var item in hots)
        {
            var keyword = item.Prop("first").AsString() ?? "";
            if (keyword.Length == 0) continue;
            terms.Add(new HotSearchTerm
            {
                Keyword = keyword,
                Score = item.Prop("second").AsInt() ?? 0,
                DisplayPrefix = HotSearchIconLabel(item.Prop("iconType").AsInt() ?? 0),
                Icon = null,
            });
        }
        return terms;
    }

    private static string? HotSearchIconLabel(int type) => type switch
    {
        1 => "新",
        2 => "沸",
        _ => null,
    };

    public async Task<CommentPage> FetchCommentsAsync(
        string songID,
        CommentSort sort,
        int page,
        int pageSize = 20,
        string? cursor = null,
        CancellationToken ct = default)
    {
        var cookie = LoadLoginCookie();
        var data = await RequestAsync("/comment/new", CommentQuery(songID, sort, page, pageSize, cursor), cookie,
            sort == CommentSort.Newest ? TimeSpan.Zero : TimeSpan.FromSeconds(60), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var myID = CredentialStore.Shared.Load(CredentialKey.NeteaseUserID);
        return MapCommentPage(json, myID);
    }

    internal static Dictionary<string, string> CommentQuery(
        string songID, CommentSort sort, int page, int pageSize, string? cursor)
    {
        var query = new Dictionary<string, string>
        {
            ["id"] = songID,
            ["type"] = "0",
            ["sortType"] = sort.ApiValue().ToString(),
            ["pageNo"] = Math.Max(1, page).ToString(),
            ["pageSize"] = Math.Max(1, pageSize).ToString(),
        };
        if (sort == CommentSort.Newest && page > 1 && cursor is not null) query["cursor"] = cursor;
        return query;
    }

    internal static CommentPage MapCommentPage(JsonElement json, string? myID)
    {
        var body = json.Prop("data");
        var list = body.Prop("comments").AsArray();
        if (body is null || list is null) throw MusicException.InvalidResponse();
        var comments = new List<Comment>();
        foreach (var item in list)
        {
            var id = item.Prop("commentId") ?? item.Prop("id");
            if (id is null) continue;
            var user = item.Prop("user");
            var userID = (user.Prop("userId") ?? item.Prop("userId")).AsIDString() ?? "";
            var replied = item.Prop("beReplied").AsArray()?.FirstOrDefault();
            comments.Add(new Comment
            {
                Id = id.Value.AsIDString() ?? "",
                Content = item.Prop("content").AsString() ?? "",
                UserID = userID,
                Nickname = user.Prop("nickname").AsString() ?? "匿名用户",
                AvatarURL = user.Prop("avatarUrl").AsString(),
                Time = DateFromMilliseconds(item.Prop("time")),
                LikedCount = item.Prop("likedCount").AsInt() ?? 0,
                IsLiked = item.Prop("liked").AsBool() ?? false,
                ReplyCount = item.Prop("replyCount").AsInt() ?? 0,
                ReplyToNickname = replied.Prop("user").Prop("nickname").AsString(),
                ReplyToContent = replied.Prop("content").AsString(),
                IsMine = myID is not null && userID == myID,
            });
        }
        return new CommentPage
        {
            Comments = comments,
            Total = body.Value.Prop("totalCount").AsInt() ?? comments.Count,
            HasMore = body.Value.Prop("hasMore").AsBool() ?? false,
            NextCursor = list.Count > 0 ? list[^1].Prop("time").AsIDString() : null,
        };
    }

    internal static Dictionary<string, string> CommentLikeQuery(string songID, string commentID, bool like) =>
        new()
        {
            ["id"] = songID,
            ["cid"] = commentID,
            ["type"] = "0",
            ["t"] = like ? "1" : "0",
        };

    public async Task LikeCommentAsync(string songID, string commentID, bool like, CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var json = ParseJson(await RequestAsync("/comment/like", CommentLikeQuery(songID, commentID, like),
            cookie, method: "POST", ct: ct).ConfigureAwait(false));
        RequireWriteSucceeded(json, like ? "点赞评论" : "取消点赞");
        InvalidateCache(new[] { "/comment/new", "/comment/music" });
    }

    public async Task<List<UserNotice>> FetchNoticesAsync(int limit = 30, CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/msg/notices", new Dictionary<string, string>
        {
            ["limit"] = limit.ToString(),
            ["lasttime"] = "-1",
        }, cookie, TimeSpan.FromSeconds(60), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var list = json.Prop("notices").AsArray();
        if (list is null) throw MusicException.InvalidResponse();
        var notices = new List<UserNotice>();
        foreach (var item in list)
        {
            var id = item.Prop("id").AsIDString();
            if (id is null) continue;
            var user = item.Prop("user");
            notices.Add(new UserNotice
            {
                Id = id,
                Kind = UserNoticeKind.FromTypeCode(item.Prop("type").AsInt() ?? 0),
                Time = DateFromMilliseconds(item.Prop("time")),
                ActorNickname = user.Prop("nickname").AsString(),
                ActorAvatarURL = user.Prop("avatarUrl").AsString(),
                Content = item.Prop("msg").AsString(),
                ReplyCommentText = item.Prop("replyCommentText").AsString(),
                RelatedID = item.Prop("relatedId").AsIDString(),
            });
        }
        return notices;
    }

    public async Task<List<PrivateConversation>> FetchPrivateConversationsAsync(
        int limit = 30, int offset = 0, CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/msg/private", new Dictionary<string, string>
        {
            ["limit"] = limit.ToString(),
            ["offset"] = offset.ToString(),
            ["total"] = "true",
        }, cookie, TimeSpan.FromSeconds(60), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var list = json.Prop("msgs").AsArray()
            ?? json.Prop("data").AsArray()
            ?? json.Prop("users").AsArray()
            ?? new List<JsonElement>();
        var myID = CredentialStore.Shared.Load(CredentialKey.NeteaseUserID);
        var conversations = new List<PrivateConversation>();
        foreach (var item in list)
        {
            var user = item.Prop("user");
            var peerID = (user.Prop("id") ?? user.Prop("fromUserId")).AsIDString();
            if (peerID is null) continue;
            var peerProfile = PeerProfile(item, myID);
            var peerIDString = peerProfile.Prop("id").AsIDString() ?? peerID;
            conversations.Add(new PrivateConversation
            {
                Id = (item.Prop("lastMsgId") ?? user.Prop("id")).AsIDString() ?? peerID,
                UserID = peerIDString,
                Nickname = peerProfile.Prop("nickname").AsString() ?? "未知用户",
                AvatarURL = peerProfile.Prop("avatarUrl").AsString(),
                LastMessage = DecodeNestedLastMessage(item.Prop("lastMsg").AsString()),
                LastTime = DateFromMilliseconds(item.Prop("lastMsgTime") ?? user.Prop("lastMsgTime")),
                UnreadCount = (item.Prop("newMsgCount") ?? user.Prop("newMsgCount")).AsInt() ?? 0,
            });
        }
        return conversations;
    }

    internal static JsonElement? PeerProfile(JsonElement item, string? myID)
    {
        var user = item.Prop("user");
        var from = item.Prop("fromUser");
        var to = item.Prop("toUser");
        var pair = new List<JsonElement>();
        if (IsNonEmptyObject(from)) pair.Add(from!.Value);
        if (IsNonEmptyObject(to)) pair.Add(to!.Value);
        foreach (var candidate in pair)
        {
            var candidateID = candidate.Prop("id").AsIDString();
            if (candidateID is not null && candidateID != myID) return candidate;
        }
        var peerIDString = (user.Prop("id") ?? user.Prop("fromUserId")).AsIDString();
        if (peerIDString is not null && peerIDString == myID)
        {
            return pair.Count > 0 ? pair[^1] : user;
        }
        return pair.Count > 0 ? pair[0] : user;
    }

    private static bool IsNonEmptyObject(JsonElement? element) =>
        element is { ValueKind: JsonValueKind.Object } value && value.EnumerateObject().Any();

    private static string? DecodeNestedLastMessage(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return null;
        try
        {
            var inner = JsonSerializer.Deserialize<JsonElement>(raw);
            var text = inner.Prop("msg").AsString();
            if (!string.IsNullOrEmpty(text)) return text;
        }
        catch (JsonException)
        {
        }
        return raw;
    }

    public async Task<List<PrivateMessage>> FetchPrivateMessagesAsync(
        string userID, int limit = 30, CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/msg/private/history", new Dictionary<string, string>
        {
            ["uid"] = userID,
            ["limit"] = limit.ToString(),
            ["before"] = "0",
            ["total"] = "true",
        }, cookie, TimeSpan.Zero, ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var list = json.Prop("msgs").AsArray();
        if (list is null) throw MusicException.InvalidResponse();
        var myID = CredentialStore.Shared.Load(CredentialKey.NeteaseUserID);
        var messages = new List<PrivateMessage>();
        foreach (var item in list)
        {
            var inner = item.Prop("msg");
            var text = inner.Prop("content").AsString() ?? "";
            if (text.Length == 0) continue;
            var id = inner.Prop("id") ?? item.Prop("id");
            if (id is null) continue;
            var from = (inner.Prop("fromUserId") ?? item.Prop("fromUserId")).AsIDString() ?? "";
            var sender = item.Prop("sender") ?? item.Prop("user");
            messages.Add(new PrivateMessage
            {
                Id = id.Value.AsIDString() ?? "",
                Kind = PrivateMessageKind.FromMsgType(
                    inner.Prop("msgType").AsInt() ?? item.Prop("msgType").AsInt() ?? 1),
                Content = text,
                Time = DateFromMilliseconds(inner.Prop("time") ?? item.Prop("time")),
                IsOutgoing = myID == from && from.Length > 0,
                SenderNickname = sender.Prop("nickname").AsString(),
            });
        }
        return messages;
    }

    public async Task<List<MyComment>> FetchMyCommentsAsync(int limit = 30, CancellationToken ct = default)
    {
        var userID = RequireUserID();
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/msg/comments", new Dictionary<string, string>
        {
            ["uid"] = userID,
            ["limit"] = limit.ToString(),
            ["before"] = "-1",
        }, cookie, TimeSpan.FromSeconds(60), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var list = json.Prop("comments").AsArray();
        if (list is null) throw MusicException.InvalidResponse();
        var comments = new List<MyComment>();
        foreach (var item in list)
        {
            var replied = item.Prop("beReplied").AsArray()?.FirstOrDefault();
            var commentID = AnyValue(item.Prop("commentId"));
            if (commentID is null) continue;
            var resourceKindValue = IntValue(item.Prop("type")) ?? 0;
            var resourceKind = Enum.IsDefined(typeof(MyCommentResourceKind), resourceKindValue)
                ? (MyCommentResourceKind)resourceKindValue
                : MyCommentResourceKind.Song;
            comments.Add(new MyComment
            {
                Id = commentID,
                Content = item.Prop("content").AsString() ?? "",
                Time = DateFromMilliseconds(item.Prop("time")),
                LikedCount = IntValue(item.Prop("likedCount")) ?? 0,
                ResourceKind = resourceKind,
                ResourceID = AnyValue(item.Prop("id")),
                ReplyCount = IntValue(item.Prop("replyCount")) ?? 0,
                RepliedNickname = replied.Prop("user").Prop("nickname").AsString(),
                RepliedContent = replied.Prop("content").AsString(),
            });
        }
        return comments;
    }

    public async Task<UserLevelInfo> FetchUserLevelAsync(CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/user/level", cookie: cookie, cacheTtl: TimeSpan.FromSeconds(300), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var dict = json.Prop("data");
        if (dict is null) throw MusicException.InvalidResponse();
        return new UserLevelInfo
        {
            Level = dict.Value.Prop("level").AsInt() ?? 0,
            ListenSongs = dict.Value.Prop("listenSongs").AsInt() ?? 0,
            ListenDays = dict.Value.Prop("listenDays").AsInt() ?? 0,
            CurrentLoginDays = dict.Value.Prop("currentLoginDays").AsInt() ?? 0,
            NextLevelNeedLoginDays = dict.Value.Prop("nextLevelNeedLoginDays").AsInt() ?? 0,
            NextLevelNeedListenSongs = dict.Value.Prop("nextLevelNeedListenSongs").AsInt() ?? 0,
            CurrentProgress = dict.Value.Prop("currentProgress").AsInt() ?? 0,
        };
    }

    public async Task<List<ListenRecord>> FetchListenRecordsAsync(bool weekly, CancellationToken ct = default)
    {
        var userID = RequireUserID();
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/user/record", new Dictionary<string, string>
        {
            ["uid"] = userID,
            ["type"] = weekly ? "1" : "0",
        }, cookie, TimeSpan.FromSeconds(300), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        var list = json.Prop(weekly ? "weekData" : "allData").AsArray() ?? new List<JsonElement>();
        var records = new List<ListenRecord>();
        foreach (var item in list)
        {
            var songDict = item.Prop("song");
            if (songDict is null) continue;
            var song = MapSong(songDict.Value);
            if (song is null) continue;
            records.Add(new ListenRecord
            {
                Song = song,
                PlayCount = item.Prop("score").AsInt() ?? item.Prop("count").AsInt() ?? 0,
                LastPlayedAt = DateFromMilliseconds(item.Prop("playTime")),
            });
        }
        return records.OrderByDescending(record => record.LastPlayedAt ?? DateTimeOffset.MinValue).ToList();
    }

    public async Task<SignInResult> DailySignInAsync(CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var json = ParseJson(await RequestAsync("/daily_signin", new Dictionary<string, string>
        {
            ["type"] = "0",
        }, cookie, method: "POST", ct: ct).ConfigureAwait(false));
        if (json.Prop("code").AsInt() == -2) return new SignInResult.AlreadySigned();
        RequireWriteSucceeded(json, "打卡");
        return new SignInResult.Success(json.Prop("point").AsInt() ?? 0);
    }

    public async Task<Dictionary<string, int>> FetchUserCountsAsync(CancellationToken ct = default)
    {
        var cookie = RequireLoginCookie();
        var data = await RequestAsync("/user/subcount", cookie: cookie, cacheTtl: TimeSpan.FromSeconds(300), ct: ct).ConfigureAwait(false);
        var json = ParseJson(data);
        if (json.Prop("code") is null) throw MusicException.InvalidResponse();
        return new Dictionary<string, int>
        {
            ["创建歌单"] = IntValue(json.Prop("createdPlaylistCount")) ?? 0,
            ["收藏歌单"] = IntValue(json.Prop("subPlaylistCount")) ?? 0,
            ["关注歌手"] = IntValue(json.Prop("artistCount")) ?? 0,
            ["收藏电台"] = IntValue(json.Prop("djRadioCount")) ?? 0,
            ["节目"] = IntValue(json.Prop("programCount")) ?? 0,
            ["MV"] = IntValue(json.Prop("mvCount")) ?? 0,
        };
    }

    private static string? AnyValue(JsonElement? value)
    {
        if (value is null) return null;
        if (value.Value.ValueKind == JsonValueKind.String)
        {
            var text = value.Value.GetString();
            return string.IsNullOrEmpty(text) ? null : text;
        }
        return value.Value.ValueKind == JsonValueKind.Number ? value.Value.GetRawText().Trim() : null;
    }

    private static int? IntValue(JsonElement? value) => value.AsInt();

    internal static DateTimeOffset DateFromMilliseconds(JsonElement? value)
    {
        var milliseconds = value.AsLong();
        if (milliseconds is null) return DateTimeOffset.UtcNow;
        return milliseconds > 100_000_000_000
            ? DateTimeOffset.FromUnixTimeMilliseconds(milliseconds.Value)
            : DateTimeOffset.FromUnixTimeSeconds(milliseconds.Value);
    }
}
