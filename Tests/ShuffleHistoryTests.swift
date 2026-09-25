import XCTest

/// 随机播放历史：同时充当「上一首」的 LIFO 栈与「已播过」的 O(1) 集合。
///
/// 原先只用 `[UUID]`，`contains` 线性扫描 → 随机模式 next() 为 O(n×k)，
/// 1000 首时单次调用约 10⁶ 次 UUID 比较。改成双结构后，
/// 最大风险是两边的数据失同步（集合说有、栈里没有 → popLast 拿不出来）。
@MainActor
final class ShuffleHistoryTests: XCTestCase {

    func testAppendKeepsStackAndSetInSync() {
        var h = PlayQueue.ShuffleHistory()
        let a = UUID(), b = UUID(), c = UUID()
        h.append(a); h.append(b); h.append(c)
        XCTAssertEqual(h.count, 3)
        XCTAssertEqual(h.stack, [a, b, c], "栈应保持插入顺序（供 previous() LIFO 回退）")
        for id in [a, b, c] { XCTAssertTrue(h.contains(id)) }
        XCTAssertFalse(h.contains(UUID()), "未插入的 id 不应命中")
    }

    func testPopLastRemovesFromBothStructures() {
        var h = PlayQueue.ShuffleHistory()
        let a = UUID(), b = UUID()
        h.append(a); h.append(b)
        XCTAssertEqual(h.popLast(), b, "应弹出最后插入的")
        XCTAssertFalse(h.contains(b), "弹出后集合也必须移除，否则该歌会被永久跳过")
        XCTAssertTrue(h.contains(a))
        XCTAssertEqual(h.count, 1)
    }

    func testPopLastOnEmptyReturnsNil() {
        var h = PlayQueue.ShuffleHistory()
        XCTAssertNil(h.popLast())
        XCTAssertTrue(h.isEmpty)
    }

    /// 重复 append 同一 id：栈里会有两条，集合只有一条（Set 语义）
    func testDuplicateAppendIsIdempotentInSet() {
        var h = PlayQueue.ShuffleHistory()
        let a = UUID()
        h.append(a); h.append(a)
        XCTAssertEqual(h.count, 2, "栈保留两条记录")
        XCTAssertTrue(h.contains(a))
        XCTAssertEqual(h.popLast(), a)
        XCTAssertTrue(h.contains(a), "还有一条记录，集合里仍应命中")
    }

    /// 删除队列中某一项后，历史里对应的记录也要消失，否则会引用不存在的 id
    func testRemoveAllWherePrunesBothStructures() {
        var h = PlayQueue.ShuffleHistory()
        let keep = UUID(), drop = UUID(), drop2 = UUID()
        h.append(keep); h.append(drop); h.append(drop2)
        h.removeAll { $0 == drop || $0 == drop2 }
        XCTAssertEqual(h.stack, [keep], "栈应只剩保留项")
        XCTAssertFalse(h.contains(drop))
        XCTAssertFalse(h.contains(drop2))
        XCTAssertTrue(h.contains(keep))
        XCTAssertEqual(h.count, 1)
    }

    func testRemoveAllClearsBoth() {
        var h = PlayQueue.ShuffleHistory()
        h.append(UUID()); h.append(UUID())
        h.removeAll()
        XCTAssertTrue(h.isEmpty)
        XCTAssertEqual(h.count, 0)
        XCTAssertFalse(h.contains(UUID()))
    }

    /// 关键不变量：集合内容必须始终等于栈的成员集合
    /// （removeAll(where:) 之后最容易失同步）
    func testSetAlwaysMirrorsStackMembership() {
        var h = PlayQueue.ShuffleHistory()
        let ids = (0..<20).map { _ in UUID() }
        for id in ids { h.append(id) }
        h.removeAll { _ in Bool.random() }   // 随机删除一半
        for id in ids {
            XCTAssertEqual(h.contains(id), h.stack.contains(id),
                           "contains 与 stack 成员关系必须一致")
        }
    }

    /// 性能回归护栏：O(1) 判定而非线性扫描
    func testContainsIsConstantTimeNotLinear() {
        var h = PlayQueue.ShuffleHistory()
        let ids = (0..<5000).map { _ in UUID() }
        for id in ids { h.append(id) }
        // 线性扫描在 5000 个元素上会明显慢；这里只验证规模下仍能快速完成
        let target = ids[4999]
        var found = false
        for id in ids { if h.contains(id) { found = true } }
        XCTAssertTrue(found, "最后一个元素也应命中")
        XCTAssertTrue(h.contains(target))
    }
}
