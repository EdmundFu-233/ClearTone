import XCTest
@testable import ClearTone

/// 收藏写操作的限流护栏。
///
/// ## 这条测试对应一个真实的线上现象
///
/// 账号触发网易云写接口限流后，**所有**写接口一起挂：
/// `/like` 回 `524 当前环境异常`，连无关的 `/playlist/subscribe` 都回
/// `405 操作过于频繁`（同一账号、同一时刻，读接口全 200）。
///
/// 原实现对心形点击**没有任何在途保护**：一次点击一个 `Task`，
/// 连点 10 次就是 10 个并发写请求，而每一次被拒都会让限流窗口继续延长 ——
/// 用户越着急点，越点不出来。
@MainActor
final class LikeWriteThrottleTests: XCTestCase {

    // MARK: - 哪些错误算「别再试」

    /// 405 / 524 是限流，必须冷却。
    ///
    /// 证据：同一时刻、同一 cookie，`/playlist/subscribe` 返回
    /// `405 操作过于频繁，请稍后再试`。
    func testRateLimitCodesAreThrottled() {
        XCTAssertTrue(AppState.isWriteThrottled(MusicError.apiError(code: 405, message: "操作过于频繁")))
        XCTAssertTrue(AppState.isWriteThrottled(MusicError.apiError(code: 524, message: "当前环境异常")))
        XCTAssertTrue(AppState.isWriteThrottled(MusicError.rateLimited))
    }

    /// 其余错误重试是有意义的，**不能**冷却 ——
    /// 否则「这首歌下架了」会把所有心形按钮冻住 30 秒。
    func testNonThrottleErrorsAreNotCooledDown() {
        XCTAssertFalse(AppState.isWriteThrottled(MusicError.apiError(code: 404, message: "歌曲不存在")))
        XCTAssertFalse(AppState.isWriteThrottled(MusicError.apiError(code: 500, message: "服务器错误")))
        XCTAssertFalse(AppState.isWriteThrottled(MusicError.notLoggedIn))
        XCTAssertFalse(AppState.isWriteThrottled(MusicError.networkUnavailable))
    }

    // MARK: - 提示文案

    /// 服务端原文没告诉用户「别再点」，提示必须补上这一句。
    /// 用户看不懂「当前环境异常」就会继续点，把窗口越拖越长。
    func testThrottleMessageTellsUserNotToKeepClicking() throws {
        let message = NeteaseProvider.likeFailureMessage([
            "code": 524, "message": "当前环境异常，已取消喜欢",
        ])
        XCTAssertTrue(message.contains("当前环境异常"), "要保留服务端原文")
        XCTAssertTrue(message.contains("限流"), "要说清这是限流而不是 App 坏了")
        XCTAssertTrue(message.contains("连点"), "必须明确劝阻连点")
    }

    func testThrottleMessageMentionsTheSameCooldownTheStateUses() throws {
        // 提示里写的秒数必须与实际冷却一致，否则用户按提示等了还是不行
        let message = NeteaseProvider.likeFailureMessage([
            "code": 405, "message": "操作过于频繁，请稍后再试",
        ])
        XCTAssertTrue(message.contains("\(AppState.likeWriteCooldownSeconds)"))
    }

    /// 非限流错误不加多余解释，保持服务端原文
    func testNormalFailureKeepsServerText() {
        let message = NeteaseProvider.likeFailureMessage([
            "code": 404, "message": "歌曲不存在",
        ])
        XCTAssertEqual(message, "歌曲不存在")
    }

    func testFailureWithoutServerTextStillProducesMessage() {
        let message = NeteaseProvider.likeFailureMessage(["code": -1])
        XCTAssertFalse(message.isEmpty)
    }
}
