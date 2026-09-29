import Foundation

/// 辅助进程路由名 → 网易云原始接口的映射与加密方式。
///
/// ## 这张表现在做什么用
///
/// 它有两个职责：
///
/// 1. **路由登记表（主要职责）。** 每条路由都记着它在
///    `api/module/*.js` 里的真实 uri 与加密方式，全部逐个读过源码核对。
///    `Tests/NeteaseEndpointTests.swift` 里的
///    `testEveryRequestCallSiteIsMapped` 会扫描所有 `request("...")` 调用点，
///    断言「调了但没登记」的路由不可能存在 —— `/song/detail` 当初就是这么漏掉的，
///    症状是 iOS 上「喜欢的音乐」必然抛「接口未适配」。
/// 2. **直连传输的翻译层。** `NeteaseDirectTransport` 按 `crypto` 分派
///    plain / weapi / eapi。`ClearToneiOS` target 已移除，这条路目前没有生产调用方，
///    保留理由见 `NeteaseDirectTransport.swift` 顶部说明。
///
/// ## 加密方式的判定依据
///
/// 以**上游 `api/module/*.js` 的实际行为**为准，不是猜的：
///
/// - `createOption(query, 'weapi')` → weapi
/// - `createOption(query, 'xeapi')` → xeapi（`/song/url/v1`）
/// - `createOption(query)`（第二参缺省）→ `util/option.js:3` 给出 `crypto: ''`，
///   `util/request.js:218-221` 把空串解析成 `APP_CONF.encrypt ? 'eapi' : 'api'`，
///   而 `util/config.json` 里 `encrypt: true` —— 所以**这些 module 全部是 eapi**。
///
/// 这条曾经写错成 `.plain`（5 条路由），并被 `NeteaseEndpointTests` 断言锁死。
/// 现已按 `helper.log` 里的 `[INFO] Request Success: [eapi] <route>` 实测日志校正。
///
/// - `weapi`：AesRsaWeapi。请求发往 `music.163.com/weapi/<uri 去掉前 5 字符>`。
/// - `plain`：明文表单，POST 到 `interface.music.163.com` + 原始 uri。
public enum NeteaseEndpoint {

    public enum Crypto: Sendable {
        /// AES-128-CBC 双重加密 + raw RSA
        case weapi
        /// 明文表单
        case plain
        /// AES-128-ECB + MD5 签名，请求体形如 `params=<大写hex>`
        case eapi
        /// 需要运行时公钥 + 反作弊 token 的加强签名。
        ///
        /// **直连层不支持**（`NeteaseDirectTransport` 会显式失败而不是静默降级）。
        /// 登记它是为了让这张表如实反映上游 module 的加密方式 —— 之前
        /// `/song/url/v1` 被标成 `.plain`，照着表重写直连会得到错签名。
        case xeapi
    }

    public struct Endpoint: Sendable {
        public let apiPath: String
        public let crypto: Crypto
        /// eapi 路由的请求参数（必须按 Node 模块里的键序）。
        /// 仅 `.eapi` 使用；nil 表示该路由只有固定参数，在调用处构造。
        public let orderedParamsKey: String?

        public init(apiPath: String, crypto: Crypto, orderedParamsKey: String? = nil) {
            self.apiPath = apiPath
            self.crypto = crypto
            self.orderedParamsKey = orderedParamsKey
        }
    }

    /// 一条 eapi 路由的参数规格。
    ///
    /// `payloadKeys` 是**上游 `api/module/*.js` 里 `data` 对象字面量的书写顺序** ——
    /// eapi 的签名覆盖整个 `JSON.stringify` 结果，键序参与鉴权。
    ///
    /// `renames` 处理「辅助进程 query 参数名 ≠ 上游 payload 键名」的情况。
    /// `/song/like` 就是这种：module 读 `query.id` / `query.uid`，
    /// 却把它们放进 data 的 `trackId` / `userid`。不登记重命名的话，
    /// 直连层会拼出 `{"id":…,"uid":…}` —— 键名错、顺序也对不上，签名必失败。
    public struct EapiParamSpec: Sendable {
        public let payloadKeys: [String]
        /// 辅助进程 query 键 → 上游 payload 键。默认同名。
        public let renames: [String: String]
        /// module 里**写死**、不从 query 读的值。直连层必须自己补上，
        /// 否则 `JSON.stringify` 的结果与辅助进程发出去的不一致，签名必失败。
        public let constants: OrderedJSON.Value?

