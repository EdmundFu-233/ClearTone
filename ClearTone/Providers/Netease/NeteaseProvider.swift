import Foundation

/// 通过本地辅助进程访问网易云 API
public actor NeteaseProvider: MusicProvider {
    public let identifier = "netease"
    public let displayName = "网易云音乐"

    /// 全局共享实例：让内存缓存跨视图复用（各页面原本各建一个实例，缓存互不相通）
    public static let shared = NeteaseProvider()

    private let session: URLSession
    private let decoder: JSONDecoder

    // MARK: - 响应缓存

    private struct CacheEntry {
        let data: Data
        let expiresAt: Date
    }

    /// 只读接口的短时缓存，避免页面来回切换重复请求；写操作后按前缀失效
    private var responseCache: [String: CacheEntry] = [:]
    private var responseCacheBytes = 0

    /// 缓存硬上限。原先的 256 只是「触发 prune 的阈值」而非上限 ——
    /// pruneExpiredCache 只删过期项，写入速率高于过期速率时字典单调增长
    /// （一个 1000 首歌单 10 页约 1.5MB），最坏可达数百 MB 后被 jetsam 杀掉。
    private static let responseCacheEntryLimit = 128
    private static let responseCacheByteLimit = 32 * 1024 * 1024

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        // 不做 cookie 持久化：网易云凭据一律走 X-CT-Cookie 头传给辅助进程。
        // 若保留默认 cookie 存储，URLSession 会在 ~/Library/HTTPStorages/com.cleartone.app
        // 建容器目录，而该目录会被 LaunchServices 误注册成 com.cleartone.app 这个 bundle，
        // 顶掉真正的 App 注册，导致 Finder/Dock 显示通用图标。
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    #if os(macOS)
    @MainActor
    private var helper: HelperProcessManager { HelperProcessManager.shared }
    #endif

    // MARK: - 认证

    public func fetchQRCodeKey() async throws -> String {
        // randomCNIP：辅助进程从本机回环访问时，用随机中国 IP 填充 X-Real-IP，
        // 避免网易云风控将登录环境判定为异常（手机扫码报“设备环境异常”）
        let data = try await request("/login/qr/key", query: ["randomCNIP": "true"])
        let json = try parseJSON(data)
        guard let unikey = json["data"] as? [String: Any],
              let key = unikey["unikey"] as? String else {
            throw MusicError.invalidResponse
        }
        return key
    }

    public func fetchQRCodeImage(key: String) async throws -> URL {
        // qrimg 接口返回 base64 图片，但 api-enhanced 的 /login/qr/create 直接返回 qrimg URL
        let data = try await request("/login/qr/create", query: ["key": key, "qrimg": "true"])
        let json = try parseJSON(data)
        guard let dataDict = json["data"] as? [String: Any],
              let qrimg = dataDict["qrimg"] as? String,
              let url = URL(string: qrimg) else {
            throw MusicError.invalidResponse
        }
        return url
    }

    public func checkQRCodeStatus(key: String) async throws -> QRLoginStatus {
        // timestamp 保证每次轮询的 URL 不同，避免辅助进程 apicache 缓存旧的扫码状态（2 分钟）
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let data = try await request("/login/qr/check", query: ["key": key, "timestamp": timestamp, "randomCNIP": "true"])
        let json = try parseJSON(data)
        guard let code = json["code"] as? Int else { throw MusicError.invalidResponse }

        switch code {
        case 800: return .expired
        case 801: return .waitingScan
        case 802: return .scannedWaitingConfirm
        case 803:
            guard let cookie = json["cookie"] as? String else { throw MusicError.invalidResponse }
            return .success(cookie: cookie)
        default:
            return .failed(json["message"] as? String ?? "未知错误")
        }
    }

    public func logout() async throws {
        // 无论服务端登出是否成功，都必须清除本地凭据，否则下次启动会自动重新登录
        defer {
            try? KeychainStore.shared.delete(for: .neteaseCookie)
            try? KeychainStore.shared.delete(for: .neteaseUserID)
            clearCache()
        }
        let cookie = (try? KeychainStore.shared.load(for: .neteaseCookie)) ?? nil
        _ = try await request("/logout", cookie: cookie, method: "POST")
    }

    public func fetchAccountInfo() async throws -> AccountInfo? {
        guard let cookie = try KeychainStore.shared.load(for: .neteaseCookie) else { return nil }
        let data = try await request("/user/account", cookie: cookie)
        let json = try parseJSON(data)
        guard let account = json["account"] as? [String: Any],
              let profile = json["profile"] as? [String: Any] else { return nil }

        let userID = String(describing: account["id"] ?? "")
        let nickname = profile["nickname"] as? String ?? "未知用户"
        let avatarURL = (profile["avatarUrl"] as? String).flatMap(URL.init)
        let vipType = account["vipType"] as? Int ?? 0
        return AccountInfo(userID: userID, nickname: nickname, avatarURL: avatarURL, isVIP: vipType > 0)
    }

    // MARK: - 搜索

    public func search(query: String, type: SearchType, page: Int, limit: Int) async throws -> SearchResult {
        let typeCode: Int
        switch type {
        case .song: typeCode = 1
        case .artist: typeCode = 100
        case .album: typeCode = 10
        case .playlist: typeCode = 1000
        }

        let data = try await request("/cloudsearch", query: [
            "keywords": query,
            "type": String(typeCode),
            "limit": String(limit),
            "offset": String((page - 1) * limit),
        ], cacheTTL: 120)
        let json = try parseJSON(data)
        guard let result = json["result"] as? [String: Any] else { throw MusicError.invalidResponse }

        var searchResult = SearchResult()

        switch type {
        case .song:
            if let songs = result["songs"] as? [[String: Any]] {
                searchResult.songs = songs.compactMap { mapSong($0) }
            }
            searchResult.totalCount = result["songCount"] as? Int ?? 0
        case .artist:
            if let artists = result["artists"] as? [[String: Any]] {
                searchResult.artists = artists.map { mapArtist($0) }
            }
            searchResult.totalCount = result["artistCount"] as? Int ?? 0
        case .album:
            if let albums = result["albums"] as? [[String: Any]] {
                searchResult.albums = albums.map { mapAlbum($0) }
            }
            searchResult.totalCount = result["albumCount"] as? Int ?? 0
        case .playlist:
            if let playlists = result["playlists"] as? [[String: Any]] {
                searchResult.playlists = playlists.map { mapPlaylist($0) }
            }
            searchResult.totalCount = result["playlistCount"] as? Int ?? 0
        }

        searchResult.hasMore = (result["hasMore"] as? Bool) ?? (page * limit < searchResult.totalCount)
        return searchResult
    }

    // MARK: - 歌单/专辑

    public func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail {
        let cookie = try KeychainStore.shared.load(for: .neteaseCookie) ?? ""
        let data = try await request("/playlist/detail", query: ["id": id], cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        guard let playlistDict = json["playlist"] as? [String: Any] else { throw MusicError.invalidResponse }

        let playlist = mapPlaylist(playlistDict)
        let trackIds = (playlistDict["trackIds"] as? [[String: Any]])?.compactMap { $0["id"] } ?? []
        let totalCount = playlistDict["trackCount"] as? Int ?? trackIds.count

        // 只取前 50 首用于展示，完整分页用 fetchPlaylistTracks
        let tracks = (playlistDict["tracks"] as? [[String: Any]])?.compactMap { mapSong($0) } ?? []

        return PlaylistDetail(playlist: playlist, tracks: tracks, totalTrackCount: totalCount)
    }

    public func fetchPlaylistTracks(id: String, page: Int, limit: Int) async throws -> [Song] {
        let cookie = try KeychainStore.shared.load(for: .neteaseCookie) ?? ""
        let data = try await request("/playlist/track/all", query: [
            "id": id,
            "limit": String(limit),
            "offset": String((page - 1) * limit),
        ], cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        guard let songs = json["songs"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return songs.compactMap { mapSong($0) }
    }

    /// 已完整拉取过的歌单曲目：命中则完全不发请求，二次进入歌单瞬时显示
    private var playlistTrackCache: [String: (songs: [Song], cachedAt: Date)] = [:]

    /// 歌单曲目缓存有效期（内存态，避免每次重进都重新请求）
    private static let playlistTrackCacheTTL: TimeInterval = 600
    /// 歌单整表缓存的条数上限（每个 1000 首歌单约上千个 Song 对象）
    private static let playlistTrackCacheLimit = 8

    public func cachedPlaylistTracks(id: String) -> [Song]? {
        guard let entry = playlistTrackCache[id],
              Date().timeIntervalSince(entry.cachedAt) < Self.playlistTrackCacheTTL else {
            playlistTrackCache[id] = nil
            return nil
        }
        return entry.songs
    }

    private func storePlaylistTracks(_ songs: [Song], for id: String) {
        playlistTrackCache[id] = (songs, Date())
        // 硬上限：原实现只在 >16 后按 TTL 过滤，若都未过期则无限增长
        guard playlistTrackCache.count > Self.playlistTrackCacheLimit else { return }
        let ordered = playlistTrackCache.sorted { $0.value.cachedAt < $1.value.cachedAt }
        let overflow = playlistTrackCache.count - Self.playlistTrackCacheLimit
        for (key, _) in ordered.prefix(overflow) {
            playlistTrackCache.removeValue(forKey: key)
        }
    }

    /// 歌单曲目分页并发拉取：最多 maxConcurrent 个请求同时进行，按页序 yield，调用方可边收边渲染。
    /// 原实现串行分页（单页约 2s，1000 首歌单需 20s+），并发后同一数据约 1/4 等待时间。
    public func streamPlaylistTracks(
        id: String,
        totalCount: Int,
        pageSize: Int = 100,
        maxConcurrent: Int = 4
    ) -> AsyncThrowingStream<[Song], Error> {
        let pageCount = max(1, Int(ceil(Double(totalCount) / Double(pageSize))))
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var assembled: [Song] = []
                var bufferedPages: [Int: [Song]] = [:]
                do {
                    try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
                        var nextToStart = 1
                        while nextToStart <= pageCount && nextToStart <= maxConcurrent {
                            let page = nextToStart
                            group.addTask {
                                (page, try await self.fetchPlaylistTracks(id: id, page: page, limit: pageSize))
                            }
                            nextToStart += 1
                        }
                        var nextToYield = 1
                        while let (page, songs) = try await group.next() {
                            // 后到的页先存着，等前面的页到齐再按顺序输出，保证列表顺序正确
                            if page == nextToYield {
                                assembled.append(contentsOf: songs)
                                continuation.yield(songs)
                                nextToYield += 1
                                while let buffered = bufferedPages.removeValue(forKey: nextToYield) {
                                    assembled.append(contentsOf: buffered)
                                    continuation.yield(buffered)
                                    nextToYield += 1
                                }
                            } else {
                                bufferedPages[page] = songs
                            }
                            if nextToStart <= pageCount {
                                let page = nextToStart
                                group.addTask {
                                    (page, try await self.fetchPlaylistTracks(id: id, page: page, limit: pageSize))
                                }
                                nextToStart += 1
                            }
                        }
                    }
                    await self.storePlaylistTracks(assembled, for: id)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func fetchAlbumDetail(id: String) async throws -> PlaylistDetail {
        let data = try await request("/album", query: ["id": id], cacheTTL: 600)
        let json = try parseJSON(data)
        guard let albumDict = json["album"] as? [String: Any] else { throw MusicError.invalidResponse }
        let album = mapAlbum(albumDict)
        let songs = (json["songs"] as? [[String: Any]])?.compactMap { mapSong($0) } ?? []

        let playlist = Playlist(
            id: album.id, name: album.name, coverURL: album.coverURL,
            trackCount: songs.count, creatorName: (albumDict["artist"] as? [String: Any])?["name"] as? String,
            source: .netease
        )
        return PlaylistDetail(playlist: playlist, tracks: songs, totalTrackCount: songs.count)
    }

    public func fetchArtistDetail(id: String) async throws -> ArtistDetail {
        let data = try await request("/artist/detail", query: ["id": id], cacheTTL: 600)
        let json = try parseJSON(data)
        guard let artistDict = json["data"] as? [String: Any],
              let artistInfo = artistDict["artist"] as? [String: Any] else { throw MusicError.invalidResponse }
        let artist = mapArtist(artistInfo)

        let songsData = try await request("/artist/top/song", query: ["id": id], cacheTTL: 600)
        let songsJSON = try parseJSON(songsData)
        let hotSongs = (songsJSON["songs"] as? [[String: Any]])?.compactMap { mapSong($0) } ?? []

        let albumsData = try await request("/artist/album", query: ["id": id, "limit": "20"], cacheTTL: 600)
        let albumsJSON = try parseJSON(albumsData)
        let albums = (albumsJSON["hotAlbums"] as? [[String: Any]])?.map { mapAlbum($0) } ?? []

        return ArtistDetail(artist: artist, hotSongs: hotSongs, albums: albums)
    }

    // MARK: - 播放地址

    public func fetchPlayableURL(songID: String, quality: AudioQuality.QualityLevel) async throws -> PlayableURL {
        let cookie = try KeychainStore.shared.load(for: .neteaseCookie) ?? ""
        let level: String
        switch quality {
        case .standard: level = "standard"
        case .higher: level = "higher"
        case .exhigh: level = "exhigh"
        case .lossless: level = "lossless"
        case .hires: level = "hires"
        case .unknown: level = "standard"
        }

        // 1) 标准信道：仅当可达且不是 30 秒试听流（br=128012）时采用，
        //    这样 VIP 用户和免费歌曲能拿到对应音质
        var standardURL: URL?
        var standardQuality: AudioQuality?
        var standardIsPreview = false
        do {
            let data = try await request("/song/url/v1", query: ["id": songID, "level": level], cookie: cookie, cacheTTL: 240)
            let json = try parseJSON(data)
            if let dataArray = json["data"] as? [[String: Any]],
               let first = dataArray.first,
               let urlString = first["url"] as? String,
               let raw = URL(string: urlString) {
                let primary = upgradeToHTTPS(raw) ?? raw
                let br = first["br"] as? Int
                // 试听流判定：接口在试听时返回 freeTrialInfo（如 end=30），
                // 且 br 会出现 128012 / 128018 这类“带后缀”的标记值
                let hasTrial = first["freeTrialInfo"] is [String: Any]
                let isPreview = hasTrial || br == 128012 || br == 128018
                standardURL = primary
                standardIsPreview = isPreview
                standardQuality = AudioQuality(
                    level: mapQualityLevel(first["level"] as? String),
                    bitrate: br.map { $0 / 1000 },
                    sampleRate: first["sr"] as? Int,
                    bitDepth: nil,
                    isActual: true
                )
                if !isPreview, await isStreamReachable(primary) {
                    return PlayableURL(url: primary, quality: standardQuality!)
                }
            }
        } catch {
            // 标准信道失败，继续走回退信道
        }

        // 2) 解灰信道：无 token 的 CDN 对象地址，返回完整歌曲文件且全球可访问。
        //    非 VIP 听版权歌曲时标准信道只给 30 秒试听，这里能拿到全曲。
        //
        //    串行遍历：unm 不通再试 gdmusic，行为可预期。
        //    曾试过 withTaskGroup 并发，两条探测会互相争抢带宽，冷启动时
        //    更容易双双超时，反而错过本来可用的一条。
        for source in ["unm", "gdmusic"] {
            if let matchURL = try? await fetchMatchURL(songID: songID, source: source),
               let upgraded = upgradeToHTTPS(matchURL),
               await isStreamReachable(upgraded) {
                let fallbackQuality = AudioQuality(level: .unknown, bitrate: nil, sampleRate: nil, bitDepth: nil, isActual: true)
                return PlayableURL(url: upgraded, quality: fallbackQuality)
            }
        }

        // 3) 最后兜底：原样返回标准地址，交给 AVPlayer 再试（避免预检误杀）。
        //    试听流仍标记 isPreview，调用方据此跳过音频缓存
        if let url = standardURL {
            let q = standardQuality ?? AudioQuality(level: .unknown, isActual: true)
            return PlayableURL(url: url, quality: q, isPreview: standardIsPreview)
        }
        throw MusicError.noPlayableURL
    }

    private func fetchMatchURL(songID: String, source: String?) async throws -> URL? {
        let cookie = try KeychainStore.shared.load(for: .neteaseCookie) ?? ""
        var query: [String: String] = ["id": songID]
        if let source, !source.isEmpty { query["source"] = source }
        let data = try await request("/song/url/match", query: query, cookie: cookie, cacheTTL: 240)
        let json = try parseJSON(data)
        guard let urlString = json["data"] as? String, let url = URL(string: urlString) else { return nil }
        return url
    }

    /// 纯字符串处理，可在 actor 外的并发子任务里调用
    private nonisolated func upgradeToHTTPS(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http" else { return url }
        return URL(string: url.absoluteString.replacingOccurrences(of: "http://", with: "https://", options: .anchored))
    }

    /// 轻量预检：Range 取 1 字节，仅验证 CDN 可达性；
    /// 用 bytes 流而非 data，响应头到达后立即取消，避免 CDN 忽略 Range 时下载整首歌
    /// 可达性探测结果的短期记忆。
    ///
    /// 只记成功：缓存命中（TTL 240s）也要付一次探测，连播时逐首累积。
    /// 失败**不记**，网络抖动恢复后能立刻重试。
    private var reachCache: [String: Date] = [:]
    private static let reachCacheTTL: TimeInterval = 180

    /// 可达性探测。
    ///
    /// 超时保持 4s：实测这台机器上冷启动的 CDN 探测（DNS + TLS + Range）需要
    /// 1.3~1.7s。曾收紧到 1.5s，结果探测几乎必然失败、完整播放地址被判死，
    /// 退回 30 秒试听流。这是实测数据，不要再动。
    private func isStreamReachable(_ url: URL) async -> Bool {
        let key = url.absoluteString
        if let at = reachCache[key],
           Date().timeIntervalSince(at) < Self.reachCacheTTL {
            return true
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 4
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { return false }
            let ok = (200...299).contains(http.statusCode)
            if ok { reachCache[key] = Date() }
            return ok
        } catch {
            // 失败不记忆：网络问题恢复后应该重试
            return false
        }
    }

    // MARK: - 歌词

    public func fetchLyrics(songID: String) async throws -> LyricResult {
        let cookie = try KeychainStore.shared.load(for: .neteaseCookie) ?? ""
        let data = try await request("/lyric/new", query: ["id": songID], cookie: cookie, cacheTTL: 1800)
        let json = try parseJSON(data)

        let lrc = (json["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        let tlyric = (json["tlyric"] as? [String: Any])?["lyric"] as? String
        let romalrc = (json["romalrc"] as? [String: Any])?["lyric"] as? String
        let yrc = (json["yrc"] as? [String: Any])?["lyric"] as? String

        let isPureMusic = lrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (yrc?.isEmpty ?? true)

        // 优先使用逐字 YRC
        if let yrcText = yrc, !yrcText.isEmpty {
            let lines = LRCParser.parseYRC(yrcText, translation: tlyric, romanization: romalrc)
            return LyricResult(lines: lines, hasWordTiming: true, isPureMusic: false)
        }

        let lines = LRCParser.parse(lrc, translation: tlyric, romanization: romalrc)
        return LyricResult(lines: lines, hasWordTiming: false, isPureMusic: isPureMusic)
    }

    // MARK: - 用户数据

    public func fetchUserPlaylists() async throws -> [Playlist] {
        guard let cookie = try KeychainStore.shared.load(for: .neteaseCookie) else { throw MusicError.notLoggedIn }
        guard let userID = try KeychainStore.shared.load(for: .neteaseUserID) else { throw MusicError.notLoggedIn }
        let data = try await request("/user/playlist", query: ["uid": userID], cookie: cookie, cacheTTL: 120)
        let json = try parseJSON(data)
        guard let playlists = json["playlist"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return playlists.map { mapPlaylist($0) }
    }

    /// 喜欢列表的**全量**歌曲 id。
    ///
    /// 这是判断「心形是否点亮」的唯一依据，必须完整：早期实现只取前 500 个 id
    /// 去查详情，导致 likedIDs 只有 500 项，排在 501 名之后的歌被误判为未收藏，
    /// 表现为「点了收藏没反应 / 加不进去」。
    /// 这里只取 id（2808 个约 60KB），很轻，不需要 song/detail。
    public func fetchLikedSongIDs() async throws -> [String] {
        guard let cookie = try KeychainStore.shared.load(for: .neteaseCookie) else { throw MusicError.notLoggedIn }
        guard let userID = try KeychainStore.shared.load(for: .neteaseUserID) else { throw MusicError.notLoggedIn }
        let data = try await request("/likelist", query: ["uid": userID], cookie: cookie, cacheTTL: 60)
        let json = try parseJSON(data)
        guard let ids = json["ids"] as? [Int64] else { throw MusicError.invalidResponse }
        return ids.map(String.init)
    }

    /// `/song/detail` 单次 ids 的上限，拼接过长会超出 URL 长度限制
    private static let detailBatchSize = 500

    /// 喜欢列表的完整曲目（分批拉取，用于列表展示）。
    /// 2808 首约 6 批；List 是懒加载的，不会一次性构建所有行。
    public func fetchLikedSongs() async throws -> [Song] {
        let idStrings = try await fetchLikedSongIDs()
        guard !idStrings.isEmpty else { return [] }
        let cookie = try KeychainStore.shared.load(for: .neteaseCookie)

        var result: [Song] = []
        result.reserveCapacity(idStrings.count)
        // 保持 /likelist 的 id 顺序 —— 那就是用户的收藏时间序
        for start in stride(from: 0, to: idStrings.count, by: Self.detailBatchSize) {
            let end = min(start + Self.detailBatchSize, idStrings.count)
            let batch = Array(idStrings[start..<end])
            let detailData = try await request(
                "/song/detail", query: ["ids": batch.joined(separator: ",")],
                cookie: cookie, cacheTTL: 300
            )
            guard let songs = (try parseJSON(detailData)["songs"] as? [[String: Any]]) else { continue }
            result.append(contentsOf: songs.compactMap { mapSong($0) })
        }
        return result
    }

    public func likeSong(id: String, like: Bool) async throws {
        guard let cookie = try KeychainStore.shared.load(for: .neteaseCookie) else { throw MusicError.notLoggedIn }
        // 必须用 POST：用 GET 调 /like 网易云会返回
        // code 524「当前环境异常，已取消喜欢」，表现为「点收藏没反应」
        let data = try await request("/like", query: ["id": id, "like": like ? "true" : "false"],
                                     cookie: cookie, method: "POST")
        let json = try parseJSON(data)
        guard let code = json["code"] as? Int, code == 200 else {
            throw MusicError.apiError(code: json["code"] as? Int ?? -1, message: json["message"] as? String ?? "操作失败")
        }
        // 收藏状态变化会反映到歌单曲目元数据与用户歌单计数，
        // 只清 /likelist 会让这些最长 300s 不更新
        invalidateCache(pathPrefixes: ["/likelist", "/song/detail", "/user/playlist", "/playlist/detail"])
    }

    public func fetchRecommendPlaylists() async throws -> [Playlist] {
        let cookie = try KeychainStore.shared.load(for: .neteaseCookie) ?? ""
        let data = try await request("/personalized", query: ["limit": "20"], cookie: cookie, cacheTTL: 600)
        let json = try parseJSON(data)
        guard let result = json["result"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return result.map { mapPlaylist($0) }
    }

    public func fetchDailyRecommendSongs() async throws -> [Song] {
        guard let cookie = try KeychainStore.shared.load(for: .neteaseCookie) else { throw MusicError.notLoggedIn }
        let data = try await request("/recommend/songs", cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        guard let dataDict = json["data"] as? [String: Any],
              let dailySongs = dataDict["dailySongs"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return dailySongs.compactMap { mapSong($0) }
    }

    // MARK: - 电台（DJ / 播客）

    /// 电台分类。注意响应是**顶层** `categories`，不在 result/data 里。
    public func fetchRadioCategories() async throws -> [RadioCategory] {
        let data = try await request("/dj/catelist", cacheTTL: 3600)
        let json = try parseJSON(data)
        guard let categories = json["categories"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return categories.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let id = String(describing: dict["id"] ?? "")
            // 二级分类名，用于 dj/hot?cat=
            let subs = (dict["sub"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String } ?? []
            return RadioCategory(id: id, name: name, subCategories: subs)
        }
    }

    /// 精选电台推荐。响应 `djRadios` 在顶层。
    public func fetchRecommendedRadios(limit: Int = 30) async throws -> [RadioStation] {
        let data = try await request("/dj/recommend", query: ["limit": String(limit)], cacheTTL: 600)
        return try parseRadioStations(data)
    }

    /// 热门电台，可按分类筛选。`categoryID` 传 nil 表示全部分类。
    public func fetchHotRadios(categoryID: String? = nil, limit: Int = 30) async throws -> [RadioStation] {
        var query = ["limit": String(limit)]
        if let categoryID, !categoryID.isEmpty { query["cat"] = categoryID }
        let data = try await request("/dj/hot", query: query, cacheTTL: 600)
        return try parseRadioStations(data)
    }

    private func parseRadioStations(_ data: Data) throws -> [RadioStation] {
        let json = try parseJSON(data)
        guard let radios = json["djRadios"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return radios.compactMap { mapRadioStation($0) }
    }

    private func mapRadioStation(_ dict: [String: Any]) -> RadioStation? {
        guard let id = dict["id"] else { return nil }
        let dj = dict["dj"] as? [String: Any] ?? [:]
        return RadioStation(
            id: String(describing: id),
            name: dict["name"] as? String ?? "未命名电台",
            coverURL: (dict["picUrl"] as? String).flatMap(URL.init),
            programCount: (dict["programCount"] as? Int) ?? 0,
            subscriberCount: (dict["subCount"] as? Int) ?? 0,
            creatorName: dj["nickname"] as? String,
            categoryName: dict["categoryName"] as? String,
            descriptionText: dict["desc"] as? String,
            isSubscribed: (dict["isSub"] as? Int) == 1
        )
    }

    /// 电台节目列表。
    ///
    /// 两个容易踩的坑（均已实测）：
    /// 1. 参数是 `rid` 不是 `id`（`id` 会返回「参数错误」）
    /// 2. `programs` 在**顶层**，不是 `data.programs`
    public func fetchRadioPrograms(radioID: String, page: Int = 1, limit: Int = 30) async throws -> [RadioProgram] {
        let offset = (page - 1) * limit
        let data = try await request("/dj/program", query: [
            "rid": radioID, "limit": String(limit), "offset": String(offset),
        ], cacheTTL: 300)
        let json = try parseJSON(data)
        guard let programs = json["programs"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return programs.compactMap { mapRadioProgram($0, stationName: nil) }
    }

    private func mapRadioProgram(_ dict: [String: Any], stationName: String?) -> RadioProgram? {
        guard let id = dict["id"] else { return nil }
        // 节目自带 mainSong，结构与标准歌曲一致，直接复用 mapSong
        let mainSong = dict["mainSong"] as? [String: Any]
        let song = mainSong.flatMap { mapSong($0) }
        // 时长是毫秒；节目级 duration 优先，缺失时取歌曲的
        let durationMs = (dict["duration"] as? Int)
            ?? (mainSong?["duration"] as? Int)
            ?? 0
        return RadioProgram(
            id: String(describing: id),
            title: dict["name"] as? String ?? song?.title ?? "未命名节目",
            // 节目封面实测常为空，回退用主音频的专辑封面
            coverURL: (dict["coverImgUrl"] as? String).flatMap(URL.init) ?? song?.coverURL,
            duration: TimeInterval(durationMs) / 1000,
            createTime: (dict["createTime"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0 / 1000)) },
            playCount: (dict["playCount"] as? Int) ?? 0,
            stationName: stationName,
            song: song
        )
    }

    // MARK: - 网络请求基础

    /// 发起请求。
    ///
    /// `method` 默认 GET。**写操作必须显式传 "POST"**：
    /// 网易云对 `/like` 这类写接口用 GET 调用时会返回
    /// `code: 524 / 当前环境异常，已取消喜欢` —— 同一首歌、同一 cookie，
    /// POST 返回 200 而 GET 返回 524。请求方法错了会被当成风控请求而静默拒绝。
    private func request(
        _ path: String,
        query: [String: String] = [:],
        cookie: String? = nil,
        cacheTTL: TimeInterval? = nil,
        method: String = "GET"
    ) async throws -> Data {
        let cacheKey = Self.cacheKey(path: path, query: query, hasCookie: !(cookie ?? "").isEmpty)
        // 写操作永远不读缓存
        if method == "GET", let ttl = cacheTTL, ttl > 0,
           let entry = responseCache[cacheKey], entry.expiresAt > Date() {
            return entry.data
        }

        #if os(iOS)
        // iOS 无法拉起辅助进程（没有 Process()，且 node 是 macOS 二进制），
        // 改为直连：路由名翻译成网易云原始 uri，自行完成加密。
        let data = try await directRequest(
            path, query: query, cookie: cookie, cacheTTL: cacheTTL, method: method
        )
        return data
        #else
        try await helper.startIfNeeded()
        let url = try await helper.makeURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if method == "POST" {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        await helper.applyAuth(to: &request)

        // 通过 query 传递 cookie（辅助进程转发到网易云）
        // 通过自定义 header 传递 cookie，由辅助进程注入转发，避免出现在 URL 中
        if let cookie = cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "X-CT-Cookie")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MusicError.invalidResponse }
            // 网易云未登录时常见 301/401/403（部分接口 HTTP 200 + body code=301）
            if http.statusCode == 301 || http.statusCode == 401 || http.statusCode == 403 {
                throw sessionExpiredError()
            }
            if http.statusCode == 429 { throw MusicError.rateLimited }
            guard (200...299).contains(http.statusCode) else {
                throw MusicError.apiError(code: http.statusCode, message: "HTTP \(http.statusCode)")
            }
            // 会话失效的错误响应都是小包；大响应（如 100 首曲目）跳过整包反序列化，
            // 避免这里 JSONSerialization 一遍、调用方 parseJSON 再一遍的双重开销
            if data.count <= 64 * 1024,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["code"] as? Int) == 301 {
                throw sessionExpiredError()
            }
            if method == "GET", let ttl = cacheTTL, ttl > 0 {
                responseCacheBytes += data.count - (responseCache[cacheKey]?.data.count ?? 0)
                responseCache[cacheKey] = CacheEntry(data: data, expiresAt: Date().addingTimeInterval(ttl))
                enforceResponseCacheLimits()
            }
            return data
        } catch let error as URLError where error.code == .cancelled {
            throw MusicError.cancelled
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw MusicError.networkUnavailable
        } catch {
            if let musicError = error as? MusicError { throw musicError }
            throw MusicError.unknown(error.localizedDescription)
        }
        #endif
    }

    #if os(iOS)
    /// iOS 直连实现。
    ///
    /// 与辅助进程版的差异只有「谁来翻译路由名、谁来加密」，
    /// 缓存、错误映射、解析逻辑完全共用。
    private func directRequest(
        _ path: String,
        query: [String: String],
        cookie: String?,
        cacheTTL: TimeInterval?,
        method: String
    ) async throws -> Data {
        guard let endpoint = NeteaseEndpoint.endpoint(forRoute: path) else {
            // 未知路由显式失败：静默走错加密方式会得到「HTTP 200 空 body」
            CTLog.general.error("未映射的接口路由: \(CTLog.sanitize(path))")
            throw MusicError.apiError(code: -1, message: "接口未适配：\(path)")
        }

        let cacheKey = Self.cacheKey(
            path: path, query: query, hasCookie: !(cookie ?? "").isEmpty
        )

        // 辅助进程接受 GET/POST 两种；直连统一用 POST。
        // 写操作必须 POST（GET 时网易云返回 524/405）。
        let data: Data
        switch endpoint.crypto {
        case .plain:
            data = try await NeteaseDirectTransport.shared.plainAPI(
                endpoint.apiPath, params: query, cookie: cookie
            )
        case .weapi:
            data = try await NeteaseDirectTransport.shared.weapi(
                endpoint.apiPath, params: query, cookie: cookie
            )
        }

        // 会话失效：部分接口 HTTP 200 + body code=301
        if data.count <= 64 * 1024,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["code"] as? Int) == 301 {
            throw sessionExpiredError()
        }

        if method == "GET", let ttl = cacheTTL, ttl > 0 {
            responseCacheBytes += data.count - (responseCache[cacheKey]?.data.count ?? 0)
            responseCache[cacheKey] = CacheEntry(
                data: data, expiresAt: Date().addingTimeInterval(ttl)
            )
            enforceResponseCacheLimits()
        }
        return data
    }
    #endif

    private func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MusicError.invalidResponse
        }
        return json
    }

    /// 广播会话失效（AppState 监听后清理登录态并提示重新登录）
    private func sessionExpiredError() -> MusicError {
        // 会话失效后 cookie 可能被原地刷新（重新扫码换新 MUSIC_U，权限可能变化），
        // 不清缓存的话旧身份写入的条目会继续命中到 TTL 结束
        clearCache()
        NotificationCenter.default.post(name: .clearToneSessionExpired, object: nil)
        return MusicError.sessionExpired
    }

    // MARK: - 缓存维护

    private static func cacheKey(path: String, query: [String: String], hasCookie: Bool) -> String {
        let queryPart = query.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return "\(path)?\(queryPart)|\(hasCookie ? "auth" : "anon")"
    }

    private func pruneExpiredCache() {
        let now = Date()
        let before = responseCache
        responseCache = responseCache.filter { $0.value.expiresAt > now }
        responseCacheBytes -= before.reduce(0) { sum, entry in
            responseCache[entry.key] == nil ? sum + entry.value.data.count : sum
        }
        if responseCacheBytes < 0 { responseCacheBytes = 0 }
    }

    /// 硬上限：先清过期，再按最接近过期优先淘汰，直到同时满足条数与字节预算。
    /// 过期项每次都清（一次 filter，开销可忽略）：它们虽然不会被读取命中，
    /// 但不清理就会一直占着内存与字节预算。
    private func enforceResponseCacheLimits() {
        pruneExpiredCache()
        guard responseCache.count > Self.responseCacheEntryLimit
                || responseCacheBytes > Self.responseCacheByteLimit else { return }
        let ordered = responseCache.sorted { $0.value.expiresAt < $1.value.expiresAt }
        for (key, entry) in ordered {
            if responseCache.count <= Self.responseCacheEntryLimit,
               responseCacheBytes <= Self.responseCacheByteLimit { break }
            responseCache.removeValue(forKey: key)
            responseCacheBytes -= entry.data.count
        }
    }

    /// 按路径前缀失效缓存（写操作后调用）。
    /// 缓存键形如 "/path?query|auth"，直接 hasPrefix 会误伤：
    /// "/like" 会连带清掉 "/likelist"，"/user/playlist" 与 "/user/playlist/..." 互相误伤。
    public func invalidateCache(pathPrefixes: [String]) {
        for prefix in pathPrefixes {
            let hit = responseCache.keys.filter {
                let path = Self.path(ofCacheKey: $0)
                return path == prefix || path.hasPrefix(prefix + "/")
            }
            for key in hit {
                responseCacheBytes -= responseCache[key]?.data.count ?? 0
                responseCache.removeValue(forKey: key)
            }
        }
        if responseCacheBytes < 0 { responseCacheBytes = 0 }
    }

    /// 从缓存键里取出路径部分。注意两种分隔符都要处理：
    /// 有 query 时是 "/path?query|auth"，无 query 时是 "/path|auth" ——
    /// 只按 "?" 切分会让无 query 的键（如 "/likelist|auth"）永远匹配不上前缀。
    private static func path(ofCacheKey key: String) -> String {
        guard let cut = key.firstIndex(where: { $0 == "?" || $0 == "|" }) else { return key }
        return String(key[key.startIndex..<cut])
    }

    public func invalidateCache(pathPrefix: String) {
        invalidateCache(pathPrefixes: [pathPrefix])
    }

    /// 清空全部缓存（退出登录、会话失效等）
    public func clearCache() {
        responseCache.removeAll()
        responseCacheBytes = 0
        reachCache.removeAll()
    }

    // MARK: - 模型映射

    private func mapSong(_ dict: [String: Any]) -> Song? {
        guard let id = dict["id"] else { return nil }
        let idString = String(describing: id)
        let title = dict["name"] as? String ?? "未知歌曲"

        let artists = (dict["ar"] as? [[String: Any]]) ?? (dict["artists"] as? [[String: Any]]) ?? []
        let artistModels = artists.map { mapArtist($0) }

        var album: Album?
        if let al = dict["al"] as? [String: Any] {
            album = mapAlbum(al)
        } else if let albumDict = dict["album"] as? [String: Any] {
            album = mapAlbum(albumDict)
        }

        let duration = (dict["dt"] as? Double ?? dict["duration"] as? Double ?? 0) / 1000.0
        let coverURL = (dict["al"] as? [String: Any])?["picUrl"] as? String ?? (dict["album"] as? [String: Any])?["picUrl"] as? String

        let st = dict["st"] as? Int ?? 0
        let isPlayable = st >= 0
        var unavailableReason: String?
        if !isPlayable { unavailableReason = "歌曲已下架" }

        return Song(
            id: idString, title: title, artists: artistModels, album: album,
            duration: duration, coverURL: coverURL.flatMap(URL.init),
            isPlayable: isPlayable, unavailableReason: unavailableReason,
            source: .netease
        )
    }

    private func mapArtist(_ dict: [String: Any]) -> Artist {
        let id = String(describing: dict["id"] ?? "0")
        let name = dict["name"] as? String ?? "未知歌手"
        return Artist(id: id, name: name)
    }

    private func mapAlbum(_ dict: [String: Any]) -> Album {
        let id = String(describing: dict["id"] ?? "0")
        let name = dict["name"] as? String ?? "未知专辑"
        let coverURL = (dict["picUrl"] as? String).flatMap(URL.init)
        return Album(id: id, name: name, coverURL: coverURL)
    }

    private func mapPlaylist(_ dict: [String: Any]) -> Playlist {
        let id = String(describing: dict["id"] ?? "0")
        let name = dict["name"] as? String ?? "未知歌单"
        let coverURL = ((dict["coverImgUrl"] as? String) ?? (dict["picUrl"] as? String)).flatMap(URL.init)
        let trackCount = dict["trackCount"] as? Int ?? 0
        let creator = (dict["creator"] as? [String: Any])?["nickname"] as? String
        let description = dict["description"] as? String
        return Playlist(id: id, name: name, coverURL: coverURL, trackCount: trackCount,
                        creatorName: creator, descriptionText: description, source: .netease)
    }

    private func mapQualityLevel(_ level: String?) -> AudioQuality.QualityLevel {
        switch level {
        case "standard": return .standard
        case "higher": return .higher
        case "exhigh": return .exhigh
        case "lossless": return .lossless
        case "hires": return .hires
        default: return .unknown
        }
    }
}

#if os(macOS)
// MARK: - HelperProcessManager 便捷扩展
extension HelperProcessManager {
    @MainActor
    func startIfNeeded() async throws {
        switch state {
        case .running:
            return
        case .stopped, .starting, .failed:
            // start() 内部对进行中的启动做单飞等待，避免 `.starting` 时直接返回导致首个请求失败
            try await start()
        }
    }
}
#endif
