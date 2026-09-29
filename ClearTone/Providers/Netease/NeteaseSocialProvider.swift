import Foundation

/// `NeteaseProvider` 的社交 / 资料库能力（`MusicSocialProvider`）。
///
/// ## 分文件的原因
///
/// 主文件已 975 行，再塞 40 个方法会到 2000 行。这里用 extension 拆开，
/// 共享主类的 `request` / 解析器（因此那些成员是 internal 而非 private）。
///
/// ## 三条贯穿全文件的铁律
///
/// 1. **写操作必须 POST**。用 GET 调网易云的写接口会拿到
///    `code 524 当前环境异常` 或 `405 操作频繁`，表现为「点了没反应」。
/// 2. **只认 body 里的 `code`，不看 HTTP 状态码**。`playlist_tracks.js`
///    在出错时也会 `return { status: 200, body: error.body }` ——
///    HTTP 200 与「成功」无关。
/// 3. **写完必须失效相关读缓存**。`/like` 只清 `/likelist` 时，
///    歌单曲目元数据最长 300s 不更新，界面表现为「收藏了但列表没变」。
extension NeteaseProvider: MusicSocialProvider {

    // MARK: - 写操作公共部分

    /// 统一校验写接口返回的 `code`。
    ///
    /// 网易云的成功码是 200；`-460` 是缺客户端标识、`405` 是已接受但被限流、
    /// `301` 是需要登录 —— 都必须当成失败抛出去，不能静默。
    private func requireWriteSucceeded(_ json: [String: Any], action: String) throws {
        guard let code = json["code"] as? Int else { throw MusicError.invalidResponse }
        guard code == 200 else {
            let message = (json["msg"] ?? json["message"]) as? String ?? "未知错误"
            throw MusicError.apiError(code: code, message: "\(action)失败：\(message)")
        }
    }

    private func requireLoginCookie() async throws -> String {
        guard let cookie = try Self.loadLoginCookie(), !cookie.isEmpty else {
            throw MusicError.notLoggedIn
        }
        return cookie
    }

    // MARK: - 歌单写操作

    public func subscribePlaylist(id: String, subscribe: Bool) async throws {
        let cookie = try await requireLoginCookie()
        // 走 eapi 路由：playlist_subscribe.js 内部强制 checkToken=v2，
        // 辅助进程会为每次调用现取反作弊 token；iOS 直连没有这个能力，
        // 会在 NeteaseEndpoint.orderedPayload 处显式失败而不是静默降级。
        let route = subscribe ? "/playlist/subscribe" : "/playlist/unsubscribe"
        let json = try parseJSON(
            try await request(route, query: ["id": id, "t": subscribe ? "1" : "2"],
                              cookie: cookie, method: "POST")
        )
        try requireWriteSucceeded(json, action: subscribe ? "收藏歌单" : "取消收藏")
        invalidateCache(pathPrefixes: ["/playlist/detail", "/playlist/track/all", "/user/playlist"])
    }