        public init(
            _ payloadKeys: [String],
            renames: [String: String] = [:],
            constants: OrderedJSON.Value? = nil
        ) {
            self.payloadKeys = payloadKeys
            self.renames = renames
            self.constants = constants
        }

        /// 上游 payload 键 → 辅助进程 query 键
        func queryKey(forPayloadKey key: String) -> String {
            renames.first { $0.value == key }?.key ?? key
        }

        /// 写死的键（不该出现在 query 里）
        var constantKeys: Set<String> {
            guard case .object(let pairs)? = constants else { return [] }
            return Set(pairs.map(\.0))
        }
    }

    /// 辅助进程路由名 → 端点。取自 `api/module/*.js` 逐一核对。
    private static let table: [String: Endpoint] = [
        // MARK: 认证（实测：weapi 全部 code 200）
        "/login/qr/key":    Endpoint(apiPath: "/api/login/qr/unikey", crypto: .plain),
        "/login/qr/create": Endpoint(apiPath: "/api/login/qr/create", crypto: .plain),
        "/login/qr/check":  Endpoint(apiPath: "/api/login/qr/check", crypto: .plain),
        "/user/account":    Endpoint(apiPath: "/api/nuser/account/get", crypto: .weapi),
        "/logout":          Endpoint(apiPath: "/api/logout", crypto: .plain),

        // MARK: 搜索
        "/cloudsearch":     Endpoint(apiPath: "/api/cloudsearch/pc", crypto: .plain),
        "/search/suggest":  Endpoint(apiPath: "/api/search/suggest/web", crypto: .weapi),
        "/search/hot":      Endpoint(apiPath: "/api/search/hot", crypto: .eapi, orderedParamsKey: "searchHot"),
        "/search/hot/detail": Endpoint(apiPath: "/api/hotsearchlist/get", crypto: .weapi),

        // MARK: 歌曲详情
        "/song/detail":     Endpoint(apiPath: "/api/v3/song/detail", crypto: .weapi),

        // MARK: 歌单 / 专辑
        "/playlist/detail":     Endpoint(apiPath: "/api/v6/playlist/detail", crypto: .eapi, orderedParamsKey: "playlistDetailV6"),
        "/playlist/track/all":  Endpoint(apiPath: "/api/v6/playlist/detail", crypto: .eapi, orderedParamsKey: "playlistDetailV6"),
        "/album":               Endpoint(apiPath: "/api/v1/album", crypto: .weapi),
        // `artist_detail.js` 用的是裸 `createOption(query)`（第二参缺省）→ eapi，
        // 之前登记成 `.plain` 是错的。
        "/artist/detail":       Endpoint(apiPath: "/api/artist/head/info/get", crypto: .eapi, orderedParamsKey: "artistDetail"),
        "/artist/top/song":     Endpoint(apiPath: "/api/artist/top/song", crypto: .weapi),
        // **apiPath 是模板**：`artist_album.js` 打的是 `/api/artist/albums/${query.id}`，
        // 之前登记成 `/api/artist/album`（少了 s 与路径段）。
        "/artist/album":        Endpoint(apiPath: "/api/artist/albums/{id}", crypto: .weapi),
        "/artist/songs":        Endpoint(apiPath: "/api/v1/artist/songs", crypto: .eapi, orderedParamsKey: "artistSongs"),
        "/artist/desc":         Endpoint(apiPath: "/api/artist/introduction", crypto: .weapi),
        // `artist_mv.js` 读的参数名是 `artistId`（不是 `id`）
        "/artist/mv":           Endpoint(apiPath: "/api/artist/mvs", crypto: .weapi),

        // MARK: 播放地址
        "/song/url/v1":         Endpoint(apiPath: "/api/song/enhance/player/url/v1", crypto: .xeapi),
        "/song/url/match":      Endpoint(apiPath: "/api/song/enhance/player/url", crypto: .plain),

        // MARK: 歌词
        "/lyric/new":           Endpoint(apiPath: "/api/song/lyric/v1", crypto: .eapi, orderedParamsKey: "lyricNew"),

        // MARK: 用户数据
        "/user/playlist":   Endpoint(apiPath: "/api/user/playlist", crypto: .weapi),
        "/likelist":        Endpoint(apiPath: "/api/song/like/get", crypto: .eapi, orderedParamsKey: "likelist"),
        // **收藏实际走这条**（`song_like.js`，裸 createOption → eapi）。
        // `/like`（weapi `/api/radio/like`）不再使用：weapi 写接口在辅助进程
        // 匿名标识注册失败时会被风控稳定拒成 `code 301`，见 NeteaseProvider.likeSong。
        // 留着登记是为了如实反映上游仍然提供这条路由。
        "/song/like":       Endpoint(apiPath: "/api/song/like", crypto: .eapi, orderedParamsKey: "songLike"),
        "/like":            Endpoint(apiPath: "/api/radio/like", crypto: .weapi),

        // MARK: 推荐
        "/recommend/songs":    Endpoint(apiPath: "/api/v3/discovery/recommend/songs", crypto: .weapi),
        // 原先标 .plain 是错的：`recommend_resource.js` 用 createOption(query, 'weapi')
        "/recommend/resource": Endpoint(apiPath: "/api/v1/discovery/recommend/resource", crypto: .weapi),
        "/personalized":       Endpoint(apiPath: "/api/personalized/playlist", crypto: .weapi),

        // MARK: 电台
        "/dj/catelist":  Endpoint(apiPath: "/api/djradio/category/get", crypto: .weapi),
        "/dj/hot":       Endpoint(apiPath: "/api/djradio/hot/v1", crypto: .weapi),
        "/dj/recommend": Endpoint(apiPath: "/api/djradio/recommend/v1", crypto: .weapi),
        "/dj/program":   Endpoint(apiPath: "/api/dj/program/byradio", crypto: .weapi),
        "/dj/detail":    Endpoint(apiPath: "/api/djradio/v2/get", crypto: .weapi),
        "/dj/sub":       Endpoint(apiPath: "/api/djradio/sub", crypto: .weapi),
        "/dj/unsub":     Endpoint(apiPath: "/api/djradio/unsub", crypto: .weapi),
        "/dj/sublist":   Endpoint(apiPath: "/api/djradio/get/subed", crypto: .weapi),

        // MARK: 榜单 / 分类
        "/toplist":            Endpoint(apiPath: "/api/toplist", crypto: .eapi, orderedParamsKey: "toplist"),
        "/top/song":           Endpoint(apiPath: "/api/v1/discovery/new/songs", crypto: .weapi),
        "/top/playlist":       Endpoint(apiPath: "/api/playlist/list", crypto: .weapi),
        "/top/album":          Endpoint(apiPath: "/api/discovery/new/albums/area", crypto: .weapi),
        "/playlist/catlist":   Endpoint(apiPath: "/api/playlist/catalogue", crypto: .eapi, orderedParamsKey: "playlistCatlist"),
        "/playlist/hot":       Endpoint(apiPath: "/api/playlist/hottags", crypto: .weapi),

        // MARK: 歌单写操作
        //
        // 注意：加歌/删歌用 `/playlist/tracks`（op=add|del），**不是**
        // `/playlist/track/add` —— 后者在 api-enhanced 里是给「视频歌单」
        // 用的，home.md 的标题就是「收藏视频到视频歌单」。
        "/playlist/create":       Endpoint(apiPath: "/api/playlist/create", crypto: .weapi),
        "/playlist/delete":       Endpoint(apiPath: "/api/playlist/remove", crypto: .weapi),
        // 重命名走 eapi（createOption 无第二参），键序 { id, name }
        "/playlist/name/update":  Endpoint(apiPath: "/api/playlist/update/name", crypto: .eapi, orderedParamsKey: "playlistNameUpdate"),
        "/playlist/tracks":       Endpoint(apiPath: "/api/playlist/manipulate/tracks", crypto: .eapi, orderedParamsKey: "playlistTracks"),
        "/playlist/subscribe":    Endpoint(apiPath: "/api/playlist/subscribe", crypto: .eapi, orderedParamsKey: "playlistSubscribe"),
        "/playlist/unsubscribe":  Endpoint(apiPath: "/api/playlist/unsubscribe", crypto: .eapi, orderedParamsKey: "playlistSubscribe"),
        "/playlist/subscribers":  Endpoint(apiPath: "/api/playlist/subscribers", crypto: .eapi, orderedParamsKey: "playlistSubscribers"),
        "/album/sublist":         Endpoint(apiPath: "/api/album/sublist", crypto: .weapi),
        "/artist/sublist":        Endpoint(apiPath: "/api/artist/sublist", crypto: .weapi),

        // MARK: 收藏专辑 / 歌手
        "/album/sub":   Endpoint(apiPath: "/api/album/sub", crypto: .weapi),
        "/album/unsub": Endpoint(apiPath: "/api/album/unsub", crypto: .weapi),
        "/artist/sub":   Endpoint(apiPath: "/api/artist/sub", crypto: .weapi),
        "/artist/unsub": Endpoint(apiPath: "/api/artist/unsub", crypto: .weapi),

        // MARK: 推荐扩展
        "/recommend/songs/dislike": Endpoint(apiPath: "/api/v2/discovery/recommend/dislike", crypto: .weapi),
        "/personal_fm":              Endpoint(apiPath: "/api/v1/radio/get", crypto: .weapi),
        "/personalized/newsong":     Endpoint(apiPath: "/api/personalized/newsong", crypto: .weapi),
        "/album/newest":             Endpoint(apiPath: "/api/discovery/newAlbum", crypto: .weapi),
        "/simi/song":                Endpoint(apiPath: "/api/v1/discovery/simiSong", crypto: .weapi),
        "/simi/artist":              Endpoint(apiPath: "/api/discovery/simiArtist", crypto: .weapi),

        // MARK: 评论
        //
        // macOS helper 用 `/comment/new` 提供排序；旧的歌曲专用读取路由保留登记。
        // 点赞与取消点赞均走 `/comment/like`，由 query.t 分派原始 uri。
        "/comment/new":    Endpoint(apiPath: "/api/v2/resource/comments", crypto: .eapi, orderedParamsKey: "commentNew"),
        "/comment/music":  Endpoint(apiPath: "/api/v1/resource/comments/R_SO_4_", crypto: .weapi),
        "/comment/hot":    Endpoint(apiPath: "/api/v1/resource/hotcomments/R_SO_4_", crypto: .weapi),
        "/comment/like":   Endpoint(apiPath: "/api/v1/comment/like", crypto: .weapi),

        // MARK: 消息
        "/msg/notices":         Endpoint(apiPath: "/api/msg/notices", crypto: .weapi),
        "/msg/private":         Endpoint(apiPath: "/api/msg/private/users", crypto: .weapi),
        "/msg/private/history": Endpoint(apiPath: "/api/msg/private/history", crypto: .weapi),
        "/msg/comments":        Endpoint(apiPath: "/api/v1/user/comments/", crypto: .weapi),

        // MARK: 账号数据
        "/daily_signin":  Endpoint(apiPath: "/api/point/dailyTask", crypto: .eapi, orderedParamsKey: "dailySignin"),
        "/user/record":   Endpoint(apiPath: "/api/v1/play/record", crypto: .weapi),
        "/user/level":    Endpoint(apiPath: "/api/user/level", crypto: .weapi),
        "/user/subcount": Endpoint(apiPath: "/api/subcount", crypto: .weapi),
    ]

