import Foundation

/// `NeteaseProvider` 的歌手资料页能力。
///
/// ## 为什么单独一个文件
///
/// `NeteaseProvider.swift` 已经 975 行，`NeteaseSocialProvider.swift` 836 行。
/// 歌手页的五个接口（资料 / 简介 / 全部歌曲 / 专辑 / MV）自成一体，
/// 拆出来单独读比在主文件里翻要快。
///
/// ## 为什么不加进 `MusicProvider` 协议
///
/// `MusicProvider` 是**播放闭环**的最小面。新增协议方法要连带改
/// `LocalProvider` 与三个测试桩，而本地 Provider 根本没有网易云的歌手资料。
/// 与其加一堆 `throw .unsupported`，不如像 `fetchSimilarArtists` 那样
/// 放在 `MusicSocialProvider` 侧的 extension 里。
///
/// ## 字段名都对着实测核过
///
/// 这个接口族的坑全在字段名上（`/artist/album` 给 `hotAlbums`，
/// `/simi/artist` 给 `artists`，`/artist/detail` 给 `data.artist` 且图片字段叫
/// `cover`/`avatar` 而**不是** `picUrl`）。每处解析下面都注明了来源。
extension NeteaseProvider: ArtistProfileProviding {

    // MARK: - 资料

    /// `/artist/detail`（eapi `/api/artist/head/info/get`）。
    ///
    /// 实测响应：`{ code, message, data: { artist, videoCount, identify, ... } }`。
    /// `data.artist` 的键是
    /// `id / cover / avatar / name / transNames / alias / identities /
    ///  identifyTag / briefDesc / rank / albumSize / musicSize / mvSize`
    /// —— **没有 `picUrl`**，头像要从 `cover` 或 `avatar` 取。
    public func fetchArtistProfile(id: String) async throws -> ArtistProfile {
        let cookie = try Self.loadLoginCookie()
        let data = try await request("/artist/detail", query: ["id": id], cookie: cookie, cacheTTL: 600)
        let json = try parseJSON(data)
        guard let payload = json["data"] as? [String: Any],
              let artistDict = payload["artist"] as? [String: Any] else {
            throw MusicError.invalidResponse
        }
        let artist = Self.mapArtist(artistDict)
        // `identifyTag` 是逗号分隔的字符串，不是数组（实测 "创作歌手,制作人"）
        let identifyTags = (artistDict["identifyTag"] as? String)?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        return ArtistProfile(
            artist: artist,
            briefDescription: artistDict["briefDesc"] as? String,
            albumCount: (artistDict["albumSize"] as? Int) ?? 0,
            songCount: (artistDict["musicSize"] as? Int) ?? 0,
            mvCount: (artistDict["mvSize"] as? Int) ?? 0,
            videoCount: (payload["videoCount"] as? Int) ?? 0,
            identifyTags: identifyTags,
            isFollowed: Self.optionalBool(artistDict["followed"])
        )
    }

    // MARK: - 热门歌曲

    /// `/artist/top/song`（weapi）。
    ///
    /// 单独拆一个方法而不是复用 `fetchArtistDetail`：那个方法会把
    /// `/artist/album` 一起打一遍，而歌手页的专辑区块有自己的分页加载，
    /// 复用等于每次都白打一次专辑接口。
    public func fetchHotArtistSongs(id: String) async throws -> [Song] {
        let data = try await request("/artist/top/song", query: ["id": id], cacheTTL: 600)
        let json = try parseJSON(data)
        return (json["songs"] as? [[String: Any]])?.compactMap { Self.mapSong($0) } ?? []
    }

    // MARK: - 全部歌曲

    /// `/artist/songs`（eapi `/api/v1/artist/songs`）。
    ///
    /// 实测响应：`{ songs, more, total, code }`，`total` 566 而 `songs` 只有一页。
    /// `order`：`hot`（热门，默认）/ `time`（按时间）。
    ///
    /// `songs[]` 的元素是**完整歌曲对象**（`artists` / `album` / `mvid` 都在），
    /// 现成的 `mapSong` 直接能吃，不需要二次补详情。
    public func fetchArtistSongs(
        id: String,
        offset: Int,
        limit: Int = 50,
        order: String = "hot"
    ) async throws -> ArtistSongPage {
        let cookie = try Self.loadLoginCookie()
        let data = try await request("/artist/songs", query: [
            "id": id,
            "order": order,
            "offset": String(offset),
            "limit": String(limit),
            // private_cloud / work_type 由 artist_songs.js 写死，不从 query 读，
            // 所以这里不传（传了会被 module 忽略）。见 NeteaseEndpoint.artistSongs。
        ], cookie: cookie, cacheTTL: order == "hot" ? 300 : nil)
        let json = try parseJSON(data)
        let songs = (json["songs"] as? [[String: Any]])?.compactMap { Self.mapSong($0) } ?? []
        return ArtistSongPage(
            songs: songs,
            total: (json["total"] as? Int) ?? offset + songs.count,
            // `more` 缺失时按「这一页没填满」保守处理，避免翻页卡死
            hasMore: (json["more"] as? Bool) ?? (songs.count >= limit)
        )
    }

