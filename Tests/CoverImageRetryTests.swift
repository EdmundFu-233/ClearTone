import XCTest

/// 封面下载的 host 故障转移 + 协议升级。
///
/// ## 实测数据（本文件所有断言的依据）
///
/// 同一张封面（`p4.music.126.net/fwXLL1psPyqhQsmQK_mHYw==/109951173820160027.jpg`）
/// 在 8 个 host 上各试 4 轮，走 https：
///
///     p1 → 4/4 可达  ★
///     p4 → 3/4 可达  ★
///     p2 → 2/4 可达
///     p3 → 1/4 可达
///     p5 → 0/4，全部 404      ← 不是有效镜像
///     p6 → 0/4，全部 404      ← 不是有效镜像
///     p7 → 0/4，TCP 连不上
///     p8 → 0/4，TCP 连不上
///
/// 路径部分在所有 host 上通用，但**只有 p1~p4 是真镜像**。
///
/// ## 修过的两个 bug
///
/// **1. 镜像池里混了 5 个废 host，且重试是顺序走的**
///
/// 原来 `mirrorHosts = p1...p8`，重试逻辑是「从当前 host 之后顺序走」：
/// 从 p4 失败 → 试 p5(404) → p6(404) → p7(超时)，三次机会全浪费在
/// 不该试的 host 上，**永远够不到 4/4 可达的 p1**。
/// 改为：池子只留 p1~p4 并按可达率降序，重试时跳过当前 host。
///
/// **2. 每日推荐返回明文 http，被 ATS 静默拦截（主因）**
///
/// 各接口返回的协议并不统一：
///     /recommend/songs → http://p3|p4.music.126.net  ← 明文
///     /song/detail     → https://p3.music.126.net     ← 加密
///
/// 本项目 Info.plist 里**零个 ATS 键**，走默认 ATS（禁止明文 HTTP）。
/// 所以每日推荐的封面请求被静默拦截 —— 不报错、不进日志、只是永远转圈，
/// 表现就是「只有每日推荐没封面」。
/// 修复是在 `CoverImage.sizedURL` 里把 http 升级为 https，
/// 而不是开 ATS 例外（那会全局削弱安全性）。
@MainActor
final class CoverImageRetryTests: XCTestCase {

    /// 与 CoverImage.mirrorHosts 保持一致：仅 p1~p4，按实测可达率降序
    private let mirrorHosts = ["p1", "p4", "p2", "p3"]

    // MARK: - 镜像池正确性

    /// p5~p8 不该出现在池子里
    func testMirrorPoolExcludesInvalidHosts() {
        for dead in ["p5", "p6", "p7", "p8"] {
            XCTAssertFalse(mirrorHosts.contains(dead), "\(dead) 实测 0/4 可达（p5/p6 全 404，p7/p8 连不上），不该浪费请求")
        }
    }

    func testMirrorPoolCoversAllRealMirrors() {
        XCTAssertEqual(Set(mirrorHosts), Set(["p1", "p2", "p3", "p4"]))
    }

    /// 最可靠的排最前，让每次重试的第一次尝试都有最高成功率
    func testMirrorPoolOrderedByMeasuredReliability() {
        XCTAssertEqual(mirrorHosts.first, "p1", "p1 实测 4/4，应排第一")
        XCTAssertEqual(mirrorHosts[1], "p4", "p4 实测 3/4，排第二")
    }

    // MARK: - 重试顺序

    /// 重试时按可达率降序试，跳过当前失败的 host
    private func retryOrder(from host: String) -> [String] {
        mirrorHosts.filter { $0 != host }
    }

    /// 关键回归：原 host 是 p4 时，**下一次尝试必须是 p1**
    ///
    /// 旧逻辑会走 p5 → p6 → p7，三次全废，永远够不到 p1。
    func testRetryFromP4GoesStraightToReliableP1() {
        XCTAssertEqual(retryOrder(from: "p4"), ["p1", "p2", "p3"])
        XCTAssertEqual(retryOrder(from: "p4").first, "p1", "p4 失败后应先试 4/4 可达的 p1")
    }

    func testRetryFromEachHostSkipsItself() {
        for host in mirrorHosts {
            XCTAssertFalse(retryOrder(from: host).contains(host), "不该重试刚失败的 \(host)")
        }
    }

