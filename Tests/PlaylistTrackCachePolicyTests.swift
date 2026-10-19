import XCTest

/// 歌单曲目缓存的新鲜度判定：
/// - 可信窗口（60s）内：直接用缓存，不发请求
/// - 超过可信窗口、未过保留期（600s）：先渲染缓存，后台校准
/// - 超过保留期：视为未命中，走完整加载
///
/// 背景：原先只有「600 秒内直接用、超过就整页重载」两档，命中时完全不
/// 校验 —— 在别处加的歌最长 10 分钟不出现。三档之后旧清单的展示时间
/// 被限制在一个可信窗口内，随后会被静默校准。
final class PlaylistTrackCachePolicyTests: XCTestCase {

    private func decision(age: TimeInterval) -> PlaylistTrackCachePolicy.Decision {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        return PlaylistTrackCachePolicy.decision(cachedAt: now.addingTimeInterval(-age), now: now)
    }

    func testFreshInsideTrustWindow() {
        XCTAssertEqual(decision(age: 0), .fresh)
        XCTAssertEqual(decision(age: 1), .fresh)
        XCTAssertEqual(decision(age: PlaylistTrackCachePolicy.trustInterval - 0.001), .fresh)
    }

    /// 边界取闭区间外的第一点：恰好等于可信窗口时进入校准档。
    func testStaleAtTrustBoundary() {
        XCTAssertEqual(decision(age: PlaylistTrackCachePolicy.trustInterval), .stale)
        XCTAssertEqual(decision(age: PlaylistTrackCachePolicy.trustInterval + 0.001), .stale)
        XCTAssertEqual(decision(age: 300), .stale)
        XCTAssertEqual(decision(age: PlaylistTrackCachePolicy.maximumAge - 0.001), .stale)
    }

    func testMissAtMaximumAge() {
        XCTAssertEqual(decision(age: PlaylistTrackCachePolicy.maximumAge), .miss)
        XCTAssertEqual(decision(age: PlaylistTrackCachePolicy.maximumAge + 0.001), .miss)
        XCTAssertEqual(decision(age: 86_400), .miss)
    }

    /// 时钟回拨（缓存时间落在未来）按 fresh 处理：否则缓存永远无法可信，
    /// 每次进入歌单都整页重载。
    func testClockRollbackTreatsCacheAsFresh() {
        XCTAssertEqual(decision(age: -1), .fresh)
        XCTAssertEqual(decision(age: -86_400), .fresh)
    }

    /// 三档必须覆盖真实用到的取值路径，不允许出现真空区。
    func testEveryPositiveAgeIsCovered() {
        var age: TimeInterval = 0
        while age <= PlaylistTrackCachePolicy.maximumAge * 2 {
            let result = decision(age: age)
            if age < PlaylistTrackCachePolicy.trustInterval {
                XCTAssertEqual(result, .fresh, "age=\(age)")
            } else if age < PlaylistTrackCachePolicy.maximumAge {
                XCTAssertEqual(result, .stale, "age=\(age)")
            } else {
                XCTAssertEqual(result, .miss, "age=\(age)")
            }
            age += 7.3
        }
    }
}
