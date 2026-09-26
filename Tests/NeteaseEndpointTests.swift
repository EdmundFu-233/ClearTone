import XCTest

/// 辅助进程路由名 → 网易云原始接口的映射契约。
///
/// 这张表是 iOS 直连的基础：**路由名对不上或加密方式选错，症状都是
/// 「HTTP 200 但空 body」**，极难定位。所以每个条目都要锁住。
///
/// 表的来源是逐个读 `api/module/*.js` 拿到的 uri 与 crypto，
/// 并用纯 Swift 直连实测过 20/21 个接口 code 200。
final class NeteaseEndpointTests: XCTestCase {

    func testAllKnownRoutesResolve() {
        // NeteaseProvider 实际会用到的全部路由
        let routes = [
            "/login/qr/key", "/login/qr/create", "/login/qr/check",
            "/user/account", "/logout",
            "/cloudsearch",
            "/playlist/detail", "/playlist/track/all",
            "/album", "/artist/detail", "/artist/top/song", "/artist/album",
            "/song/url/v1", "/song/url/match",
            "/lyric/new",
            "/user/playlist", "/likelist", "/like",
            "/recommend/songs", "/recommend/resource", "/personalized",
            "/dj/catelist", "/dj/hot", "/dj/recommend", "/dj/program",
        ]
        for route in routes {
            XCTAssertNotNil(
                NeteaseEndpoint.endpoint(forRoute: route),
                "未映射的路由：\(route) —— iOS 端会直接抛错"
            )
        }
        XCTAssertEqual(routes.count, NeteaseEndpoint.knownRoutes.count,
                       "若有未列入上表的路由，说明表与实际调用点脱节了")
    }

    func testUnknownRouteReturnsNil() {
        XCTAssertNil(NeteaseEndpoint.endpoint(forRoute: "/not/a/real/route"))
        XCTAssertNil(NeteaseEndpoint.endpoint(forRoute: ""))
    }

    /// 所有 uri 必须以 /api/ 开头 —— weapi 靠「去掉前 5 字符」拼 URL
    func testAllAPIPathsStartWithApiPrefix() {
        for route in NeteaseEndpoint.knownRoutes {
            let endpoint = NeteaseEndpoint.endpoint(forRoute: route)!
            XCTAssertTrue(
                endpoint.apiPath.hasPrefix("/api/"),
                "\(route) → \(endpoint.apiPath)：weapi 依赖 substr(5) 去掉 '/api/'"
            )
        }
    }

    /// 播放地址必须明文：走 weapi 会拿到空 body
    func testPlayURLUsesPlainCrypto() {
        let endpoint = NeteaseEndpoint.endpoint(forRoute: "/song/url/v1")!
        XCTAssertEqual(endpoint.crypto, .plain)
        XCTAssertEqual(endpoint.apiPath, "/api/song/enhance/player/url/v1")
    }

    /// 收藏接口必须 weapi + 完整客户端 cookie
    ///
    /// 实测：明文调用 /api/radio/like 返回 `code -460 检测到您的网络环境存在风险`。
    /// 补上 os/appver/osver 等标识后进入正常风控（405 操作频繁 = 请求已被接受）。
    /// 早期把 -460 误判为「GET 方法不对」，实际是缺客户端标识。
    func testLikeUsesWeapiCrypto() {
        let endpoint = NeteaseEndpoint.endpoint(forRoute: "/like")!
        XCTAssertEqual(endpoint.crypto, .weapi)
        XCTAssertEqual(endpoint.apiPath, "/api/radio/like")
    }

    /// 电台接口的实测坑：
    /// - djRadios / categories / programs 都在**顶层**，不在 result/data 里
    /// - /dj/program 的参数是 `rid` 不是 `id`
    func testRadioRoutesUseWeapi() {
        for route in ["/dj/catelist", "/dj/hot", "/dj/recommend", "/dj/program"] {
            let endpoint = NeteaseEndpoint.endpoint(forRoute: route)!
            XCTAssertEqual(endpoint.crypto, .weapi, "\(route) 需 weapi")
        }
        XCTAssertEqual(
            NeteaseEndpoint.endpoint(forRoute: "/dj/program")!.apiPath,
            "/api/dj/program/byradio"
        )
    }

    /// 日推与歌单走不同加密 —— 两者都实测通过，但不能互换
    func testRecommendAndPlaylistCryptoDiffer() {
        XCTAssertEqual(
            NeteaseEndpoint.endpoint(forRoute: "/recommend/songs")!.crypto, .weapi
        )
        XCTAssertEqual(
            NeteaseEndpoint.endpoint(forRoute: "/playlist/detail")!.crypto, .plain
        )
    }

    /// 歌词明文可用，走 weapi 反而失败
    func testLyricUsesPlainCrypto() {
        XCTAssertEqual(NeteaseEndpoint.endpoint(forRoute: "/lyric/new")!.crypto, .plain)
    }

    /// 收藏列表（读取）与收藏（写入）加密方式不同：读明文、写 weapi
    func testReadAndWriteLikeUseDifferentCrypto() {
        XCTAssertEqual(NeteaseEndpoint.endpoint(forRoute: "/likelist")!.crypto, .plain)
        XCTAssertEqual(NeteaseEndpoint.endpoint(forRoute: "/like")!.crypto, .weapi)
    }
}
