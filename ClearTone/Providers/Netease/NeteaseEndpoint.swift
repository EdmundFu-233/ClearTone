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
///    plain / weapi / eapi / xeapi。iOS 生产路径使用这条路，
///    保留理由见 `NeteaseDirectTransport.swift` 顶部说明。
///
/// ## 这张表怎么核对
///
/// 手读 `api/module/*.js` 只能看个大概，所以上游行为用**打包的 Node 运行时**
/// 打桩复现：把 module 的 `request` 换成桩，记录它真正会发出去的
/// `(uri, data, options.crypto)`。脚本是 `scripts/probes/endpoint-table.js`，
/// 改这张表或改上游 api 之后跑一次：
///
/// ```bash
/// ./ClearTone/Resources/HelperRuntime/bin/node scripts/probes/endpoint-table.js
/// ```
///
/// 除了 uri 与加密方式，它还顺带核对两件同样致命的事：
///
/// - **helper 有没有这条路由。** helper 的路由是拿 module 文件名推出来的
///   （`server.js:78` 把 `_` 换成 `/`），所以**不存在 `album_unsub.js` 就不存在
///   `/album/unsub`** —— 登记一条上游没有的路由，macOS 上会 404。
///   收藏/取消收藏共用一个 module，方向由 `query.t` 决定（见下）。
/// - **`data` 的键序与 JSON 类型。** eapi 的签名覆盖整个 `JSON.stringify`
///   结果，`{"type":0}` 与 `{"type":"0"}` 是两个不同的签名。
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
/// 这条曾经写错成 `.plain`（`/login/qr/key`、`/login/qr/check`、`/logout`、
/// `/cloudsearch` 等），照着表重写直连会得到错签名。现已用上述探针逐条校正。
///
/// - `weapi`：AesRsaWeapi。请求发往 `music.163.com/weapi/<uri 去掉前 5 字符>`。
/// - `plain`：明文表单，POST 到 `interface.music.163.com` + 原始 uri。
///   **当前表里没有任何一条网络路由是 plain** —— 上游全是 eapi/weapi/xeapi；
///   `.plain` 这个 case 只留给「module 自己不发请求」的占位行与将来可能出现的例外。
///
/// ## apiPath 里的模板
///
/// 有的 module 把参数拼进路径（`/api/v1/album/${query.id}`）。这类行把模板写成
/// `{id}` 之类的占位符，由调用方替换 —— 写成裸前缀的话，「表里看着对、发出去少一截」
/// 没人能发现。`NeteaseMobileRoute` 统一做替换。
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
        /// 由 `NeteaseXeapi` 支持（`NeteaseDirectTransport` 直接分派过去）。
        /// 登记它是因为上游 `song_url_v1.js` 显式 `createOption(query, 'xeapi')` ——
        /// 早先标成 `.plain`，照着表重写直连会得到错签名。
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
        /// query 里**没给**时用的值，对标上游的 `query.x || 默认值`。
        public let defaults: [String: OrderedJSON.Value]
        /// 取自 query、但上游会转成**布尔**的键（如 `query.like !== 'false'`）。
        ///
        /// 语义与上游一致：值等于 `"false"` 才是 false，缺省走 `defaults`。
        public let boolKeys: Set<String>
        /// 辅助进程特有、上游 module 根本不读的 query 键。
        ///
        /// 「未登记键一律拒绝」是防拼错的护栏，但 `randomCNIP`、`timestamp`
        /// 这类只对本地 helper 有意义的开关不该被它误伤 —— 发不发都不影响
        /// payload，所以在这里显式豁免。
        public let ignoredQueryKeys: Set<String>

        public init(
            _ payloadKeys: [String],
            renames: [String: String] = [:],
            constants: OrderedJSON.Value? = nil,
            defaults: [String: OrderedJSON.Value] = [:],
            boolKeys: Set<String> = [],
            ignoredQueryKeys: Set<String> = []
        ) {
            self.payloadKeys = payloadKeys
            self.renames = renames
            self.constants = constants
            self.defaults = defaults
            self.boolKeys = boolKeys
            self.ignoredQueryKeys = ignoredQueryKeys
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
        // MARK: 认证
        //
        // 三条 qr 路由的 module 全部是裸 `createOption(query)` → eapi，
        // 而且真实 uri 用的是 `qrcode` 而不是 `qr`（探针实测）。
        // 早先登记成 `.plain` + `/api/login/qr/*`，两条都是错的。
        "/login/qr/key":    Endpoint(apiPath: "/api/login/qrcode/unikey", crypto: .eapi, orderedParamsKey: "qrKey"),
        // 上游 module 不发网络请求（本地拼 URL + qrcode 出图），crypto 无意义。
        // 仍登记是因为 macOS 的 fetchQRCodeImage 会调它，路由不能从表里消失。
        "/login/qr/create": Endpoint(apiPath: "/api/login/qr/create", crypto: .plain),
        "/login/qr/check":  Endpoint(apiPath: "/api/login/qrcode/client/login", crypto: .eapi, orderedParamsKey: "qrCheck"),
        "/user/account":    Endpoint(apiPath: "/api/nuser/account/get", crypto: .weapi),
        // logout.js: `request('/api/logout', {}, createOption(query))` ——
        // data 是**空对象**，只靠 cookie 认证，query 一律不发。
        "/logout":          Endpoint(apiPath: "/api/logout", crypto: .eapi, orderedParamsKey: "logout"),

        // MARK: 搜索
        "/cloudsearch":     Endpoint(apiPath: "/api/cloudsearch/pc", crypto: .eapi, orderedParamsKey: "cloudsearch"),
        "/search/suggest":  Endpoint(apiPath: "/api/search/suggest/web", crypto: .weapi),
        "/search/hot":      Endpoint(apiPath: "/api/search/hot", crypto: .eapi, orderedParamsKey: "searchHot"),
        "/search/hot/detail": Endpoint(apiPath: "/api/hotsearchlist/get", crypto: .weapi),

        // MARK: 歌曲详情
        "/song/detail":     Endpoint(apiPath: "/api/v3/song/detail", crypto: .weapi),

        // MARK: 歌单 / 专辑
        "/playlist/detail":     Endpoint(apiPath: "/api/v6/playlist/detail", crypto: .eapi, orderedParamsKey: "playlistDetailV6"),
        "/playlist/track/all":  Endpoint(apiPath: "/api/v6/playlist/detail", crypto: .eapi, orderedParamsKey: "playlistDetailV6"),
        // **apiPath 是模板**：`album.js` 打的是 `/api/v1/album/${query.id}`
        "/album":               Endpoint(apiPath: "/api/v1/album/{id}", crypto: .weapi),
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
        // 上游 `song_url_match.js` 走的是第三方解锁（unblockmusic-utils），
        // 不经网易云的 createOption/request，crypto 无意义。
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
        //
        // 收藏与取消收藏**共用 `/playlist/subscribe`**，方向由 `query.t` 决定
        // （`playlist_subscribe.js`: `query.t == 1 ? 'subscribe' : 'unsubscribe'`）。
        // helper 的路由是从 module 文件名推出来的（`server.js:78`），
        // **没有 `playlist_unsubscribe.js` 就没有 `/playlist/unsubscribe`** ——
        // 早先登记了这条路由并照着调，macOS 上是 404。
        "/playlist/create":       Endpoint(apiPath: "/api/playlist/create", crypto: .weapi),
        "/playlist/delete":       Endpoint(apiPath: "/api/playlist/remove", crypto: .weapi),
        // 重命名走 eapi（createOption 无第二参），键序 { id, name }
        "/playlist/name/update":  Endpoint(apiPath: "/api/playlist/update/name", crypto: .eapi, orderedParamsKey: "playlistNameUpdate"),
        "/playlist/tracks":       Endpoint(apiPath: "/api/playlist/manipulate/tracks", crypto: .eapi, orderedParamsKey: "playlistTracks"),
        "/playlist/subscribe":    Endpoint(apiPath: "/api/playlist/subscribe", crypto: .eapi, orderedParamsKey: "playlistSubscribe"),
        "/playlist/subscribers":  Endpoint(apiPath: "/api/playlist/subscribers", crypto: .eapi, orderedParamsKey: "playlistSubscribers"),
        "/album/sublist":         Endpoint(apiPath: "/api/album/sublist", crypto: .weapi),
        "/artist/sublist":        Endpoint(apiPath: "/api/artist/sublist", crypto: .weapi),

        // MARK: 收藏专辑 / 歌手 / 电台
        //
        // 与歌单同理：三个 module 各自一个文件，方向由 `query.t` 分派
        // （`t == 1` → sub，否则 unsub），**不存在 `*_unsub.js`**。
        // 调用方只准用下面这三条，`t` 由 `NeteaseSocialProvider.toggleSub` 传。
        "/album/sub":   Endpoint(apiPath: "/api/album/sub", crypto: .weapi),
        "/artist/sub":  Endpoint(apiPath: "/api/artist/sub", crypto: .weapi),
        "/dj/sub":      Endpoint(apiPath: "/api/djradio/sub", crypto: .weapi),

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
        // **两条都是模板**：resource id 拼在 uri 尾巴上
        // （`comment_music.js`: `.../R_SO_4_${query.id}`；
        //  `comment_hot.js`: `.../${resourceTypeMap[type]}${query.id}`）
        "/comment/music":  Endpoint(apiPath: "/api/v1/resource/comments/R_SO_4_{id}", crypto: .weapi),
        "/comment/hot":    Endpoint(apiPath: "/api/v1/resource/hotcomments/{type}{id}", crypto: .weapi),
        "/comment/like":   Endpoint(apiPath: "/api/v1/comment/like", crypto: .weapi),

        // MARK: 消息
        "/msg/notices":         Endpoint(apiPath: "/api/msg/notices", crypto: .weapi),
        "/msg/private":         Endpoint(apiPath: "/api/msg/private/users", crypto: .weapi),
        "/msg/private/history": Endpoint(apiPath: "/api/msg/private/history", crypto: .weapi),
        // **apiPath 是模板**：`msg_comments.js` 打 `/api/v1/user/comments/${query.uid}`
        "/msg/comments":        Endpoint(apiPath: "/api/v1/user/comments/{uid}", crypto: .weapi),

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
        // logout.js: `request('/api/logout', {}, ...)` —— data 是空对象，
        // query 一个都不读（认证只靠 cookie）。
        "logout": EapiParamSpec([], ignoredQueryKeys: ["randomCNIP", "timestamp", "cookie", "method"]),
        // search_hot.js: `data = { type: 1111 }` —— 写死的数字字面量，
        // **不读 query.type**，所以传 type 进来会被「未登记键」挡下。
        "searchHot": EapiParamSpec(["type"], constants: .object([("type", .int(1111))])),
        // login_qr_key.js: `data = { type: 3 }`（写死）
        "qrKey": EapiParamSpec(["type"], constants: .object([("type", .int(3))]),
                               ignoredQueryKeys: ["randomCNIP", "timestamp"]),
        // login_qr_check.js: `data = { key: query.key, type: 3 }`
        "qrCheck": EapiParamSpec(["key", "type"], constants: .object([("type", .int(3))]),
                                 ignoredQueryKeys: ["randomCNIP", "timestamp"]),
        // cloudsearch.js: `data = { s: query.keywords, type: query.type || 1,
        //   limit: query.limit || 30, offset: query.offset || 0, total: true }`
        // 调用方每次都传齐 type/limit/offset，所以默认值由 NeteaseMobileRoute 先补上。
        "cloudsearch": EapiParamSpec(["s", "type", "limit", "offset", "total"],
                                     renames: ["keywords": "s"],
                                     constants: .object([("total", .bool(true))])),
        // daily_signin.js: `data = { type: query.type || 0 }` —— query 来自
        // Express，**是字符串**，所以这里发 `"0"` 而不是 `0`（与辅助进程逐字一致）。
        "dailySignin": EapiParamSpec(["type"]),
        // playlist_subscribe.js: `data = { id, checkToken? }`。
        // `checkToken` 那半边是 `query.t === 1` 的**严格**比较，而 query 里
        // 永远是字符串 `'1'` —— 上游实际从来不会把它放进 data，所以不登记。
        // `t` 只决定 module 打哪条 uri，`checkToken` 只影响上游是否现取
        // 反作弊 token —— 两者都不进 payload，在这里豁免。
        "playlistSubscribe": EapiParamSpec(["id"], ignoredQueryKeys: ["t", "checkToken"]),
        // playlist_name_update.js: { id, name }
        "playlistNameUpdate": EapiParamSpec(["id", "name"]),
        // playlist_subscribers.js: { id, limit, offset }
        "playlistSubscribers": EapiParamSpec(["id", "limit", "offset"]),
        // playlist_tracks.js: { op, pid, trackIds: JSON字符串, imme: 'true' }
        "playlistTracks": EapiParamSpec(["op", "pid", "trackIds", "imme"]),
        // song_like.js: `like = query.like !== 'false'` → 缺省为 true
        "songLike": EapiParamSpec(["trackId", "userid", "like"],
                                  renames: ["id": "trackId", "uid": "userid"],
                                  defaults: ["like": .bool(true)],
                                  boolKeys: ["like"]),
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
        // 以下三条是「crypto 从 .plain 改成 .eapi」之后才暴露出来的缺口。
        // 键序直接抄自上游 module 的 `data` 对象字面量顺序 ——
        // eapi 的签名对键序敏感，顺序错了就是签名失败，
        // 而签名失败在界面上表现为「接口报错」，极难定位。
        "likelist":           EapiParamSpec(["uid"]),
        // playlist_detail.js / playlist_track_all.js:
        //   { id: query.id, n: 100000, s: query.s || 8 }
        "playlistDetailV6":   EapiParamSpec(["id", "n", "s"],
                                            constants: .object([("n", .int(100000))]),
                                            defaults: ["s": .int(8)]),
        // lyric_new.js: { id, cp: false, tv: 0, lv: 0, rv: 0, kv: 0, yv: 0, ytv: 0, yrv: 0 }
        // 除 id 外全是写死的 —— 调用方只传 id，剩下的必须由 constants 补齐，
        // 否则 payload 少八个键，与辅助进程发出去的不是同一个签名。
        "lyricNew":           EapiParamSpec(
            ["id", "cp", "tv", "lv", "rv", "kv", "yv", "ytv", "yrv"],
            constants: .object([
                ("cp", .bool(false)), ("tv", .int(0)), ("lv", .int(0)),
                ("rv", .int(0)), ("kv", .int(0)), ("yv", .int(0)),
                ("ytv", .int(0)), ("yrv", .int(0)),
            ])
        ),
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
            guard let raw = query[queryKey] else {
                // 对标上游的 `query.x || 默认值`；两边都没有就整条键省略
                if let fallback = spec.defaults[payloadKey] { pairs.append((payloadKey, fallback)) }
                continue
            }
            if spec.boolKeys.contains(payloadKey) {
                // 上游写的是 `query.x !== 'false'`：只有字面 "false" 才是 false
                pairs.append((payloadKey, .bool(raw != "false")))
            } else {
                // 取自 query 的值一律是**字符串** —— Express 就是这么给的
                // （`query.type || 1` 在有值时拿到的也是字符串）。
                // 要发数字或布尔，登记成 constants / boolKeys，不要猜。
                pairs.append((payloadKey, .string(raw)))
            }
        }
        // 未登记在册的键一律拒绝：拼错顺序的后果是签名失败，
        // 而签名失败在界面上表现为「接口报错」，极难定位。
        // module 写死的键（constants）反过来不能出现在 query 里 ——
        // 传了会被 module 忽略，却让直连层多拼一个上游根本不收的字段。
        // `ignoredQueryKeys` 是豁免名单：本地 helper 的开关，上游不读也不收。
        let acceptedQueryKeys = Set(spec.payloadKeys.map(spec.queryKey(forPayloadKey:)))
            .subtracting(spec.constantKeys)
            .union(spec.ignoredQueryKeys)
        for key in query.keys where !acceptedQueryKeys.contains(key) {
            return nil
        }
        return .object(pairs)
    }

    /// 登记过的 eapi 键序（测试用）
    public static var eapiParamKeys: [String: EapiParamSpec] { orderedPayloads }
}