    // MARK: - 专辑

    /// `/artist/album`（weapi `/api/artist/albums/{id}`）。
    ///
    /// 实测响应：`{ code, artist, hotAlbums, more, kindTabs }` —— 数组叫
    /// **`hotAlbums`**，`more` 是布尔。`artist` 里回带了 `picUrl` 与
    /// **`followed`**（关注按钮的初始状态就取这里，省一次请求）。
    public func fetchArtistAlbums(id: String, offset: Int, limit: Int = 30) async throws -> ArtistAlbumPage {
        let data = try await request("/artist/album", query: [
            "id": id, "offset": String(offset), "limit": String(limit), "total": "true",
        ], cacheTTL: 300)
        let json = try parseJSON(data)
        let albums = (json["hotAlbums"] as? [[String: Any]])?.map { Self.mapAlbum($0) } ?? []
        let artistDict = json["artist"] as? [String: Any]
        return ArtistAlbumPage(
            albums: albums,
            isFollowed: Self.optionalBool(artistDict?["followed"]),
            hasMore: (json["more"] as? Bool) ?? (albums.count >= limit)
        )
    }

    // MARK: - MV

    /// `/artist/mv`（weapi `/api/artist/mvs`）。
    ///
    /// ⚠️ 参数名是 `artistId` 不是 `id`（`artist_mv.js: artistId: query.id`）。
    /// 实测响应：`{ mvs, time, hasMore, code }`，元素没有 `ar`/`al`，
    /// 歌手名在扁平的 `artistName`，封面优先 `imgurl16v9`（竖版 16:9，比
    /// `imgurl` 宽版更适合列表左侧的小方块）。
    public func fetchArtistMVs(id: String, offset: Int, limit: Int = 30) async throws -> ArtistMVPage {
        let data = try await request("/artist/mv", query: [
            "id": id, "offset": String(offset), "limit": String(limit), "total": "true",
        ], cacheTTL: 300)
        let json = try parseJSON(data)
        let mvs = (json["mvs"] as? [[String: Any]])?.compactMap(Self.mapArtistMV) ?? []
        return ArtistMVPage(
            mvs: mvs,
            hasMore: (json["hasMore"] as? Bool) ?? (mvs.count >= limit)
        )
    }

    nonisolated static func mapArtistMV(_ dict: [String: Any]) -> ArtistMV? {
        guard let id = dict["id"] else { return nil }
        // 时长是毫秒。这个接口实测给 Int，但 `number()` 的存在本身就是为了
        // 兜住 JSONSerialization 把整数解成 NSNumber 的情况。
        let durationMs = int64(dict["duration"]) ?? 0
        let publishTime = int64(dict["publishTime"]).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        return ArtistMV(
            id: String(describing: id),
            name: dict["name"] as? String ?? "未命名 MV",
            artistName: dict["artistName"] as? String,
            coverURL: (dict["imgurl16v9"] as? String ?? dict["imgurl"] as? String).flatMap(URL.init),
            duration: TimeInterval(durationMs) / 1000,
            playCount: int64(dict["playCount"]).map(Int.init) ?? 0,
            publishDate: publishTime
        )
    }

    // MARK: - 简介

    /// `/artist/desc`（weapi `/api/artist/introduction`）。
    ///
    /// 实测响应：`{ introduction: [{ ti, txt }], briefDesc, count, topicData, code }`。
    /// `ti` 是段标题（实测「主要成就」），`txt` 是正文（含换行）。
    public func fetchArtistIntro(id: String) async throws -> ArtistIntro {
        let data = try await request("/artist/desc", query: ["id": id], cacheTTL: 3600)
        let json = try parseJSON(data)
        let sections = (json["introduction"] as? [[String: Any]])?.compactMap { entry -> ArtistIntroSection? in
            // 段标题可以缺失；正文为空或纯空白的段直接丢掉
            guard let body = (entry["txt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
            let title = ((entry["ti"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            return ArtistIntroSection(title: title, body: body)
        } ?? []
        let brief = (json["briefDesc"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ArtistIntro(briefDescription: (brief?.isEmpty ?? true) ? nil : brief, sections: sections)
    }

    // MARK: - 工具

    /// `followed` 可能是 `true` / `false` / `"true"` / `1` / `0`。
    /// 未登录时字段缺失，必须是 nil（= 未知）而不是 false，
    /// 否则关注按钮在未登录时会显示成「未关注」而不是禁用。
    nonisolated static func optionalBool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let n as Int: return n != 0
        case let s as String:
            switch s {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default: return nil
        }
    }
}
