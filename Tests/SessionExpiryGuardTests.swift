import XCTest
@testable import ClearTone

/// 「点一次红心就丢登录」的回归测试。
///
/// 事故链条（`~/Library/Logs/ClearTone/helper.log` 实测）：
///
/// ```
/// /like → HTTP 301 → 广播 .clearToneSessionExpired
///       → 清空账号 + 红心缓存 + 歌单缓存 + 导航栈 + 弹扫码
/// 扫码 → /user/account 200 → /likelist 200   （会话一直是好的）
/// 再点红心 → 又 301 → 又弹扫码 …… 死循环
/// ```
///
/// 根因是 `NeteaseProvider.request` 把 301/401/403 一律当会话失效。
/// 辅助进程把上游业务码翻译成 HTTP 码（`util/request.js:490` +
/// `SPECIAL_STATUS_CODES` 不含 301），所以 301 的真实语义只是
/// 「**这个接口说它没登录**」，风控拒绝也走这条路。
///
/// 修法：只有旁证能定罪 —— 记疑似 → 探 `/user/account` → 探针也失败才清。
final class SessionExpiryGuardTests: XCTestCase {

    // MARK: - 核心：单次拒绝不定罪

    /// 单次 301/403 **绝不能**触发会话失效。
    /// 这条就是「点一次红心丢登录」的直接对应。
    func testSingleRejectionNeverDeclaresExpiry() {
        var guard_ = SessionExpiryGuard()
        XCTAssertEqual(guard_.noteRejection(), .ignore)
        XCTAssertEqual(guard_.suspicionCount, 1)
        // 没有 probeSession 就没有 resolveProbe，也就没有任何广播的时机
    }

    func testSecondRejectionAsksForProbe() {
        var guard_ = SessionExpiryGuard()
        _ = guard_.noteRejection()
        XCTAssertEqual(guard_.noteRejection(), .probeSession)
        XCTAssertTrue(guard_.isProbing)
    }

    // MARK: - 探针结果

    /// 探针通过 → 判定风控，保留登录态。
    /// 这是实际发生的那次：/like 回 301，但 /user/account 是 200。
    func testProbeSucceedingKeepsSessionAlive() {
        var guard_ = SessionExpiryGuard()
        _ = guard_.noteRejection()
        _ = guard_.noteRejection()
        XCTAssertEqual(guard_.resolveProbe(succeeded: true), .sessionAlive)
    }

    /// 探针也失败 → 这才是真掉登录。
    func testProbeFailingDeclaresExpiry() {
        var guard_ = SessionExpiryGuard()
        _ = guard_.noteRejection()
        _ = guard_.noteRejection()
        XCTAssertEqual(guard_.resolveProbe(succeeded: false), .sessionExpired)
    }

    // MARK: - 计数复位

    /// 一次探针就是一次完整裁决，不能把怀疑累积到下一次请求上。
    ///
    /// 否则会退化成「每两次任意 301 就探一次针」，
    /// 而真掉线时探针本来就该立刻失败 —— 累积只会让误报变多。
    func testProbeResetsSuspicionCount() {
        var guard_ = SessionExpiryGuard()
        _ = guard_.noteRejection()
        _ = guard_.noteRejection()
        _ = guard_.resolveProbe(succeeded: true)
        XCTAssertEqual(guard_.suspicionCount, 0)
        XCTAssertFalse(guard_.isProbing)
        // 复位后又要重新攒两次
        XCTAssertEqual(guard_.noteRejection(), .ignore)
    }

    /// 扫码成功后必须复位：新会话不该背着旧会话攒下的疑似次数。
    func testResetClearsSuspicionAndProbing() {
        var guard_ = SessionExpiryGuard()
        _ = guard_.noteRejection()
        _ = guard_.noteRejection()
        XCTAssertTrue(guard_.isProbing)
        guard_.reset()
        XCTAssertEqual(guard_.suspicionCount, 0)
        XCTAssertFalse(guard_.isProbing)
    }

    // MARK: - 重入

    /// 探针自己返回 301 时不能再触发一轮探针，否则无限递归。
    /// `NeteaseProvider.request` 的 `noteAuthRejection: false` 就是这个用途。
    func testProbeInFlightSuppressesFurtherProbes() {
        var guard_ = SessionExpiryGuard()
        _ = guard_.noteRejection()
        _ = guard_.noteRejection()
        XCTAssertTrue(guard_.isProbing)
        // 探针在途时再来 301：只记数，不再发起探针
        XCTAssertEqual(guard_.noteRejection(), .ignore)
        XCTAssertEqual(guard_.suspicionCount, 3)
    }

    func testThresholdIsTwo() {
        XCTAssertEqual(SessionExpiryGuard.suspicionThreshold, 2)
        // 阈值不能是 1：那等于「单次 301 就清登录态」，也就是原来的 bug
        XCTAssertGreaterThan(SessionExpiryGuard.suspicionThreshold, 1)
    }

    // MARK: - 错误语义拆分

    /// 401/403 不再被当成「会话失效」这一层的东西。
    ///
    /// 401 在这套 helper 里唯一来源是 `X-CT-Token` 不匹配（辅助进程重启竞态），
    /// 所以它对应 `helperAuthFailed`，与网易云会话无关。
    func testHelperAuthFailureIsDistinctFromSessionExpiry() {
        XCTAssertNotEqual(MusicError.helperAuthFailed, .sessionExpired)
        XCTAssertFalse(MusicError.helperAuthFailed.isRetryable)
    }

    /// 网易云风控拒绝走 `apiError`，文案要说清是「被拒绝」而不是「请重新登录」。
    ///
    /// 早期 301 会被翻译成「登录状态已过期，请重新登录」——
    /// 这句话本身就是误导：会话是好的，是接口在拒绝。
    func testRiskRejectionMessageDoesNotTellUserToRelogin() {
        let error = MusicError.apiError(code: 301, message: "网易云拒绝了这次请求（可能被风控），稍后重试")
        XCTAssertFalse(error.userFacingMessage.contains("重新登录"))
        XCTAssertTrue(error.userFacingMessage.contains("风控"))
    }
}