    /// 查询端点。未知路由返回 nil —— 宁可显式失败，也不要静默走错加密方式。
    public static func endpoint(forRoute route: String) -> Endpoint? {
        table[route]
    }

    /// 已覆盖的路由，便于测试断言
    public static var knownRoutes: [String] { Array(table.keys) }

    // MARK: - eapi 有序参数

    /// eapi 的签名覆盖整个 `JSON.stringify` 结果，**键序参与鉴权**。
    ///
    /// 键序必须与 `api/module/<route>.js` 里那个对象字面量的书写顺序逐字一致，
    /// 否则算出的 MD5 与服务端对不上。所以每条 eapi 路由的顺序集中登记在
    /// `orderedPayloads` 里，一处可查、可测。
    ///
    /// 另注：Node 侧会先给 `data` 追加 `e_r`，再追加 `header`，
    /// 因此这两个键排在业务参数之后（由 `NeteaseDirectTransport.eapi` 补上）。
    private static let orderedPayloads: [String: EapiParamSpec] = [
        // /api/toplist 与 /api/playlist/catalogue 都是 `request(uri, {}, ...)`，无参数
        "toplist": EapiParamSpec([]),
        "playlistCatlist": EapiParamSpec([]),
        // search_hot.js: { type: 1111 }
        "searchHot": EapiParamSpec(["type"]),
        // daily_signin.js: { type: 0 }（0=安卓端 3 经验，1=web 2 经验）
        "dailySignin": EapiParamSpec(["type"]),
        // playlist_subscribe.js: { id, checkToken? }
        "playlistSubscribe": EapiParamSpec(["id"]),
        // playlist_name_update.js: { id, name }
        "playlistNameUpdate": EapiParamSpec(["id", "name"]),
        // playlist_subscribers.js: { id, limit, offset }
        "playlistSubscribers": EapiParamSpec(["id", "limit", "offset"]),
        // playlist_tracks.js: { op, pid, tracks: JSON字符串, imme: 'true' }
        "playlistTracks": EapiParamSpec(["op", "pid", "trackIds", "imme"]),
        // song_like.js: { trackId: query.id, userid: query.uid, like }
        "songLike": EapiParamSpec(["trackId", "userid", "like"], renames: ["id": "trackId", "uid": "userid"]),
        // artist_detail.js: { id: query.id }
        "artistDetail": EapiParamSpec(["id"]),
        "commentNew": EapiParamSpec(["threadId", "pageNo", "showInner", "pageSize", "cursor", "sortType"]),
        // artist_songs.js 的 data 字面量是
        //   { id, private_cloud: 'true', work_type: 1, order, offset, limit }
        // 其中 private_cloud / work_type 是**写死**的（不读 query），
        // 所以它们必须进 constants，而不是让调用方传 —— 传了会被 module 忽略，
        // 直连层却会当成有效参数，两边行为就分叉了。
        "artistSongs": EapiParamSpec(
            ["id", "private_cloud", "work_type", "order", "offset", "limit"],
            constants: .object([("private_cloud", .string("true")), ("work_type", .int(1))])
        ),
        // 以下四条是「crypto 从 .plain 改成 .eapi」之后才暴露出来的缺口。
        // 键序直接抄自上游 module 的 `data` 对象字面量顺序 ——
        // eapi 的签名对键序敏感，顺序错了就是签名失败，
        // 而签名失败在界面上表现为「接口报错」，极难定位。
        "likelist":           EapiParamSpec(["uid"]),
        "playlistDetailV6":   EapiParamSpec(["id", "n", "s"]),
        "lyricNew":           EapiParamSpec(["id", "cp", "tv", "lv", "rv", "kv", "yv", "ytv", "yrv"]),
    ]

