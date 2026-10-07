import XCTest
import Foundation

/// GPU 在途帧背压闸门。
///
/// `AmbientBackgroundRenderer` 用它做背压，而那个类被 `project.yml`
/// 排除在测试 target 之外（要活的 MTLDevice + Bundle.main 里的 shader），
/// 所以判定逻辑必须抽成这个带锁的纯类型才测得到。
///
/// 要锁住两件事：
/// 1. 计数**绝不越过上限** —— 跨线程非原子的 `+=` 丢一次更新就会越界，
///    越界后 `draw(in:)` 每帧都早退、画面冻在最后一帧且没有复位路径；
/// 2. 每次占位最终都能归还 —— 丢一次 `-=` 同样会让计数单调爬升。
final class InFlightGateTests: XCTestCase {

    func testAcquireSucceedsUntilFull() {
        let gate = InFlightGate(maxInFlight: 2)
        XCTAssertTrue(gate.tryAcquire(), "第一帧应放行")
        XCTAssertTrue(gate.tryAcquire(), "第二帧应放行")
        XCTAssertFalse(gate.tryAcquire(), "满了必须拒绝，否则背压失效、显存单调增长")
        XCTAssertTrue(gate.isFull)
    }

    func testReleaseUnblocksSubsequentFrames() {
        let gate = InFlightGate(maxInFlight: 2)
        _ = gate.tryAcquire()
        _ = gate.tryAcquire()
        XCTAssertFalse(gate.tryAcquire())

        gate.release()
        XCTAssertFalse(gate.isFull, "归还一个名额后应恢复")
        XCTAssertTrue(gate.tryAcquire(), "归还后必须能重新占位（否则画面永久卡死）")
    }

    /// 多还不能把计数打成负数：负数会让 `count < max` 恒真，
    /// 背压从此永远放行，等于这个闸门不存在。
    func testReleaseNeverGoesNegative() {
        let gate = InFlightGate(maxInFlight: 2)
        gate.release()
        gate.release()
        XCTAssertEqual(gate.inFlight, 0, "没有占位就归还，计数不得下穿 0")
        XCTAssertTrue(gate.tryAcquire())
        XCTAssertEqual(gate.inFlight, 1, "下穿 0 会让后续计数整体偏移")
    }

    /// 从多个线程并发占位：**计数一次都不能越过上限**。
    ///
    /// 这正是原先裸 `var` 的失败模式 —— `count += 1` 是读-改-写，
    /// 并发执行时会丢失更新，于是实际在途帧数可以远超声明值。
    func testConcurrentAcquireNeverExceedsMax() {
        let gate = InFlightGate(maxInFlight: 2)

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            for _ in 0..<500 {
                _ = gate.tryAcquire()
            }
        }

        XCTAssertEqual(
            gate.inFlight, gate.maxInFlight,
            "并发下计数必须恰好停在上限（丢更新会让它越界，或低于上限）"
        )
        gate.release()
        gate.release()
        XCTAssertEqual(gate.inFlight, 0, "全部归还后必须回到 0")
        XCTAssertTrue(gate.tryAcquire(), "归零后闸门要能继续工作")
    }

    /// 占位/归还严格配对时，跑多少轮都必须归零 —— 丢一次 `-=` 就再也回不来。
    func testBalancedTrafficAlwaysReturnsToZero() {
        let gate = InFlightGate(maxInFlight: 4)

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<1_000 {
                if gate.tryAcquire() { gate.release() }
            }
        }

        XCTAssertEqual(gate.inFlight, 0, "占位与归还必须严格配对")
        XCTAssertTrue(gate.tryAcquire(), "计数为 0 时闸门不应被自己锁死")
    }
}