    public func createPlaylist(name: String, isPrivate: Bool) async throws -> Playlist {
        let cookie = try await requireLoginCookie()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MusicError.invalidResponse }
        let json = try parseJSON(
            try await request("/playlist/create", query: [
                "name": trimmed,
                "privacy": isPrivate ? "10" : "0",   // 10 = 隐私歌单
                "type": "NORMAL",
            ], cookie: cookie, method: "POST")
        )
        try requireWriteSucceeded(json, action: "创建歌单")
        guard let dict = json["playlist"] as? [String: Any] else { throw MusicError.invalidResponse }
        invalidateCache(pathPrefixes: ["/user/playlist"])
        return Self.mapPlaylist(dict)
    }

    public func deletePlaylist(id: String) async throws {
        let cookie = try await requireLoginCookie()
        // playlist_delete.js 拼的是 `'[' + id + ']'`，所以 id 必须是
        // 纯数字或逗号分隔的数字串，任何其他字符会产出非法 JSON。
        let ids = id.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !ids.isEmpty, ids.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            throw MusicError.invalidResponse
        }
        let json = try parseJSON(
            try await request("/playlist/delete", query: ["id": ids.joined(separator: ",")],
                              cookie: cookie, method: "POST")
        )
        try requireWriteSucceeded(json, action: "删除歌单")
        invalidateCache(pathPrefixes: ["/user/playlist", "/playlist/detail"])
    }

    public func updatePlaylistName(id: String, name: String) async throws {
        let cookie = try await requireLoginCookie()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MusicError.invalidResponse }
        // 用 create + tracks 的组合接口做不了改名；playlist_name/update
        // 在 api-enhanced 里是 eapi 且键序未登记，iOS 走不了。
        // 这里显式说明限制而不是静默失败。
        let json = try parseJSON(
            try await request("/playlist/name/update", query: ["id": id, "name": trimmed],
                              cookie: cookie, method: "POST")
        )
        try requireWriteSucceeded(json, action: "重命名歌单")
        invalidateCache(pathPrefixes: ["/user/playlist", "/playlist/detail"])
    }

    public func addSongsToPlaylist(playlistID: String, songIDs: [String]) async throws {
        try await manipulatePlaylistTracks(op: "add", playlistID: playlistID, songIDs: songIDs)
    }

    public func removeSongsFromPlaylist(playlistID: String, songIDs: [String]) async throws {
        try await manipulatePlaylistTracks(op: "del", playlistID: playlistID, songIDs: songIDs)
    }

    private func manipulatePlaylistTracks(op: String, playlistID: String, songIDs: [String]) async throws {
        let cookie = try await requireLoginCookie()
        let ids = songIDs.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        // `tracks` 必须是**裸逗号串**，不是 JSON 数组字符串。
        //
        // 上游 `api/module/playlist_tracks.js:6` 做的是 `query.tracks.split(',')`，
        // 然后自己 `JSON.stringify(tracks)` 拼成 `trackIds`。它**从不** JSON.parse。
        //
        // 原实现发的是 `["347231","347232"]`，split 之后变成
        // `['["347231"', '"347232"]']`，再 stringify 就是一串垃圾 song id，
        // 网易云返回非 200 → 加歌与删歌两条写操作全部失败。
        let commaSeparated = ids.joined(separator: ",")
        let json = try parseJSON(
            try await request("/playlist/tracks", query: [
                "op": op, "pid": playlistID, "tracks": commaSeparated, "imme": "true",
            ], cookie: cookie, method: "POST")
        )
        // 这个路由出错时也返回 HTTP 200，所以必须查 body 的 code
        try requireWriteSucceeded(json, action: op == "add" ? "添加到歌单" : "从歌单移除")
        invalidateCache(pathPrefixes: ["/playlist/detail", "/playlist/track/all", "/user/playlist"])
    }

    // MARK: - 收藏专辑 / 歌手 / 电台

    public func subscribeAlbum(id: String, subscribe: Bool) async throws {
        try await toggleSub(
            subRoute: "/album/sub", unsubRoute: "/album/unsub",
            id: id, subscribe: subscribe, action: "专辑"
        )
    }

    public func subscribeArtist(id: String, subscribe: Bool) async throws {
        try await toggleSub(
            subRoute: "/artist/sub", unsubRoute: "/artist/unsub",
            id: id, subscribe: subscribe, action: "歌手"
        )
    }

    public func subscribeRadio(id: String, subscribe: Bool) async throws {
        // 注意参数名是 `rid` 不是 `id`（dj_sub.js: `data = { id: query.rid }`）
        try await toggleSub(
            subRoute: "/dj/sub", unsubRoute: "/dj/unsub",
            id: id, subscribe: subscribe, action: "电台",
            queryKey: "rid"
        )
    }

    private func toggleSub(
        subRoute: String,
        unsubRoute: String,
        id: String,
        subscribe: Bool,
        action: String,
        queryKey: String = "id"
    ) async throws {
        let cookie = try await requireLoginCookie()
        let json = try parseJSON(
            try await request(subscribe ? subRoute : unsubRoute,
                              query: [queryKey: id, "t": subscribe ? "1" : "0"],
                              cookie: cookie, method: "POST")
        )
        try requireWriteSucceeded(json, action: subscribe ? "收藏\(action)" : "取消收藏\(action)")
        invalidateCache(pathPrefixes: ["/album", "/artist", "/dj", "/user/playlist"])
    }

    // MARK: - 订阅列表

    public func fetchSubscribedPlaylists(limit: Int = 50) async throws -> [Playlist] {
        guard let userID = try KeychainStore.shared.load(for: .neteaseUserID) else {
            throw MusicError.notLoggedIn
        }
        let cookie = try await requireLoginCookie()
        // `/user/playlist` 第 2 页起是「收藏的歌单」（`/api/user/playlist` 的
        // offset 分页），前 limit 个即是收藏部分
        let data = try await request("/user/playlist", query: [
            "uid": userID, "limit": String(limit), "offset": "0",
        ], cookie: cookie, cacheTTL: 120)
        let json = try parseJSON(data)
        guard let list = json["playlist"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        // `subCount > 0` 且不是自己创建的第一个（网易云把「我喜欢的音乐」
        // 塞在第 0 位），这里用 subscribed 标记过滤已收藏的
        return list.compactMap { dict -> Playlist? in
            var p = Self.mapPlaylist(dict)
            p.isSubscribed = (dict["subCount"] as? Int ?? 0) > 0
            return p
        }
    }

    public func fetchSubscribedAlbums(limit: Int = 50) async throws -> [Album] {
        guard let userID = try KeychainStore.shared.load(for: .neteaseUserID) else {
            throw MusicError.notLoggedIn
        }
        let cookie = try await requireLoginCookie()
        let data = try await request("/album/sublist", query: [
            "uid": userID, "limit": String(limit),
        ], cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        // 实测：数组在 `data`（不是 `albums`），旁边还有 count/hasMore
        guard let albums = json["data"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return albums.map { Self.mapAlbum($0) }
    }

    public func fetchSubscribedArtists(limit: Int = 50) async throws -> [Artist] {
        guard let userID = try KeychainStore.shared.load(for: .neteaseUserID) else {
            throw MusicError.notLoggedIn
        }
        let cookie = try await requireLoginCookie()
        let data = try await request("/artist/sublist", query: [
            "uid": userID, "limit": String(limit),
        ], cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        // 实测：数组在 `data`（不是 `artists`）
        guard let artists = json["data"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return artists.map { Self.mapArtist($0) }
    }

    // MARK: - 电台

    /// 电台详情（`/dj/detail`）。
    ///
    /// 补上了一个长期存在的缺口：`/dj/program` 不返回电台名，
    /// 于是电台详情页此前永远显示「电台」两个字。这个接口会返回
    /// `djradio.name` 与 `isSub`，而且**不需要登录**。
    ///
    /// 参数名是 `rid` 不是 `id`（`dj_detail.js`: `data = { id: query.rid }`）。
    public func fetchRadioStationDetail(radioID: String) async throws -> RadioStation {
        let data = try await request("/dj/detail", query: ["rid": radioID], cacheTTL: 600)
        let json = try parseJSON(data)
        // 实测：电台本体在 `data`（不是 `djradio`），且同一次响应里**不含** programs ——
        // 节目仍要靠 `/dj/program?rid=`。
        // 封面是 `picUrl`（`/dj/sublist` 才是 `pic`），主播在 `dj.nickname`。
        guard var dict = json["data"] as? [String: Any] else { throw MusicError.invalidResponse }
        if dict["picUrl"] == nil, let pic = dict["pic"] as? String {
            dict["picUrl"] = pic
        }
        if dict["isSub"] == nil {
            dict["isSub"] = ((dict["subCount"] as? Int) ?? 0) > 0 ? 1 : 0
        }
        guard let station = Self.mapRadioStation(dict) else { throw MusicError.invalidResponse }
        return station
    }

    public func fetchSubscribedRadios(limit: Int = 30) async throws -> [RadioStation] {
        let cookie = try await requireLoginCookie()
        let data = try await request("/dj/sublist", query: [
            "limit": String(limit), "offset": "0",
        ], cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        // 实测：`djRadios` 在**顶层**（不在 data 里），封面字段是 `picUrl`
        //（`/dj/detail` 才是 `pic`）
        guard let radios = json["djRadios"] as? [[String: Any]] else {
            throw MusicError.invalidResponse
        }
        return radios.compactMap { raw -> RadioStation? in
            var normalized = raw
            if normalized["picUrl"] == nil, let pic = raw["pic"] as? String {
                normalized["picUrl"] = pic
            }
            normalized["isSub"] = 1
            return Self.mapRadioStation(normalized)
        }
    }

    // MARK: - 榜单

    public func fetchTopLists() async throws -> [TopList] {
        let data = try await request("/toplist", cacheTTL: 3600)
        let json = try parseJSON(data)
        guard let list = json["list"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return list.compactMap { dict in
            guard let id = dict["id"] else { return nil }
            return TopList(
                id: String(describing: id),
                name: dict["name"] as? String ?? "未命名榜单",
                coverURL: (dict["coverImgUrl"] as? String).flatMap(URL.init),
                updateFrequency: dict["updateFrequency"] as? String,
                trackCount: dict["trackCount"] as? Int ?? 0,
                playCount: dict["playCount"] as? Int ?? 0,
                descriptionText: dict["description"] as? String,
                iconURL: [
                    dict["icon"] as? String,
                    dict["backgroundImageUrl"] as? String,
                ].compactMap { $0 }.first.flatMap(URL.init)
            )
        }
    }

    public func fetchTopSongs(area: TopSongArea) async throws -> [Song] {
        // top_song.js 里 limit/offset 被注释掉了，接口固定返回一批
        let data = try await request("/top/song", query: [
            "type": String(area.areaID), "total": "true",
        ], cacheTTL: 600)
        let json = try parseJSON(data)
        // 关键：歌曲在 `data.songsData`，不在顶层也不在 `data.songs`
        guard let dict = json["data"] as? [String: Any],
              let songs = dict["songsData"] as? [[String: Any]] else {
            throw MusicError.invalidResponse
        }
        return songs.compactMap { Self.mapSong($0) }
    }

    public func fetchHotPlaylists(
        category: String?,
        order: TopPlaylistOrder,
        limit: Int,
        offset: Int
    ) async throws -> [Playlist] {
        var query = [
            "order": order.apiValue,
            "limit": String(limit),
            "offset": String(offset),
            "total": "true",
        ]
        // 不传 cat 时上游默认「全部」；显式传空串会被当成未知分类
        query["cat"] = (category?.isEmpty == false) ? category! : "全部"
        let data = try await request("/top/playlist", query: query, cacheTTL: 300)
        let json = try parseJSON(data)
        guard let playlists = json["playlists"] as? [[String: Any]] else {
            throw MusicError.invalidResponse
        }
        return playlists.map { Self.mapPlaylist($0) }
    }

    public func fetchPlaylistCategories() async throws -> [PlaylistCategoryGroup] {
        let data = try await request("/playlist/catlist", cacheTTL: 3600)
        let json = try parseJSON(data)
        // `categories` 是「展示名 → [机器值...]」的字典
        guard let categories = json["categories"] as? [String: Any] else {
            throw MusicError.invalidResponse
        }
        return categories
            .compactMap { groupName, values -> PlaylistCategoryGroup? in
                guard let list = values as? [String], !list.isEmpty else { return nil }
                return PlaylistCategoryGroup(name: groupName, categories: list)
            }
            // 固定分组顺序，避免每次刷新分类栏位置乱跳
            .sorted { lhs, rhs in
                Self.categoryGroupOrder(lhs.name) < Self.categoryGroupOrder(rhs.name)
            }
    }

    private static func categoryGroupOrder(_ name: String) -> Int {
        let order = ["语种", "风格", "场景", "情感", "主题"]
        return order.firstIndex(of: name) ?? order.count
    }

    public func fetchHotPlaylistTags() async throws -> [String] {
        let data = try await request("/playlist/hot", cacheTTL: 3600)
        let json = try parseJSON(data)
        guard let tags = json["tags"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return tags.compactMap { $0["name"] as? String }
    }

    // MARK: - 推荐扩展

    public func fetchPersonalFM() async throws -> [Song] {
        let cookie = try await requireLoginCookie()
        // 返回固定 3 首，不吃缓存 —— FM 的语义就是每次都要新的
        let data = try await request("/personal_fm", cookie: cookie)
        let json = try parseJSON(data)
        guard let songs = json["data"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return songs.compactMap { Self.mapSong($0) }
    }

    public func fetchDailyRecommendPlaylists() async throws -> [Playlist] {
        let cookie = try await requireLoginCookie()
        let data = try await request("/recommend/resource", cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        guard let list = json["recommend"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return list.map { Self.mapPlaylist($0) }
    }

    public func fetchNewSongs(limit: Int = 30) async throws -> [Song] {
        let data = try await request("/personalized/newsong", query: [
            "type": "recommend", "limit": String(limit), "areaId": "0",
        ], cacheTTL: 600)
        let json = try parseJSON(data)
        guard let list = json["result"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        // 这个接口返回的是「搜索简要」结构（`artists` / `album` / `duration` 全名），
        // 而 `/song/detail` 用的是 `ar` / `al` / `dt`。
        // `mapSong` 两个形状都认（它对每个字段都有回退），所以这里可以直接复用。
        return list.compactMap { Self.mapSong($0) }
    }

    public func fetchNewAlbums(limit: Int = 30) async throws -> [Album] {
        let data = try await request("/album/newest", cacheTTL: 600)
        let json = try parseJSON(data)
        // 实测：`albums` 是数组（一次给十几张），不是单个 `newest` 对象
        guard let albums = json["albums"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return albums.prefix(max(1, limit)).map { Self.mapAlbum($0) }
    }

    public func fetchSimilarSongs(songID: String, limit: Int = 30) async throws -> [Song] {
        let data = try await request("/simi/song", query: [
            "id": songID, "limit": String(limit), "offset": "0",
        ], cacheTTL: 600)
        let json = try parseJSON(data)
        guard let songs = json["songs"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return songs.compactMap { Self.mapSong($0) }
    }

    public func fetchSimilarArtists(artistID: String) async throws -> [Artist] {
        let data = try await request("/simi/artist", query: ["id": artistID], cacheTTL: 600)
        let json = try parseJSON(data)
        // 实测：数组在 `data`（不是 `artists`）
        guard let artists = json["data"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return artists.map { Self.mapArtist($0) }
    }

    @discardableResult
    public func dislikeDailyRecommend(songID: String) async throws -> Song? {
        let cookie = try await requireLoginCookie()
        let json = try parseJSON(
            try await request("/recommend/songs/dislike",
                              query: ["id": songID], cookie: cookie, method: "POST")
        )
        try requireWriteSucceeded(json, action: "反馈不喜欢")
        invalidateCache(pathPrefix: "/recommend/songs")
        // 替补歌曲在 `data`，是完整的 Song 结构
        guard let replacement = json["data"] as? [String: Any] else { return nil }
        return Self.mapSong(replacement)
    }

    // MARK: - 搜索辅助

    public func fetchSearchSuggestions(keyword: String) async throws -> [SearchSuggestion] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // 不设缓存：联想词随输入实时变化，缓存反而会给出过时建议
        let data = try await request("/search/suggest", query: ["keywords": trimmed])
        let json = try parseJSON(data)
        guard let result = json["result"] as? [String: Any] else { return [] }
        var out: [SearchSuggestion] = []
        // 顺序即权重：先歌曲再歌手再专辑和歌单
        for (key, kind) in [("songs", SearchSuggestion.Kind.song),
                            ("artists", .artist),
                            ("albums", .album),
                            ("playlists", .playlist)] {
            guard let items = result[key] as? [[String: Any]] else { continue }
            for item in items.prefix(5) {
                guard let id = item["id"] else { continue }
                out.append(SearchSuggestion(
                    kind: kind,
                    title: item["name"] as? String ?? "",
                    subtitle: Self.suggestionSubtitle(item, kind: kind),
                    coverURL: (item["picUrl"] as? String).flatMap(URL.init),
                    targetID: String(describing: id)
                ))
            }
        }
        return out
    }

    private static func suggestionSubtitle(
        _ dict: [String: Any], kind: SearchSuggestion.Kind
    ) -> String? {
        let artists = dict["artists"] as? [[String: Any]] ?? []
        let names = artists.compactMap { $0["name"] as? String }
        switch kind {
        case .song:
            guard !names.isEmpty else { return nil }
            let ms = (dict["duration"] as? Double ?? 0) / 1000
            let total = Int(ms)
            return "\(names.joined(separator: " / ")) · \(total / 60):\(String(format: "%02d", total % 60))"
        case .artist:
            let size = dict["albumSize"] as? Int
            return size.map { "\($0) 张专辑" }
        case .album:
            guard !names.isEmpty else { return nil }
            return names.joined(separator: " / ")
        case .playlist:
            let count = dict["trackCount"] as? Int
            return count.map { "\($0) 首" }
        }
    }

    /// 热搜词。
    ///
    /// ## 实测结构（与上游模块的注释不一致）
    ///
    /// 列表在 **`result.hots`**，不是 `data.hots`；每个元素只有四个字段：
    /// `first`（**就是搜索词本身**，如「刘欢」）、`second`（热度数值）、
    /// `third`（恒为 null）、`iconType`（新热/沸点等角标类型）。
    /// **没有** `keyword` / `score` / `icon` / `firstword` ——
    /// 按 `home.md` 那套字段名去读会得到空数组，而且不报错。
    public func fetchHotSearchTerms() async throws -> [HotSearchTerm] {
        let data = try await request("/search/hot", cacheTTL: 1800)
        let json = try parseJSON(data)
        guard let dict = json["result"] as? [String: Any],
              let hots = dict["hots"] as? [[String: Any]] else {
            throw MusicError.invalidResponse
        }
        return hots.compactMap { item in
            let keyword = (item["first"] as? String) ?? ""
            guard !keyword.isEmpty else { return nil }
            return HotSearchTerm(
                keyword: keyword,
                score: item["second"] as? Int ?? 0,
                // iconType 是角标类型码，映射成可读标签
                displayPrefix: Self.hotSearchIconLabel(item["iconType"] as? Int ?? 0),
                icon: nil
            )
        }
    }

    private static func hotSearchIconLabel(_ type: Int) -> String? {
        switch type {
        case 1: return "新"
        case 2: return "沸"
        default: return nil
        }
    }

    // MARK: - 评论

    public func fetchComments(
        songID: String,
        sort: CommentSort,
        page: Int,
        pageSize: Int = 20,
        cursor: String? = nil
    ) async throws -> CommentPage {
        let cookie = try Self.loadLoginCookie()
        let data = try await request("/comment/new", query: Self.commentQuery(
            songID: songID, sort: sort, page: page, pageSize: pageSize, cursor: cursor
        ), cookie: cookie, cacheTTL: sort == .newest ? 0 : 60)
        let json = try parseJSON(data)
        let myID = try? KeychainStore.shared.load(for: .neteaseUserID)
        return try Self.mapCommentPage(json, myID: myID)
    }

    nonisolated static func commentQuery(
        songID: String, sort: CommentSort, page: Int, pageSize: Int, cursor: String?
    ) -> [String: String] {
        var query = [
            "id": songID, "type": "0", "sortType": String(sort.apiValue),
            "pageNo": String(max(1, page)), "pageSize": String(max(1, pageSize)),
        ]
        if sort == .newest, page > 1, let cursor { query["cursor"] = cursor }
        return query
    }

    /// 直接测试生产解析，避免测试里复制映射逻辑却把错误字段名也复制过去。
    nonisolated static func mapCommentPage(_ json: [String: Any], myID: String?) throws -> CommentPage {
        guard let body = json["data"] as? [String: Any],
              let list = body["comments"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        let comments = list.compactMap { item -> Comment? in
            guard let id = item["commentId"] ?? item["id"] else { return nil }
            let user = item["user"] as? [String: Any] ?? [:]
            let userID = String(describing: user["userId"] ?? item["userId"] ?? "")
            let replied = (item["beReplied"] as? [[String: Any]])?.first
            return Comment(
                id: String(describing: id),
                content: item["content"] as? String ?? "",
                userID: userID,
                nickname: user["nickname"] as? String ?? "匿名用户",
                avatarURL: (user["avatarUrl"] as? String).flatMap(URL.init),
                time: Self.date(fromMilliseconds: item["time"]),
                likedCount: item["likedCount"] as? Int ?? 0,
                isLiked: item["liked"] as? Bool ?? false,
                replyCount: item["replyCount"] as? Int ?? 0,
                replyToNickname: (replied?["user"] as? [String: Any])?["nickname"] as? String,
                replyToContent: replied?["content"] as? String,
                isMine: myID.map { userID == $0 } ?? false
            )
        }
        return CommentPage(
            comments: comments,
            total: body["totalCount"] as? Int ?? comments.count,
            hasMore: body["hasMore"] as? Bool ?? false,
            nextCursor: list.last?["time"].map { String(describing: $0) }
        )
    }

    nonisolated static func commentLikeQuery(songID: String, commentID: String, like: Bool) -> [String: String] {
        ["id": songID, "cid": commentID, "type": "0", "t": like ? "1" : "0"]
    }

    public func likeComment(songID: String, commentID: String, like: Bool) async throws {
        let cookie = try await requireLoginCookie()
        // 同一个 comment_like.js 用 t=1/0 分派，helper 没有 /comment/unlike 路由。
        let json = try parseJSON(
            try await request("/comment/like", query: Self.commentLikeQuery(
                songID: songID, commentID: commentID, like: like
            ), cookie: cookie, method: "POST")
        )
        try requireWriteSucceeded(json, action: like ? "点赞评论" : "取消点赞")
        invalidateCache(pathPrefixes: ["/comment/new", "/comment/music"])
    }

    // MARK: - 消息

    public func fetchNotices(limit: Int = 30) async throws -> [UserNotice] {
        let cookie = try await requireLoginCookie()
        // 参数名是 `lasttime`（映射上游的 `time`），不是 `before`/`time`
        let data = try await request("/msg/notices", query: [
            "limit": String(limit), "lasttime": "-1",
        ], cookie: cookie, cacheTTL: 60)
        let json = try parseJSON(data)
        guard let list = json["notices"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return list.compactMap { item in
            guard let id = item["id"] else { return nil }
            let user = item["user"] as? [String: Any]
            return UserNotice(
                id: String(describing: id),
                kind: UserNotice.Kind(typeCode: item["type"] as? Int ?? 0),
                time: Self.date(fromMilliseconds: item["time"]),
                actorNickname: user?["nickname"] as? String,
                actorAvatarURL: (user?["avatarUrl"] as? String).flatMap(URL.init),
                content: item["msg"] as? String,
                replyCommentText: item["replyCommentText"] as? String,
                relatedID: item["relatedId"].map { String(describing: $0) }
            )
        }
    }

    public func fetchPrivateConversations(limit: Int = 30, offset: Int = 0) async throws -> [PrivateConversation] {
        let cookie = try await requireLoginCookie()
        let data = try await request("/msg/private", query: [
            "limit": String(limit), "offset": String(offset), "total": "true",
        ], cookie: cookie, cacheTTL: 60)
        let json = try parseJSON(data)
        // 实测：数组键是 `msgs`（不是 data/users），每个会话把对端用户裹在
        // `user` 子对象里；`lastMsg` 是**被 JSON 字符串化过的**内容
        // （形如 {"msg":"...发..."}），要再解一层才能拿到纯文本。
        // 另外可能是 fromUser 也可能是 toUser —— 谁不是自己就是对方。
        let list = (json["msgs"] as? [[String: Any]])
            ?? (json["data"] as? [[String: Any]])
            ?? (json["users"] as? [[String: Any]])
            ?? []
        let myID = (try? KeychainStore.shared.load(for: .neteaseUserID)) ?? nil
        return list.compactMap { item -> PrivateConversation? in
            let user = item["user"] as? [String: Any] ?? [:]
            guard let peerID = user["id"] ?? user["fromUserId"] else { return nil }
            let peerIDString = String(describing: peerID)
            // 对端 = 不是我的那个
            let peerProfile = (peerIDString == myID)
                ? (item["toUser"] as? [String: Any] ?? [:])
                : (item["fromUser"] as? [String: Any]
                    ?? item["toUser"] as? [String: Any] ?? [:])
            return PrivateConversation(
                id: String(describing: item["lastMsgId"] ?? user["id"] ?? peerID),
                userID: peerIDString,
                nickname: peerProfile["nickname"] as? String ?? "未知用户",
                avatarURL: (peerProfile["avatarUrl"] as? String).flatMap(URL.init),
                lastMessage: Self.decodeNestedLastMessage(item["lastMsg"] as? String),
                lastTime: Self.date(fromMilliseconds: item["lastMsgTime"] ?? user["lastMsgTime"]),
                unreadCount: Self.intValue(item["newMsgCount"] ?? user["newMsgCount"]) ?? 0
            )
        }
    }

    /// `lastMsg` 被上游 JSON 字符串化过一层（`{"msg":"...","msgType":1,...}`），
    /// 取出其中的 msg 字段；不是合法 JSON 时原样返回。
    private static func decodeNestedLastMessage(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let data = raw.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = inner["msg"] as? String, !text.isEmpty else {
            return raw
        }
        return text
    }

    public func fetchPrivateMessages(userID: String, limit: Int = 30) async throws -> [PrivateMessage] {
        let cookie = try await requireLoginCookie()
        // 参数名是 `uid`（映射上游的 `userId`）
        let data = try await request("/msg/private/history", query: [
            "uid": userID, "limit": String(limit), "before": "0", "total": "true",
        ], cookie: cookie, cacheTTL: 0)
        let json = try parseJSON(data)
        guard let list = json["msgs"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        let myID = (try? KeychainStore.shared.load(for: .neteaseUserID)) ?? nil
        return list.compactMap { item in
            // 正文在嵌套的 `msg` 对象里，`msgType` 却在顶层 —— 两层不能混
            let inner = item["msg"] as? [String: Any] ?? [:]
            let text = inner["content"] as? String ?? ""
            guard !text.isEmpty, let id = inner["id"] ?? item["id"] else { return nil }
            let from = String(describing: inner["fromUserId"] ?? item["fromUserId"] ?? "")
            let sender = item["sender"] as? [String: Any] ?? item["user"] as? [String: Any] ?? [:]
            return PrivateMessage(
                id: String(describing: id),
                kind: PrivateMessage.Kind(msgType: inner["msgType"] as? Int ?? item["msgType"] as? Int ?? 1),
                content: text,
                time: Self.date(fromMilliseconds: inner["time"] ?? item["time"]),
                isOutgoing: myID == from && !from.isEmpty,
                senderNickname: sender["nickname"] as? String
            )
        }
    }

    public func fetchMyComments(limit: Int = 30) async throws -> [MyComment] {
        guard let userID = try KeychainStore.shared.load(for: .neteaseUserID) else {
            throw MusicError.notLoggedIn
        }
        let cookie = try await requireLoginCookie()
        // uid 在 uri 里；`before` 默认 '-1' 表示从最新开始
        let data = try await request("/msg/comments", query: [
            "uid": userID, "limit": String(limit), "before": "-1",
        ], cookie: cookie, cacheTTL: 60)
        let json = try parseJSON(data)
        // 实测：数组键是 `comments`（不是 data），旁边有 total/more
        guard let list = json["comments"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return list.compactMap { item -> MyComment? in
            let replied = (item["beReplied"] as? [[String: Any]])?.first
            // `commentId` 是这条评论自身的 id；`id` 是被评论资源的 id —— 两者别混
            guard let commentID = Self.anyValue(item["commentId"]) else { return nil }
            return MyComment(
                id: commentID,
                content: Self.stringValue(item["content"]) ?? "",
                time: Self.date(fromMilliseconds: item["time"]),
                likedCount: Self.intValue(item["likedCount"]) ?? 0,
                resourceKind: MyComment.ResourceKind(
                    rawValue: Self.intValue(item["type"]) ?? 0
                ) ?? .song,
                resourceID: Self.anyValue(item["id"]).map(String.init(describing:)),
                replyCount: Self.intValue(item["replyCount"]) ?? 0,
                repliedNickname: (replied?["user"] as? [String: Any])
                    .flatMap { Self.stringValue($0["nickname"]) },
                repliedContent: replied.flatMap { Self.stringValue($0["content"]) }
            )
        }
    }

    // MARK: - 账号数据

    public func fetchUserLevel() async throws -> UserLevelInfo {
        let cookie = try await requireLoginCookie()
        let data = try await request("/user/level", cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        guard let dict = json["data"] as? [String: Any] else { throw MusicError.invalidResponse }
        return UserLevelInfo(
            level: dict["level"] as? Int ?? 0,
            listenSongs: dict["listenSongs"] as? Int ?? 0,
            listenDays: dict["listenDays"] as? Int ?? 0,
            currentLoginDays: dict["currentLoginDays"] as? Int ?? 0,
            nextLevelNeedLoginDays: dict["nextLevelNeedLoginDays"] as? Int ?? 0,
            nextLevelNeedListenSongs: dict["nextLevelNeedListenSongs"] as? Int ?? 0,
            currentProgress: dict["currentProgress"] as? Int ?? 0
        )
    }

    public func fetchListenRecords(weekly: Bool) async throws -> [ListenRecord] {
        guard let userID = try KeychainStore.shared.load(for: .neteaseUserID) else {
            throw MusicError.notLoggedIn
        }
        let cookie = try await requireLoginCookie()
        // type 0 = 全部时间，1 = 最近一周；数组是 allData / weekData
        let data = try await request("/user/record", query: [
            "uid": userID, "type": weekly ? "1" : "0",
        ], cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        let list = (json[weekly ? "weekData" : "allData"] as? [[String: Any]]) ?? []
        return list.compactMap { item in
            // 歌曲裹在 `song` 里，不是平铺
            guard let songDict = item["song"] as? [String: Any],
                  let song = Self.mapSong(songDict) else { return nil }
            return ListenRecord(
                song: song,
                playCount: item["score"] as? Int ?? item["count"] as? Int ?? 0,
                lastPlayedAt: Self.date(fromMilliseconds: item["playTime"])
            )
        }
        .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    public func dailySignIn() async throws -> SignInResult {
        let cookie = try await requireLoginCookie()
        let json = try parseJSON(
            try await request("/daily_signin", query: ["type": "0"],
                              cookie: cookie, method: "POST")
        )
        // -2 = 今天已经签过；这不算失败，UI 上要显示成「今日已打卡」
        if json["code"] as? Int == -2 { return .alreadySigned }
        try requireWriteSucceeded(json, action: "打卡")
        return .success(point: json["point"] as? Int ?? 0)
    }

    /// 收藏数量汇总。
    ///
    /// ## 实测结构：计数在**顶层**，没有 `profile` 包裹
    ///
    /// 可用的键只有 6 个：`createdPlaylistCount`（我创建的歌单）、
    /// `subPlaylistCount`（收藏的歌单）、`artistCount`、`djRadioCount`、
    /// `programCount`、`mvCount`。
    /// **`albumCount` / `listenSongCount` / `playlistCount` 并不存在** ——
    /// 按 `home.md` 描述去读 `profile` 会直接抛 invalidResponse。
    public func fetchUserCounts() async throws -> [String: Int] {
        let cookie = try await requireLoginCookie()
        let data = try await request("/user/subcount", cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        guard json["code"] != nil else { throw MusicError.invalidResponse }
        return [
            "创建歌单": Self.intValue(json["createdPlaylistCount"]) ?? 0,
            "收藏歌单": Self.intValue(json["subPlaylistCount"]) ?? 0,
            "关注歌手": Self.intValue(json["artistCount"]) ?? 0,
            "收藏电台": Self.intValue(json["djRadioCount"]) ?? 0,
            "节目": Self.intValue(json["programCount"]) ?? 0,
            "MV": Self.intValue(json["mvCount"]) ?? 0,
        ]
    }

    // MARK: - 工具

    // `Any?` 上的 `??` 与 `as?` 组合会让 Swift 6 的类型检查器崩掉
    // （"failed to produce diagnostic"），统一走这三个显式取值函数。
    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as Int64: return Int(n)
        case let n as Double: return Int(n)
        case let s as String: return Int(s)
        default: return nil
        }
    }

    /// 归一成字符串形式（id 可能是 Int / Int64 / String）
    private static func anyValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s.isEmpty ? nil : s }
        return String(describing: value)
    }

    /// 网易云的时间戳基本都是**毫秒**，且可能是字符串
    private static func date(fromMilliseconds value: Any?) -> Date {
        guard let ms = int64(value) else { return Date() }
        // 有的接口（如 user/record 的 playTime）已经是秒
        return ms > 100_000_000_000
            ? Date(timeIntervalSince1970: Double(ms) / 1000)
            : Date(timeIntervalSince1970: Double(ms))
    }

    /// internal 而非 private：`NeteaseArtistProvider.swift` 里的
    /// `mapArtistMV` 也要用同一个容错解析（同一模块的另一个 extension）。
    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as Double: return Int64(n)
        case let s as String: return Int64(s)
        default: return nil
        }
    }
}
