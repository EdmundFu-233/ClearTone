import XCTest

/// 辅助进程路由名 → 网易云原始接口的映射契约。
///
/// 这张表是**路由登记表**：每个路由在 `api/module/*.js` 里的真实 uri 与
/// 加密方式都逐个读过源码核对。
///
/// 两条测试各管一件事：
/// - `testEveryRequestCallSiteIsMapped` 扫描所有 `request("...")` 调用点，
///   保证不存在「调了但没登记」的路由；
/// - 其余用例锁住每条路由的映射与 eapi 键序 —— 直连路径一旦重新启用，
///   **路由名对不上或加密方式选错，症状都是「HTTP 200 但空 body」**，极难定位。
final class NeteaseEndpointTests: XCTestCase {

    func testAllKnownRoutesResolve() {
        // NeteaseProvider / NeteaseSocialProvider 实际会用到的全部路由
        let routes = [
            // 认证
            "/login/qr/key", "/login/qr/create", "/login/qr/check",
            "/user/account", "/logout",
            // 搜索
            "/cloudsearch", "/search/suggest", "/search/hot", "/search/hot/detail",
            // 歌曲
            "/song/detail", "/song/url/v1", "/song/url/match", "/lyric/new",
            // 歌单
            "/playlist/detail", "/playlist/track/all", "/playlist/create",
            "/playlist/delete", "/playlist/name/update", "/playlist/tracks",
            "/playlist/subscribe", "/playlist/unsubscribe", "/playlist/subscribers",
            "/playlist/catlist", "/playlist/hot", "/top/playlist",
            // 专辑 / 歌手
            "/album", "/album/sub", "/album/unsub", "/album/sublist", "/album/newest",
            "/artist/detail", "/artist/top/song", "/artist/album",
            "/artist/songs", "/artist/desc", "/artist/mv",
            "/artist/sub", "/artist/unsub", "/artist/sublist",
            // 用户数据
            "/user/playlist", "/likelist", "/like", "/song/like", "/user/record",
            "/user/level", "/user/subcount", "/daily_signin",
            // 推荐
            "/recommend/songs", "/recommend/resource", "/recommend/songs/dislike",
            "/personalized", "/personalized/newsong", "/personal_fm",
            "/simi/song", "/simi/artist",
            // 榜单
            "/toplist", "/top/song", "/top/album",
            // 电台
            "/dj/catelist", "/dj/hot", "/dj/recommend", "/dj/program",
            "/dj/detail", "/dj/sub", "/dj/unsub", "/dj/sublist",
            // 评论
            "/comment/new", "/comment/music", "/comment/hot", "/comment/like",
            // 消息
            "/msg/notices", "/msg/private", "/msg/private/history", "/msg/comments",
        ]
        for route in routes {
            XCTAssertNotNil(
                NeteaseEndpoint.endpoint(forRoute: route),
                "未映射的路由：\(route) —— 直连路径会直接抛错"
            )
        }
        XCTAssertEqual(routes.count, NeteaseEndpoint.knownRoutes.count,
                       "若有未列入上表的路由，说明表与实际调用点脱节了")
    }

    /// `/song/detail` 曾在表里缺失，而 `fetchLikedSongs` 一直在调它。
    /// 这条用例是为了不让它再消失一次。
    func testSongDetailIsMapped() {
        XCTAssertNotNil(NeteaseEndpoint.endpoint(forRoute: "/song/detail"))
    }

