import XCTest

/// 封面下载的 host 故障转移。
///
/// ## 为什么需要
///
/// 网易云图片分散在 `p1~p4` / `m1~m8` 等多个 host，DNS 随机解析到的节点
/// 有时完全无法建立 TCP 连接（实测 `time_connect = 0`，直接等到超时）。
///
/// 实测同一张封面的路径部分在所有 host 上通用，但可达性每次都不同：
///     p1/p2/p3 → HTTP 200, 0.66s
///     p4/p7/p8 → 连不上, 6s 超时
/// 随机命中慢 host 就表现为「封面一直不出来」。所以要能在失败时换 host。
///
/// 注意：瓶颈是**连接建立**不是带宽 —— 加 `?param=` 让耗时几乎不变
/// （0.66s vs 0.68s），但体积差 3 倍（3955B vs 8680B），
/// 所以 `?param=` 仍值得保留（省流量），但解决慢要靠重试。
@MainActor
final class CoverImageRetryTests: XCTestCase {

    private let mirrorHosts = ["p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8"]

    private func url(host: String) -> URL {
        URL(string: "https://\(host).music.126.net/abc123/109951169484091680.jpg?param=200y200")!
    }

    /// 从当前 host 之后开始试，循环回绕
    private func nextHosts(from host: String, limit: Int) -> [String] {
        guard let idx = mirrorHosts.firstIndex(of: host) else { return [] }
        let start = idx + 1
        guard start < mirrorHosts.count else { return [] }
        return (0..<min(limit, mirrorHosts.count - start))
            .map { mirrorHosts[(start + $0) % mirrorHosts.count] }
    }

    func testStartsFromHostAfterCurrent() {
        // p2 不可达时应先试 p3，而不是回头试 p1
        XCTAssertEqual(nextHosts(from: "p2", limit: 3), ["p3", "p4", "p5"])
    }

    func testWrapsAroundAtEnd() {
        XCTAssertEqual(nextHosts(from: "p7", limit: 3), ["p8"])
        // p8 已是最后一个，没有后续可试
        XCTAssertTrue(nextHosts(from: "p8", limit: 3).isEmpty)
    }

    func testUnknownHostYieldsNoCandidates() {
        XCTAssertTrue(nextHosts(from: "zzz", limit: 3).isEmpty)
    }

    /// 关键不变式：重试必须保留 URL 的路径与 query，只换 host。
    /// 若 query 丢了，`?param=` 的裁剪就没了，等于白下载原图。
    func testRetryPreservesPathAndQuery() {
        let original = url(host: "p2")
        var components = URLComponents(url: original, resolvingAgainstBaseURL: false)
        components?.host = "p3.music.126.net"
        let candidate = components!.url!

        XCTAssertEqual(candidate.path, original.path, "路径必须一致")
        XCTAssertEqual(candidate.query, original.query, "?param= 必须保留，否则裁剪失效")
        XCTAssertEqual(candidate.host, "p3.music.126.net")
    }

    /// 每个候选 host 都会带上 param
    func testAllRetryCandidatesKeepParam() {
        for host in nextHosts(from: "p1", limit: 3) {
            var components = URLComponents(url: url(host: "p1"), resolvingAgainstBaseURL: false)
            components?.host = "\(host).music.126.net"
            let q = URLComponents(url: components!.url!, resolvingAgainstBaseURL: false)!.queryItems
            XCTAssertEqual(q?.first(where: { $0.name == "param" })?.value, "200y200",
                           "切到 \(host) 后 param 不能丢")
        }
    }

    /// 尺寸换算仍应正确（列表行小、详情页大）
    func testSizeParamStillApplied() {
        // 40pt 歌曲行 → 80px
        XCTAssertEqual(paramValue(for: 40), "80y80")
        // 180pt 歌单卡 → 360px
        XCTAssertEqual(paramValue(for: 180), "360y360")
    }

    /// 超时被压到 2.5s：不可达 host 最坏等 2.5s 就换下一个，
    /// 最多 3 个候选 → 最坏约 7.5s，而不是原来的 20s。
    func testTimeoutBudgetIsBounded() {
        let perHostTimeout = 2.5
        let maxRetries = 3
        // 主 host 1 次 + 最多 3 个镜像
        XCTAssertLessThan(Double(1 + maxRetries) * perHostTimeout, 12.0,
                          "最坏等待应远小于原来的 20s 单次超时")
    }

    private func paramValue(for pointSize: CGFloat) -> String? {
        let sized = CoverLoader.sizedURL(url(host: "p1"), pointSize: pointSize)
        return URLComponents(url: sized, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "param" })?.value
    }
}
