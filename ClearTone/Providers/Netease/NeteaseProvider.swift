import Foundation
import CryptoKit

/// macOS 通过本地辅助进程、iOS 通过原生加密传输访问网易云 API
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
    /// 清缓存后，旧的在途响应不能重新填回。失效操作也必须推进代次。
    private(set) var responseCacheGeneration = 0

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

    /// 收藏失败时给用户看的话。
    ///
    /// 服务端对 405 / 524 的原文（「操作过于频繁」「当前环境异常」）
    /// 都没说「别再点」—— 而这两个码是**限流**，用户看不懂就会继续点，
    /// 每一次重试都把限流窗口延长一点（实测 405/524 是账号级的，
    /// 连 `/playlist/subscribe` 都一起挂）。所以这里补一句可执行的建议。
    nonisolated static func likeFailureMessage(_ json: [String: Any]) -> String {
        let code = json["code"] as? Int ?? -1
        let serverText = (json["message"] ?? json["msg"]) as? String
        switch code {
        case 405, 524:
            let reason = serverText ?? "被网易云限流"
            return "\(reason)。这是账号级限流，连点只会让等待更久，请 \(Int(AppState.likeWriteCooldownSeconds)) 秒后再试一次"
        default:
            return serverText ?? "操作失败"
        }
    }

    // MARK: - 凭据读取

    /// 读网易云凭据，并顺带**归一化**。
    ///
    /// 归一化放在读路径而不是只在写入路径，是为了顺带修好**已经存脏的**
    /// 凭据：旧版本原样存了 `login_qr_check.js` 返回的 Set-Cookie 拼接串，
    /// 用户不必重新扫码就能受益。`normalize` 是幂等的，正常凭据不受影响。
    ///
    /// 全部 cookie 读取都必须走这里 —— 漏一处就等于往上游发一个
    /// 带 134 段（含 `Expires=...GMT` 这种未编码值）的畸形 Cookie 头。
    nonisolated static func loadLoginCookie() throws -> String? {
        // ⚠️ 这里必须直接读 KeychainStore，不能写成 `try Self.loadLoginCookie()`。
        // 批量替换读取点时曾把**这一行自己**也替换掉，于是变成无限递归，
        // 启动即栈溢出（`EXC_BAD_ACCESS` / SIGSEGV，崩溃栈全在
        // loadLoginCookie 里）。所以下面这一行不是冗余，它是唯一的出口。
        guard let raw = try KeychainStore.shared.load(for: .neteaseCookie) else { return nil }
        let normalized = NeteaseCookieNormalizer.normalize(raw)
        return normalized.isEmpty ? nil : normalized
    }

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
        #if os(iOS)
        // QR 图像在设备上生成，避免把登录 key 发送给第三方图片服务。
        return try NeteaseMobileRoute.qrURL(key: key)
        #else
        // qrimg 接口返回 base64 图片，但 api-enhanced 的 /login/qr/create 直接返回 qrimg URL
        let data = try await request("/login/qr/create", query: ["key": key, "qrimg": "true"])
        let json = try parseJSON(data)
        guard let dataDict = json["data"] as? [String: Any],
              let qrimg = dataDict["qrimg"] as? String,
              let url = URL(string: qrimg) else {
            throw MusicError.invalidResponse
        }
        return url
        #endif
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
            sessionGuard.reset()
            clearCache()
        }
        let cookie = try? Self.loadLoginCookie()
        _ = try await request("/logout", cookie: cookie, method: "POST")
    }

    /// 登录态换了人（扫码成功）时复位会话闸门，
    /// 否则新会话要背上旧会话攒下的疑似次数，第一次 301 就去打探针。
    public func resetSessionGuard() {
        sessionGuard.reset()
    }

    public func fetchAccountInfo() async throws -> AccountInfo? {
        guard let cookie = try Self.loadLoginCookie() else { return nil }
        return try await fetchAccountInfo(cookie: cookie)
    }

    /// 先验证临时登录凭据，再让调用方提交到钥匙串。
    func fetchAccountInfo(cookie: String) async throws -> AccountInfo? {
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
                searchResult.songs = songs.compactMap { Self.mapSong($0) }
            }
            searchResult.totalCount = result["songCount"] as? Int ?? 0
        case .artist:
            if let artists = result["artists"] as? [[String: Any]] {
                searchResult.artists = artists.map { Self.mapArtist($0) }
            }
            searchResult.totalCount = result["artistCount"] as? Int ?? 0
        case .album:
            if let albums = result["albums"] as? [[String: Any]] {
                searchResult.albums = albums.map { Self.mapAlbum($0) }
            }
            searchResult.totalCount = result["albumCount"] as? Int ?? 0
        case .playlist:
            if let playlists = result["playlists"] as? [[String: Any]] {
                searchResult.playlists = playlists.map { Self.mapPlaylist($0) }
            }
            searchResult.totalCount = result["playlistCount"] as? Int ?? 0
        }

        searchResult.hasMore = (result["hasMore"] as? Bool) ?? (page * limit < searchResult.totalCount)
        return searchResult
    }

    // MARK: - 歌单/专辑

    public func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail {
        let cookie = try Self.loadLoginCookie() ?? ""
        let data = try await request("/playlist/detail", query: ["id": id], cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        guard let playlistDict = json["playlist"] as? [String: Any] else { throw MusicError.invalidResponse }

        let playlist = Self.mapPlaylist(playlistDict)
        let trackIds = (playlistDict["trackIds"] as? [[String: Any]])?.compactMap { $0["id"] } ?? []
        let totalCount = playlistDict["trackCount"] as? Int ?? trackIds.count

        // 只取前 50 首用于展示，完整分页用 fetchPlaylistTracks
        let tracks = (playlistDict["tracks"] as? [[String: Any]])?.compactMap { Self.mapSong($0) } ?? []

        return PlaylistDetail(playlist: playlist, tracks: tracks, totalTrackCount: totalCount)
    }

    public func fetchPlaylistTracks(id: String, page: Int, limit: Int) async throws -> [Song] {
        let cookie = try Self.loadLoginCookie() ?? ""
        let data = try await request("/playlist/track/all", query: [
            "id": id,
            "limit": String(limit),
            "offset": String((page - 1) * limit),
        ], cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        guard let songs = json["songs"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return songs.compactMap { Self.mapSong($0) }
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
        let album = Self.mapAlbum(albumDict)
        let songs = (json["songs"] as? [[String: Any]])?.compactMap { Self.mapSong($0) } ?? []
        // 专辑的 `artist` 是完整的歌手对象（id + name + picUrl），不是字符串。
        // 只取 name 的话专辑页的歌手名就点不动 —— 那个按钮曾经是个空壳。
        let albumArtist = albumDict["artist"] as? [String: Any]
        let artistID = albumArtist.flatMap { dict -> String? in
            guard let raw = dict["id"] else { return nil }
            let value = String(describing: raw)
            return value == "0" ? nil : value
        }

        let playlist = Playlist(
            id: album.id, name: album.name, coverURL: album.coverURL,
            trackCount: songs.count, creatorName: albumArtist?["name"] as? String,
            source: .netease
        )
        return PlaylistDetail(playlist: playlist, tracks: songs,
                              totalTrackCount: songs.count, artistID: artistID)
    }

    public func fetchArtistDetail(id: String) async throws -> ArtistDetail {
        // 三个接口并发：串行要等 3 个 RTT，而它们互不依赖
        async let profileData = request("/artist/detail", query: ["id": id], cacheTTL: 600)
        async let songsData = request("/artist/top/song", query: ["id": id], cacheTTL: 600)
        async let albumsData = request("/artist/album", query: ["id": id, "limit": "20"], cacheTTL: 600)

        let json = try parseJSON(await profileData)
        guard let artistDict = json["data"] as? [String: Any],
              let artistInfo = artistDict["artist"] as? [String: Any] else { throw MusicError.invalidResponse }
        let artist = Self.mapArtist(artistInfo)

        let songsJSON = try parseJSON(await songsData)
        let hotSongs = (songsJSON["songs"] as? [[String: Any]])?.compactMap { Self.mapSong($0) } ?? []

        let albumsJSON = try parseJSON(await albumsData)
        let albums = (albumsJSON["hotAlbums"] as? [[String: Any]])?.map { Self.mapAlbum($0) } ?? []

        return ArtistDetail(artist: artist, hotSongs: hotSongs, albums: albums)
    }

    // MARK: - 播放地址

    public func fetchPlayableURL(songID: String, quality: AudioQuality.QualityLevel) async throws -> PlayableURL {
        let cookie = try Self.loadLoginCookie() ?? ""
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
        var standardSizeBytes: Int?
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
                // FLAC（level=lossless/hires）常常 br=0，只给 size。
                // 码率留给上层用 size×8/时长 反算，这里不拿 0 当码率。
                standardSizeBytes = first["size"] as? Int
                standardQuality = AudioQuality(
                    level: Self.mapQualityLevel(first["level"] as? String),
                    bitrate: br.map { $0 / 1000 }.flatMap { $0 > 0 ? $0 : nil },
                    sampleRate: first["sr"] as? Int,
                    bitDepth: nil,
                    isActual: true,
                    codec: Self.codecName(encodeType: first["encodeType"] as? String, url: primary)
                )
                if !isPreview, await isStreamReachable(primary) {
                    return PlayableURL(url: primary, quality: standardQuality!, sizeBytes: standardSizeBytes)
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
        #if os(macOS)
        for source in ["unm", "gdmusic"] {
            if let matchURL = try? await fetchMatchURL(songID: songID, source: source),
               let upgraded = upgradeToHTTPS(matchURL),
               await isStreamReachable(upgraded) {
                let fallbackQuality = AudioQuality(level: .unknown, bitrate: nil, sampleRate: nil, bitDepth: nil, isActual: true)
                return PlayableURL(url: upgraded, quality: fallbackQuality)
            }
        }

        #endif

        // 3) 最后兜底：原样返回标准地址，交给 AVPlayer 再试（避免预检误杀）。
        //    试听流仍标记 isPreview，调用方据此跳过音频缓存
        if let url = standardURL {
            let q = standardQuality ?? AudioQuality(level: .unknown, isActual: true)
            return PlayableURL(url: url, quality: q, isPreview: standardIsPreview, sizeBytes: standardSizeBytes)
        }
        throw MusicError.noPlayableURL
    }

    private func fetchMatchURL(songID: String, source: String?) async throws -> URL? {
        let cookie = try Self.loadLoginCookie() ?? ""
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
        let cookie = try Self.loadLoginCookie() ?? ""
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
        guard let cookie = try Self.loadLoginCookie() else { throw MusicError.notLoggedIn }
        guard let userID = try KeychainStore.shared.load(for: .neteaseUserID) else { throw MusicError.notLoggedIn }
        let data = try await request("/user/playlist", query: ["uid": userID], cookie: cookie, cacheTTL: 120)
        let json = try parseJSON(data)
        guard let playlists = json["playlist"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return playlists.map { Self.mapPlaylist($0) }
    }

    /// 喜欢列表的**全量**歌曲 id。
    ///
    /// 这是判断「心形是否点亮」的唯一依据，必须完整：早期实现只取前 500 个 id
    /// 去查详情，导致 likedIDs 只有 500 项，排在 501 名之后的歌被误判为未收藏，
    /// 表现为「点了收藏没反应 / 加不进去」。
    /// 这里只取 id（2808 个约 60KB），很轻，不需要 song/detail。
    public func fetchLikedSongIDs() async throws -> [String] {
        guard let cookie = try Self.loadLoginCookie() else { throw MusicError.notLoggedIn }
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
        let cookie = try Self.loadLoginCookie()

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
            result.append(contentsOf: songs.compactMap { Self.mapSong($0) })
        }
        return result
    }

    public func likeSong(id: String, like: Bool) async throws {
        let cookie = try Self.loadLoginCookie() ?? ""
        guard !cookie.isEmpty else { throw MusicError.notLoggedIn }
        guard let userID = try KeychainStore.shared.load(for: .neteaseUserID), !userID.isEmpty else {
            throw MusicError.notLoggedIn
        }
        // 走 `/song/like`（eapi），不再走 `/like`（weapi `/api/radio/like`）。
        //
        // 原因：weapi 写接口在辅助进程**匿名标识注册失败**时会被网易云按风控
        // 拒掉，症状是稳定返回 `code 301`（实测：辅助进程启动时
        // `register_anonimous` 抛 "xeapi public key is missing"，
        // 同一实例上 /like 连续三次 301，而 /user/account、/likelist 全都 200）。
        // eapi 那条在同一 cookie 下实测 200，且不依赖 weapi 的客户端标识。
        //
        // 参数名是 module 里定的：`song_like.js` 读 `query.id`/`query.uid`，
        // 映射到上游 data 的 `trackId`/`userid`。
        let data = try await request("/song/like", query: [
            "id": id, "uid": userID, "like": like ? "true" : "false",
        ], cookie: cookie, method: "POST")
        let json = try parseJSON(data)
        guard let code = json["code"] as? Int, code == 200 else {
            throw MusicError.apiError(code: json["code"] as? Int ?? -1,
                                     message: Self.likeFailureMessage(json))
        }
        // 收藏状态变化会反映到歌单曲目元数据与用户歌单计数，
        // 只清 /likelist 会让这些最长 300s 不更新
        invalidateCache(pathPrefixes: ["/likelist", "/song/detail", "/user/playlist", "/playlist/detail"])
    }

    public func fetchRecommendPlaylists() async throws -> [Playlist] {
        let cookie = try Self.loadLoginCookie() ?? ""
        let data = try await request("/personalized", query: ["limit": "20"], cookie: cookie, cacheTTL: 600)
        let json = try parseJSON(data)
        guard let result = json["result"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return result.map { Self.mapPlaylist($0) }
    }

    public func fetchDailyRecommendSongs() async throws -> [Song] {
        guard let cookie = try Self.loadLoginCookie() else { throw MusicError.notLoggedIn }
        let data = try await request("/recommend/songs", cookie: cookie, cacheTTL: 300)
        let json = try parseJSON(data)
        guard let dataDict = json["data"] as? [String: Any],
              let dailySongs = dataDict["dailySongs"] as? [[String: Any]] else { throw MusicError.invalidResponse }
        return dailySongs.compactMap { Self.mapSong($0) }
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
        return radios.compactMap { Self.mapRadioStation($0) }
    }

    nonisolated static func mapRadioStation(_ dict: [String: Any]) -> RadioStation? {
        guard let id = dict["id"] else { return nil }
        let dj = dict["dj"] as? [String: Any] ?? [:]
        return RadioStation(
            id: String(describing: id),
            name: dict["name"] as? String ?? "未命名电台",
            coverURL: (dict["picUrl"] as? String).flatMap(URL.init),
            programCount: (dict["programCount"] as? Int) ?? 0,
            subscriberCount: (dict["subCount"] as? Int) ?? 0,
            creatorName: dj["nickname"] as? String,
            // 实测：分类字段叫 `category`（不是 categoryName）；
            // `/dj/sublist` 用 category，`/dj/hot` 用 categoryName，两个都认
            categoryName: dict["categoryName"] as? String ?? dict["category"] as? String,
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
        let song = mainSong.flatMap { Self.mapSong($0) }
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
    func request(
        _ path: String,
        query: [String: String] = [:],
        cookie: String? = nil,
        cacheTTL: TimeInterval? = nil,
        method: String = "GET",
        /// 只有旁证探针自己要传 false：否则探针返回 301 会再次触发探针，递归下去。
        noteAuthRejection: Bool = true
    ) async throws -> Data {
        let cacheKey = Self.cacheKey(path: path, query: query, cookie: cookie)
        let cacheGeneration = responseCacheGeneration
        // 写操作永远不读缓存
        if method == "GET", let ttl = cacheTTL, ttl > 0,
           let cached = cachedResponse(forKey: cacheKey) {
            return cached
        }

        do {
            #if os(iOS)
            let data: Data
            do {
                data = try await NeteaseDirectTransport.shared.mobileRequest(path, query: query, cookie: cookie)
            } catch let error as MusicError {
                if case .apiError(let code, _) = error, [301, 401, 403].contains(code), noteAuthRejection {
                    noteSessionRejection()
                }
                throw error
            }
            #else
            try await helper.startIfNeeded()
            let url = try await helper.makeURL(path: path, query: query)
            var request = URLRequest(url: url)
            request.httpMethod = method
            if method == "POST" {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
            await helper.applyAuth(to: &request)

            // 通过自定义 header 传递 cookie，由辅助进程注入转发，避免出现在 URL 中
            if let cookie = cookie, !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "X-CT-Cookie")
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MusicError.invalidResponse }
            // 301/403 都不是「会话失效」的证据，只是一个接口在说「我这儿没登录」。
            // 详见 SessionExpiryGuard：这里只抛普通接口错 + 记一次疑似，
            // 真正清登录态要等 /user/account 探针也失败。
            if http.statusCode == 301 || http.statusCode == 403 {
                if noteAuthRejection { noteSessionRejection() }
                throw MusicError.apiError(
                    code: http.statusCode,
                    message: "网易云拒绝了这次请求（可能被风控），稍后重试"
                )
            }
            // 401 在这套 helper 里只有一个来源：X-CT-Token 不匹配
            // （server.js:198-210），即辅助进程重启竞态 —— 与网易云会话无关，
            // 所以只提示本地服务鉴权失败，绝不能牵连用户的登录态。
            if http.statusCode == 401 { throw MusicError.helperAuthFailed }
            if http.statusCode == 429 { throw MusicError.rateLimited }
            guard (200...299).contains(http.statusCode) else {
                throw MusicError.apiError(code: http.statusCode, message: "HTTP \(http.statusCode)")
            }
            #endif
            // 同样地，HTTP 200 + body code 301 也只是「这个接口说没登录」。
            // 会话失效的错误响应都是小包；大响应（如 100 首曲目）跳过整包反序列化，
            // 避免这里 JSONSerialization 一遍、调用方 parseJSON 再一遍的双重开销
            if data.count <= 64 * 1024,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (json["code"] as? Int) == 301 {
                if noteAuthRejection { noteSessionRejection() }
                throw MusicError.apiError(code: 301, message: "该接口要求重新登录后才能访问")
            }
            if method == "GET", let ttl = cacheTTL, ttl > 0 {
                cacheResponse(data, forKey: cacheKey, ttl: ttl, generation: cacheGeneration)
            }
            return data
        } catch let error as URLError where error.code == .cancelled {
            throw MusicError.cancelled
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw MusicError.networkUnavailable
        } catch {
            // 走归一化：URLError 的语义（超时/断网/取消）不再被 localizedDescription 抹掉，
            // 且文案不再随系统语言变化
            throw MusicError.from(error)
        }
    }


    func parseJSON(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MusicError.invalidResponse
        }
        return json
    }

    // MARK: - 会话失效判定

    /// 疑似计数与定罪闸门。放在 actor 上天然被隔离，不需要额外加锁。
    private var sessionGuard = SessionExpiryGuard()

    /// 记一次「有接口说没登录」，必要时在后台打旁证探针。
    private func noteSessionRejection() {
        guard sessionGuard.noteRejection() == .probeSession else { return }
        Task { [weak self] in await self?.confirmSessionWithProbe() }
    }

    /// 打一次 `/user/account`：只有它也失败才认定会话真的失效。
    ///
    /// 这是「点一次红心就丢登录」的修复核心。早期实现对 301/401/403
    /// 一律直接广播会话失效，于是网易云一次风控拒绝就会清空本地账号数据
    /// 并弹扫码，而扫码后 `/user/account` 又返回 200 —— 会话一直是好的。
    private func confirmSessionWithProbe() async {
        let alive: Bool
        do {
            let cookie = try Self.loadLoginCookie()
            // noteAuthRejection: false —— 探针自己返回 301 时不能再触发探针
            let data = try await request("/user/account", cookie: cookie, noteAuthRejection: false)
            let json = try parseJSON(data)
            alive = (json["account"] as? [String: Any])?["id"] != nil
        } catch {
            alive = false
        }

        switch sessionGuard.resolveProbe(succeeded: alive) {
        case .sessionAlive:
            CTLog.general.info("单接口返回 301/403，但 /user/account 探针正常 —— 判定为风控拒绝，保留登录态")
        case .sessionExpired:
            CTLog.security.warning("/user/account 探针同样失败，判定会话确实失效")
            // 会话失效后 cookie 可能被原地刷新（重新扫码换新 MUSIC_U，权限可能变化），
            // 不清缓存的话旧身份写入的条目会继续命中到 TTL 结束
            clearCache()
            NotificationCenter.default.post(name: .clearToneSessionExpired, object: nil)
        case .ignore, .probeSession:
            break
        }
    }

    // MARK: - 缓存维护

    nonisolated static func cacheKey(path: String, query: [String: String], cookie: String?) -> String {
        let queryPart = query.sorted { $0.key < $1.key }
            // 长度前缀避免关键词里的 & 或 = 与 query 分隔符碰撞。
            .map { "\($0.key.utf8.count):\($0.key)\($0.value.utf8.count):\($0.value)" }
            .joined(separator: "&")
        let scope: String
        if let cookie, !cookie.isEmpty {
            // 不把凭据原文放进缓存键；不同账号/会话必须有不同的缓存空间。
            scope = SHA256.hash(data: Data(cookie.utf8)).map { String(format: "%02x", $0) }.joined()
        } else {
            scope = "anon"
        }
        return "\(path)?\(queryPart)|\(scope)"
    }

    func cachedResponse(forKey key: String) -> Data? {
        guard let entry = responseCache[key], entry.expiresAt > Date() else { return nil }
        return entry.data
    }

    func cacheResponse(_ data: Data, forKey key: String, ttl: TimeInterval, generation: Int) {
        guard generation == responseCacheGeneration, ttl > 0 else { return }
        responseCacheBytes += data.count - (responseCache[key]?.data.count ?? 0)
        responseCache[key] = CacheEntry(data: data, expiresAt: Date().addingTimeInterval(ttl))
        enforceResponseCacheLimits()
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
        responseCacheGeneration += 1
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
        responseCacheGeneration += 1
        responseCache.removeAll()
        responseCacheBytes = 0
        reachCache.removeAll()
    }

    // MARK: - 模型映射
    //
    // 全部是**纯函数**，因此标 `nonisolated static`：
    // 1. 不碰 actor 状态，隔离没有意义；
    // 2. 调用方（含单元测试）不必把非 Sendable 的 `[String: Any]`
    //    跨隔离边界传进来 —— Swift 6 会把那判成 data race。

    nonisolated static func mapSong(_ dict: [String: Any]) -> Song? {
        guard let id = dict["id"] else { return nil }
        let idString = String(describing: id)
        let title = dict["name"] as? String ?? "未知歌曲"

        let artists = (dict["ar"] as? [[String: Any]]) ?? (dict["artists"] as? [[String: Any]]) ?? []
        let artistModels = artists.map { Self.mapArtist($0) }

        var album: Album?
        if let al = dict["al"] as? [String: Any] {
            album = Self.mapAlbum(al)
        } else if let albumDict = dict["album"] as? [String: Any] {
            album = Self.mapAlbum(albumDict)
        }

        let duration = (Self.number(dict["dt"]) ?? Self.number(dict["duration"]) ?? 0) / 1000.0
        // 三个来源都要认：/song/detail 给 al.picUrl，搜索简要给 album.picUrl，
        // 而 /personalized/newsong 把封面放在**顶层** picUrl
        let coverURL = (dict["al"] as? [String: Any])?["picUrl"] as? String
            ?? (dict["album"] as? [String: Any])?["picUrl"] as? String
            ?? dict["picUrl"] as? String

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

    nonisolated static func mapArtist(_ dict: [String: Any]) -> Artist {
        let id = String(describing: dict["id"] ?? "0")
        let name = dict["name"] as? String ?? "未知歌手"
        // 四个来源字段都认：/simi/artist 与 /artist/album 给 picUrl / img1v1Url，
        // 而 /artist/detail（`/api/artist/head/info/get`）给的是 cover / avatar。
        // 少了任何一个来源，歌手页就会退回那个写死的 person.fill 圆盘。
        let avatarURL = (dict["picUrl"] as? String)
            ?? (dict["img1v1Url"] as? String)
            ?? (dict["cover"] as? String)
            ?? (dict["avatar"] as? String)
        let alias = (dict["alias"] as? [String]) ?? (dict["transNames"] as? [String]) ?? []
        return Artist(id: id, name: name, avatarURL: avatarURL.flatMap(URL.init), alias: alias)
    }

    nonisolated static func mapAlbum(_ dict: [String: Any]) -> Album {
        let id = String(describing: dict["id"] ?? "0")
        let name = dict["name"] as? String ?? "未知专辑"
        let coverURL = (dict["picUrl"] as? String).flatMap(URL.init)
        return Album(id: id, name: name, coverURL: coverURL)
    }

    nonisolated static func mapPlaylist(_ dict: [String: Any]) -> Playlist {
        let id = String(describing: dict["id"] ?? "0")
        let name = dict["name"] as? String ?? "未知歌单"
        let coverURL = ((dict["coverImgUrl"] as? String) ?? (dict["picUrl"] as? String)).flatMap(URL.init)
        let trackCount = dict["trackCount"] as? Int ?? 0
        let creator = (dict["creator"] as? [String: Any])?["nickname"] as? String
        let description = dict["description"] as? String
        return Playlist(id: id, name: name, coverURL: coverURL, trackCount: trackCount,
                        creatorName: creator, descriptionText: description, source: .netease)
    }

    /// 从 JSON 值里取数字。
    ///
    /// 不能直接 `as? Double`：`JSONSerialization` 把整数解成 `Int` 型
    /// `NSNumber` 时，`as? Double` 会失败（Swift 不会做 Int→Double 的
    /// 有损判断），于是时长变成 0、计数变成默认值 —— 而且不报错，很难查。
    nonisolated static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as Double: return n
        case let n as Int: return Double(n)
        case let n as Int64: return Double(n)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    nonisolated static func mapQualityLevel(_ level: String?) -> AudioQuality.QualityLevel {
        switch level {
        case "standard": return .standard
        case "higher": return .higher
        case "exhigh": return .exhigh
        case "lossless": return .lossless
        case "hires": return .hires
        default: return .unknown
        }
    }

    /// 播放源的实际编码。播放栏要显示「编码 + 码率」——
    /// 只写「极高 320k」看不出是 MP3 还是 AAC，无损也看不出是不是 FLAC。
    ///
    /// 优先用接口的 `encodeType`，缺失时退回 URL 扩展名
    /// （Netease 的 CDN 路径就是 `xxx.flac` / `xxx.mp3` / `xxx.m4a`）。
    nonisolated static func codecName(encodeType: String?, url: URL?) -> String? {
        let raw = (encodeType?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
        let token = raw ?? url?.pathExtension
        guard let token = token?.lowercased(), !token.isEmpty else { return nil }
        switch token {
        case "mp3": return "MP3"
        case "aac", "m4a", "m4b": return "AAC"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "opus": return "OPUS"
        case "wav", "wave": return "WAV"
        default: return token.uppercased()
        }
    }
}

// MARK: - HelperProcessManager 便捷扩展
#if os(macOS)
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