    /// 扫描源码里所有 `request("...")` 调用点，逐一确认在表中。
    ///
    /// 手工维护的路由清单迟早会漏（`/song/detail` 就是这么漏的）。
    /// 这条测试把「表 ⊇ 实际调用点」变成自动检查，新增接口忘了登记会立刻红。
    func testEveryRequestCallSiteIsMapped() throws {
        let sourceDir = Self.sourceDirectory()
        let files = try FileManager.default
            .contentsOfDirectory(atPath: sourceDir)
            .filter { $0.hasSuffix(".swift") }
            .map { URL(fileURLWithPath: sourceDir).appendingPathComponent($0) }

        var callSites: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // 匹配 request("/xxx" 与 request("xxx"，覆盖三元表达式形式
            let pattern = #"request\(\s*"(/[^"]+)""#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                for match in regex.matches(in: text, range: range) {
                    if let r = Range(match.range(at: 1), in: text) {
                        callSites.append(String(text[r]))
                    }
                }
            }
        }

        XCTAssertFalse(callSites.isEmpty, "没扫到任何 request 调用点，扫描逻辑本身坏了")
        for route in Set(callSites).sorted() {
            XCTAssertNotNil(
                NeteaseEndpoint.endpoint(forRoute: route),
                "调用了 \(route) 但 NeteaseEndpoint 里没登记 —— 直连路径会直接抛错"
            )
        }
    }

    private static func sourceDirectory() -> String {
        // #filePath = <repo>/Tests/NeteaseEndpointTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ClearTone/Providers/Netease")
            .path
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

    /// 播放地址走 **xeapi**（`song_url_v1.js` 显式 `createOption(query, 'xeapi')`）。
    ///
    /// 之前这里断言 `.plain`，依据是「明文调用能拿到 body」——
    /// 但那个观测是在**辅助进程**里做的，而辅助进程自己会按 module 选 xeapi。
    /// 直连层按错误的 `.plain` 重建会得到错签名。
    /// 实测日志：`helper.log` 里是 `[INFO] Request Success: [xeapi] /song/url/v1`。
    func testPlayURLUsesXeapiCrypto() {
        let endpoint = NeteaseEndpoint.endpoint(forRoute: "/song/url/v1")!
        XCTAssertEqual(endpoint.crypto, .xeapi)
        XCTAssertEqual(endpoint.apiPath, "/api/song/enhance/player/url/v1")
    }

    /// `/like`（weapi `/api/radio/like`）**不再使用**，但仍如实登记。
    ///
    /// 停用的原因：weapi 写接口在辅助进程匿名标识注册失败时会被网易云
    /// 按风控稳定拒成 `code 301`（实测同一实例上连开三次，而同 cookie 的
    /// `/user/account`、`/likelist` 全都 200）。收藏改走 eapi 的 `/song/like`。
    ///
    /// 早期这里断言 weapi 是因为「辅助进程日志里 `[weapi] /like`」，
    /// 那个观测本身没错，错的是把它当成了可靠路径。
    func testLegacyLikeRouteIsStillMappedButUnused() {
        let endpoint = NeteaseEndpoint.endpoint(forRoute: "/like")
        XCTAssertEqual(endpoint?.crypto, .weapi)
        XCTAssertEqual(endpoint?.apiPath, "/api/radio/like")
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

    /// `createOption(query)`（第二参缺省）的 module **全部是 eapi**，不是明文。
    ///
    /// 依据链条：`util/option.js:3` 给出 `crypto: ''` →
    /// `util/request.js:218-221` 把 `''` 解析成 `APP_CONF.encrypt ? 'eapi' : 'api'` →
    /// `util/config.json` 里 `encrypt: true`。
    /// 另有 `helper.log` 的 `[INFO] Request Success: [eapi] <route>` 实测日志佐证。
    ///
    /// 这四条之前断言 `.plain` 并因此把错误值锁死 —— 照着表重写直连会得到错签名。
    func testCreateOptionWithoutSecondArgMeansEapiNotPlain() {
        for route in ["/playlist/detail", "/playlist/track/all", "/lyric/new", "/likelist"] {
            let endpoint = NeteaseEndpoint.endpoint(forRoute: route)
            XCTAssertEqual(endpoint?.crypto, .eapi, "\(route) 走的是 eapi，不是明文")
        }
    }

    /// 日推走 weapi，歌单详情走 eapi —— 两者都实测通过，但不能互换
    func testRecommendAndPlaylistCryptoDiffer() {
        XCTAssertEqual(
            NeteaseEndpoint.endpoint(forRoute: "/recommend/songs")!.crypto, .weapi
        )
        XCTAssertEqual(
            NeteaseEndpoint.endpoint(forRoute: "/playlist/detail")!.crypto, .eapi
        )
    }

    /// eapi 键序里 module 的 data 对象键叫 `trackIds`，不是 `tracks`。
    /// `playlist_tracks.js:10` 是 `trackIds: JSON.stringify(query.tracks.split(','))`，
    /// 所以传输层给的值是 JSON 数组字符串。
    func testPlaylistTracksOrderedParamUsesTrackIds() throws {
        let payload = try XCTUnwrap(NeteaseEndpoint.orderedPayload(
            forRoute: "/playlist/tracks",
            query: ["op": "add", "pid": "1", "trackIds": #"["2","3"]"#, "imme": "true"]
        ))
        guard case .object(let pairs) = payload else {
            return XCTFail("eapi 请求体应是对象，实际是 \(payload)")
        }
        XCTAssertEqual(pairs.map(\.0), ["op", "pid", "trackIds", "imme"])
        // 键名错成 `tracks` 会被这里的「未登记键一律拒绝」挡下
        XCTAssertNil(NeteaseEndpoint.orderedPayload(
            forRoute: "/playlist/tracks",
            query: ["op": "add", "pid": "1", "tracks": #"["2","3"]"#, "imme": "true"]
        ), "键名必须是 trackIds")
    }
}
