import Foundation

/// GPU 在途帧的背压闸门。
///
/// ## 为什么单独抽出来
///
/// 这个计数原先只是渲染器上的一个裸 `var inFlightFrames`，三处读写分属两个线程：
/// `draw(in:)` 里的 `+= 1` 跑在 **draw 线程**（macOS 上 MTKView 由 CVDisplayLink
/// 驱动，不在主线程），`addCompletedHandler` 里的 `-= 1` 跑在 **Metal 命令队列的
/// completion 线程**。读-改-写不是原子的：
///
/// - 丢一次 `-=` → 计数单调爬升，一旦越过阈值 `draw(in:)` **每帧**都在背压判断处
///   早退 → 帧序号不再推进、`present()` 永不再调用 → 背景冻在最后一帧，
///   而且没有任何复位路径（`init` 只跑一次），不可自愈；
/// - 丢一次 `+=` → 背压失效，command queue 无界堆积、显存单调增长直到被内存压力杀掉
///   —— 正是这个闸门要防的事。
///
/// 抽成一个带锁的纯类型，还顺带把两个容易写错的边界钉死：
///
/// 1. **占位必须紧贴 commit**。早退点（无 drawable / 背压 / 降帧 /
///    `makeCommandBuffer` 失败）都发生在占位之前 —— 反过来写的话，
///    每次早退都会漏一个名额，几帧之后就被自己锁死。
/// 2. **阈值用 `>=`（即 `count < max` 才放行）**。原先写成 `count > max`，
///    实际允许 `max + 1` 帧在途，比声明多一档。
///
/// 之所以不直接测 `AmbientBackgroundRenderer`：它要活的 `MTLDevice` +
/// `Bundle.main` 里的 shader，且被 `project.yml` 排除在测试 target 之外。
public final class InFlightGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// 允许的在途帧数上限
    public let maxInFlight: Int

    public init(maxInFlight: Int) {
        self.maxInFlight = maxInFlight
    }

    /// 在途名额是否已用满（**只读**，不占名额）。
    /// 供 `draw(in:)` 在函数早期做廉价判断，真正的占位见 `tryAcquire()`。
    public var isFull: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count >= maxInFlight
    }

    /// 占一个在途名额。已满时返回 false，调用方应丢弃这一帧（背压早退）。
    public func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count < maxInFlight else { return false }
        count += 1
        return true
    }

    /// 归还一个名额。多还不会把计数打成负数（那样 `tryAcquire` 会永远放行，
    /// 背压彻底失效）。
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        count = max(0, count - 1)
    }

    /// 当前在途帧数（测试与诊断用）
    public var inFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
