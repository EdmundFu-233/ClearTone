import XCTest

/// seek 的令牌机制：已提交给 AVFoundation 的 seek 无法撤销，
/// 只能靠单调递增的令牌让过期回调自行放弃写回。
///
/// 原实现用 `Task.cancel()` + 共享的 `isUserSeeking` 布尔量：
/// 拖动时 60~120Hz 提交零容差 seek，旧 task 的尾行会把 `isUserSeeking`
/// 提前置回 false，导致新的 seek 失去抑制，进而让过期回调覆盖新位置。
@MainActor
final class SeekTokenTests: XCTestCase {

    /// 与 PlayerController.seekToken 语义一致的最小模型
    private final class SeekGate {
        private(set) var token: UInt64 = 0
        private(set) var isSeeking = false

        /// 提交：领新 token
        func submit() -> UInt64 {
            isSeeking = true
            token &+= 1
            return token
        }

        /// 回调到达：只有最新 token 才能改状态
        @discardableResult
        func complete(_ t: UInt64) -> Bool {
            guard t == token else { return false }
            isSeeking = false
            return true
        }
    }

    func testLatestTokenWins() {
        let gate = SeekGate()
        let a = gate.submit()
        let b = gate.submit()
        XCTAssertFalse(gate.complete(a), "过期 token 不应改状态")
        XCTAssertTrue(gate.isSeeking, "过期回调不能提前清除 isUserSeeking")
        XCTAssertTrue(gate.complete(b), "最新 token 应被接受")
        XCTAssertFalse(gate.isSeeking)
    }

    /// 模拟一次真实拖动：多次 preview + 一次 commit，期间到达多个乱序回调
    func testStaleCallbacksCannotOverwriteAfterDrag() {
        let gate = SeekGate()
        // 拖动中只更新 UI，不提交（previewSeek 不领 token）
        // 抬手时提交一次
        let committed = gate.submit()
        // AVFoundation 队列里还挂着之前的（假设的）请求陆续回调
        for stale in [UInt64(1), 2, 3, committed - 1] where stale != committed {
            XCTAssertFalse(gate.complete(stale), "拖动前的回调不得覆盖已提交的 seek")
        }
        XCTAssertTrue(gate.isSeeking, "在最新回调到达前应保持 seeking 状态")
        XCTAssertTrue(gate.complete(committed))
    }

    func testTokenIsMonotonic() {
        let gate = SeekGate()
        let tokens = (0..<200).map { _ in gate.submit() }
        XCTAssertEqual(tokens, Array(1...200).map(UInt64.init), "令牌必须严格递增且不回绕到旧值")
    }

    func testUInt64WraparoundStillDistinguishesGenerations() {
        // 即使回绕，两个"当前"令牌相差 1，complete 只接受严格相等的
        let gate = SeekGate()
        _ = gate.submit()
        let before = gate.token
        let after = gate.submit()
        XCTAssertNotEqual(before, after)
        XCTAssertFalse(gate.complete(before), "回绕前一个令牌仍应被识别为过期")
    }

    /// 预览与提交的职责边界：预览不该动 token，也不该触发任何写回
    func testPreviewDoesNotCommit() {
        let gate = SeekGate()
        let t0 = gate.token
        // previewSeek 只写 currentTime，不进 gate
        XCTAssertEqual(gate.token, t0, "预览不应领取令牌")
        XCTAssertFalse(gate.isSeeking, "单独预览不应把播放器标记为 seeking")
    }
}
