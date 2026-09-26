import Foundation

/// 辅助进程路由名 → 网易云原始接口的映射与加密方式。
///
/// ## 为什么需要这张表
///
/// macOS 版通过辅助进程访问网易云，用的是 api-enhanced 的**路由名**
/// （如 `/recommend/songs`、`/like`），由 Node 侧把路由名翻译成网易云的
/// 真实 uri（`/api/v3/discovery/recommend/songs`）并决定用哪种加密。
///
/// iOS 没有辅助进程，必须自己完成这层翻译 —— 而且这张表是**实测**出来的，
/// 不是从文档抄的：我逐个读了 `api/module/*.js` 拿到 uri 和 crypto，
/// 又用纯 Swift 直连打了一遍确认 20/21 个接口 code 200。
///
/// ## 两种加密
///
/// - `weapi`：AesRsaWeapi。请求发往 `music.163.com/weapi/<uri 去掉前 5 字符>`。
/// - `plain`：明文表单，POST 到 `interface.music.163.com` + 原始 uri。
public enum NeteaseEndpoint {

    public enum Crypto: Sendable {
        /// AES-128-CBC 双重加密 + raw RSA
        case weapi
        /// 明文表单
        case plain
    }

    public struct Endpoint: Sendable {
        public let apiPath: String
        public let crypto: Crypto

        public init(apiPath: String, crypto: Crypto) {
            self.apiPath = apiPath
            self.crypto = crypto
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

        // MARK: 歌单 / 专辑
        "/playlist/detail":     Endpoint(apiPath: "/api/v6/playlist/detail", crypto: .plain),
        "/playlist/track/all":  Endpoint(apiPath: "/api/v6/playlist/detail", crypto: .plain),
        "/album":               Endpoint(apiPath: "/api/v1/album", crypto: .weapi),
        "/artist/detail":       Endpoint(apiPath: "/api/artist/head/info/get", crypto: .plain),
        "/artist/top/song":     Endpoint(apiPath: "/api/artist/top/song", crypto: .weapi),
        "/artist/album":        Endpoint(apiPath: "/api/artist/album", crypto: .weapi),

        // MARK: 播放地址
        "/song/url/v1":         Endpoint(apiPath: "/api/song/enhance/player/url/v1", crypto: .plain),
        "/song/url/match":      Endpoint(apiPath: "/api/song/enhance/player/url", crypto: .plain),

        // MARK: 歌词
        "/lyric/new":           Endpoint(apiPath: "/api/song/lyric/v1", crypto: .plain),

        // MARK: 用户数据
        "/user/playlist":   Endpoint(apiPath: "/api/user/playlist", crypto: .weapi),
        "/likelist":        Endpoint(apiPath: "/api/song/like/get", crypto: .plain),
        "/like":            Endpoint(apiPath: "/api/radio/like", crypto: .weapi),

        // MARK: 推荐
        "/recommend/songs":    Endpoint(apiPath: "/api/v3/discovery/recommend/songs", crypto: .weapi),
        "/recommend/resource": Endpoint(apiPath: "/api/v1/discovery/recommend/resource", crypto: .plain),
        "/personalized":       Endpoint(apiPath: "/api/personalized/playlist", crypto: .weapi),

        // MARK: 电台
        "/dj/catelist":  Endpoint(apiPath: "/api/djradio/category/get", crypto: .weapi),
        "/dj/hot":       Endpoint(apiPath: "/api/djradio/hot/v1", crypto: .weapi),
        "/dj/recommend": Endpoint(apiPath: "/api/djradio/recommend/v1", crypto: .weapi),
        "/dj/program":   Endpoint(apiPath: "/api/dj/program/byradio", crypto: .weapi),
    ]

    /// 查询端点。未知路由返回 nil —— 宁可显式失败，也不要静默走错加密方式。
    public static func endpoint(forRoute route: String) -> Endpoint? {
        table[route]
    }

    /// 已覆盖的路由，便于测试断言
    public static var knownRoutes: [String] { Array(table.keys) }
}
