import XCTest

/// 排行榜目录状态机。
///
/// 放在 `Core/` 才测得到（`Features/**` 被测试 target 排除）。
/// 这里锁住四件事：成功填充、失败保留旧数据、**旧响应不得覆盖新响应**、
/// 取消（视图消失）后 `isLoading` 必须复位。
@MainActor
final class TopListSessionTests: XCTestCase {

    /// 可放行的桩：`hold` 打开时每次调用都挂起，直到测试显式放行某一次。
    /// 用它才能构造出「先发的请求后返回」——这正是代次令牌要挡的场景。
    private actor StubSource: TopListSource {
        private var lists: [TopList]
        private var error: Error?
        private(set) var calls = 0
        private var hold: Bool
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init(lists: [TopList] = [], error: Error? = nil, hold: Bool = false) {
            self.lists = lists
            self.error = error
            self.hold = hold
        }

        func setLists(_ value: [TopList]) { lists = value }
        func setError(_ value: Error?) { error = value }
        func callCount() -> Int { calls }
        var pendingCount: Int { waiting.count }

        func fetchTopLists() async throws -> [TopList] {
            calls += 1
            if hold {
                await withCheckedContinuation { waiting.append($0) }
            }
            if let error { throw error }
            return lists
        }

        /// 放行最先挂起的那次调用
        func resumeFirst() {
            guard !waiting.isEmpty else { return }
            waiting.removeFirst().resume()
        }

        /// 放行最后挂起的那次调用（模拟「后发的请求先回」）
        func resumeLast() {
            guard !waiting.isEmpty else { return }
            waiting.removeLast().resume()
        }
    }

    private func list(_ id: String, name: String = "飙升榜") -> TopList {
        TopList(id: id, name: name, trackCount: 100)
    }

    private func waitUntil(
        _ label: String, timeout: TimeInterval = 2, condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待\(label)超时")
    }

    func testLoadPopulatesLists() async {
        let source = StubSource(lists: [list("19723756", name: "飙升榜"), list("3779629")])
        let session = TopListSession(source: source)

        await session.load()

        XCTAssertEqual(session.lists.map(\.id), ["19723756", "3779629"])
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.isLoading, "加载完成后 spinner 必须消失")
    }

    /// 失败要**保留旧数据**并置错误 —— 否则「刷新失败」会把已经看到的榜单清空，
    /// 而且重试按钮靠这个错误态才显示得出来。
    func testFailureKeepsExistingListsAndSurfacesError() async {
        let source = StubSource(lists: [list("1")])
        let session = TopListSession(source: source)
        await session.load()
        XCTAssertEqual(session.lists.count, 1)

        await source.setError(MusicError.networkUnavailable)
        await session.load()

        XCTAssertEqual(session.lists.map(\.id), ["1"], "失败不该清掉旧数据")
        XCTAssertNotNil(session.errorMessage, "失败必须暴露错误")
        XCTAssertFalse(session.isLoading)
    }

    /// 视图消失时 `.task` 会取消在途请求：`isLoading` 不能停在 true，
    /// 否则回到本页就是永久转圈（SwiftUI 不会替你复位）。
    func testCancelledLoadResetsLoading() async {
        let source = StubSource(lists: [list("1")], hold: true)
        let session = TopListSession(source: source)

        let task = Task { await session.load() }
        await waitUntil("请求发出") { await source.pendingCount == 1 }
        XCTAssertTrue(session.isLoading)

        task.cancel()
        await source.resumeFirst()
        await task.value

        XCTAssertFalse(session.isLoading, "取消后必须复位 loading，否则面板永久转圈")
    }

    /// 迟到的旧响应不得覆盖新一次加载的结果。
    func testLateResponseFromOlderLoadIsDiscarded() async {
        let source = StubSource(lists: [list("old")], hold: true)
        let session = TopListSession(source: source)

        let first = Task { await session.load() }
        await waitUntil("第一次请求发出") { await source.pendingCount == 1 }
        let second = Task { await session.load() }
        await waitUntil("第二次请求发出") { await source.pendingCount == 2 }

        // 后发的第二次先返回：它是当前代次，应当生效
        await source.setLists([list("new")])
        await source.resumeLast()
        await second.value
        XCTAssertEqual(session.lists.map(\.id), ["new"])

        // 先发的第一次晚到：代次已过期，必须被丢弃
        await source.setLists([list("old")])
        await source.resumeFirst()
        await first.value
        XCTAssertEqual(session.lists.map(\.id), ["new"], "旧响应不得把新结果覆盖回去")
        XCTAssertFalse(session.isLoading)
    }
}