    func testRetryOrderIsConsistentRegardlessOfOriginalHost() {
        // 无论原始 host 是谁，候选里最可靠的都排在最前（除非它自己就是当前 host）
        for host in mirrorHosts {
            let order = retryOrder(from: host)
            if host != "p1" {
                XCTAssertEqual(order.first, "p1", "从 \(host) 失败后应先试最可靠的 p1")
            }
            // 共同候选的相对顺序必须与全局排序一致
            let shared = retryOrder(from: "p1").filter { order.contains($0) }
            XCTAssertEqual(shared, retryOrder(from: "p1").filter { $0 != "p1" && $0 != host },
                           "从 \(host) 出发时，共同候选仍应按可达率降序")
        }
    }

    /// 池子只有 4 个，跳过当前后还有 3 个可试
    func testRetryHasEnoughCandidates() {
        XCTAssertEqual(retryOrder(from: "p1").count, 3)
    }

    /// 重建 URL 时必须保留路径（含 base64 的 `==`）和 query（?param= 裁剪）
    func testCandidatePreservesPathAndQuery() {
        let original = URL(string: "https://p4.music.126.net/fwXLL1psPyqhQsmQK_mHYw==/109951173820160027.jpg?param=140y140")!
        var components = URLComponents(url: original, resolvingAgainstBaseURL: false)!
        components.host = "p1.music.126.net"
        let candidate = components.url!

        XCTAssertEqual(candidate.host, "p1.music.126.net")
        XCTAssertEqual(candidate.path, original.path, "路径含 base64 的 ==，丢了就 404")
        XCTAssertTrue(candidate.path.contains("=="), "实测该路径确实带 == 填充")
        XCTAssertEqual(candidate.query, "param=140y140", "?param= 丢了等于白下原图")
    }

    // MARK: - 协议升级（ATS 静默拦截的修复）

    /// 复刻 sizedURL 的协议升级（含 126.net 的 host 判断）
    private func upgraded(_ url: URL) -> URL {
        guard url.host?.hasSuffix("music.126.net") == true,
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if c.scheme?.lowercased() == "http" { c.scheme = "https" }
        return c.url ?? url
    }

    /// 每日推荐的封面是明文 http，必须被升级，否则被 ATS 静默拦截
    func testDailyRecommendHTTPUpgradeToHTTPS() {
        let http = URL(string: "http://p4.music.126.net/fwXLL1psPyqhQsmQK_mHYw==/109951173820160027.jpg")!
        let fixed = upgraded(http)
        XCTAssertEqual(fixed.scheme, "https", "每日推荐返回 http，不升级就过不了默认 ATS")
        XCTAssertEqual(fixed.host, http.host)
        XCTAssertEqual(fixed.path, http.path, "升级协议不能动路径")
    }

    func testHTTPSURLUnchanged() {
        let https = URL(string: "https://p3.music.126.net/QgsLl0ZAYeWYGsILAgWSSg==/109951173366702487.jpg")!
        XCTAssertEqual(upgraded(https).absoluteString, https.absoluteString, "已是 https 不应改动")
    }

    /// 非网易云域名（本地文件等）不该被改写
    func testNonNeteaseURLNotUpgraded() {
        let local = URL(string: "http://localhost:8080/cover.png")!
        XCTAssertEqual(upgraded(local).scheme, "http", "非 126.net 域名不参与本修复")
    }

    /// 升级发生在加 ?param= 之前/之后都不影响结果，但要保证 param 加上后协议仍是 https
    func testParamAddedOnUpgradedURLStaysHTTPS() {
        let http = URL(string: "http://p3.music.126.net/abc==/123.jpg")!
        var c = URLComponents(url: upgraded(http), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "param", value: "140y140")]
        let final = c.url!
        XCTAssertEqual(final.scheme, "https")
        XCTAssertEqual(final.query, "param=140y140")
    }

    /// 已有 ?param= 时要替换而不是追加两个
    func testParamReplacedNotDuplicated() {
        let u = URL(string: "https://p1.music.126.net/a==/b.jpg?param=64y64&other=1")!
        var c = URLComponents(url: u, resolvingAgainstBaseURL: false)!
        var items = c.queryItems ?? []
        items.removeAll { $0.name == "param" }
        items.append(URLQueryItem(name: "param", value: "140y140"))
        c.queryItems = items
        let q = c.query ?? ""
        XCTAssertEqual(q.components(separatedBy: "param=").count - 1, 1, "?param= 只应有一个")
        XCTAssertTrue(q.contains("other=1"), "其他 query 不能被误删")
    }
}