    /// 为 eapi 路由构造有序请求体。
    ///
    /// 返回 nil 表示该路由没有登记键序 —— 调用方应显式失败而不是随便拼一个顺序。
    public static func orderedPayload(forRoute route: String, query: [String: String]) -> OrderedJSON.Value? {
        guard let endpoint = table[route], endpoint.crypto == .eapi else { return nil }
        guard let spec = orderedPayloads[endpoint.orderedParamsKey ?? ""] else { return nil }

        // comment_new.js 在写 payload 前派生 threadId 与排序游标。
        // 本应用只请求歌曲（type=0）；其余资源显式拒绝，避免错拼前缀。
        if route == "/comment/new" {
            let accepted = Set(["id", "type", "pageNo", "pageSize", "sortType", "cursor"])
            guard Set(query.keys).isSubset(of: accepted), query["type"] == "0",
                  let id = query["id"],
                  let page = Int(query["pageNo"] ?? "1"), page > 0,
                  let size = Int(query["pageSize"] ?? "20"), size > 0,
                  let sort = Int(query["sortType"] ?? "99") else { return nil }
            let sortType = sort == 1 ? 99 : sort
            let cursor: OrderedJSON.Value
            switch sortType {
            case 99:
                let offset = (page - 1).multipliedReportingOverflow(by: size)
                guard !offset.overflow else { return nil }
                cursor = .int(offset.partialValue)
            case 2:
                let offset = (page - 1).multipliedReportingOverflow(by: size)
                guard !offset.overflow else { return nil }
                cursor = .string("normalHot#\(offset.partialValue)")
            case 3: cursor = .string(query["cursor"] ?? "0")
            default: return nil
            }
            return .object([
                ("threadId", .string("R_SO_4_" + id)),
                ("pageNo", query["pageNo"].map { .string($0) } ?? .int(1)),
                ("showInner", .bool(true)),
                ("pageSize", query["pageSize"].map { .string($0) } ?? .int(20)),
                ("cursor", cursor), ("sortType", .int(sortType)),
            ])
        }

        var pairs: [(String, OrderedJSON.Value)] = []
        let constants = spec.constants.map { Dictionary(uniqueKeysWithValues: $0.objectPairs) } ?? [:]
        for payloadKey in spec.payloadKeys {
            // module 写死的值优先，query 里不该再出现（出现会在下面被拒）
            if let fixed = constants[payloadKey] {
                pairs.append((payloadKey, fixed))
                continue
            }
            let queryKey = spec.queryKey(forPayloadKey: payloadKey)
            guard let raw = query[queryKey] else { continue }
            // Node 侧这些字段是数字/布尔，JSON.stringify 的输出不能带引号
            switch payloadKey {
            case "type", "work_type":
                guard let number = Int(raw) else { return nil }
                pairs.append((payloadKey, .int(number)))
            default:
                pairs.append((payloadKey, .string(raw)))
            }
        }
        // 未登记在册的键一律拒绝：拼错顺序的后果是签名失败，
        // 而签名失败在界面上表现为「接口报错」，极难定位。
        // module 写死的键（constants）反过来不能出现在 query 里 ——
        // 传了会被 module 忽略，却让直连层多拼一个上游根本不收的字段。
        let acceptedQueryKeys = Set(spec.payloadKeys.map(spec.queryKey(forPayloadKey:)))
            .subtracting(spec.constantKeys)
        for key in query.keys where !acceptedQueryKeys.contains(key) {
            return nil
        }
        return .object(pairs)
    }

    /// 登记过的 eapi 键序（测试用）
    public static var eapiParamKeys: [String: EapiParamSpec] { orderedPayloads }
}
