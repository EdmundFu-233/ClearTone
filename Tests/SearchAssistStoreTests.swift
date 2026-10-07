import XCTest

/// 搜索辅助 store：联想节流、历史记录。
@MainActor
final class SearchAssistStoreTests: XCTestCase {

    /// 记录调用次数的桩。不联网，因此「有没有发请求」是可断言的事实，
    /// 而不是对网络状况的猜测。
    private final class StubSource: SearchAssistSource, @unchecked Sendable {
        private(set) var suggestionCalls: [String] = []
        private(set) var hotCalls = 0
        var suggestions: [SearchSuggestion] = []
        var hotTerms: [HotSearchTerm] = []
        var error: Error?

        func fetchSearchSuggestions(keyword: String) async throws -> [SearchSuggestion] {
            suggestionCalls.append(keyword)
            if let error { throw error }
            return suggestions
        }

        func fetchHotSearchTerms() async throws -> [HotSearchTerm] {
            hotCalls += 1
            if let error { throw error }
            return hotTerms
        }
    }

    /// 每个测试用独立的 UserDefaults suite，互不干扰也不碰真实用户数据
    private func makeStore(source: SearchAssistSource = StubSource()) -> SearchAssistStore {
        let suite = "SearchAssistStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return SearchAssistStore(defaults: defaults, source: source)
    }

    // MARK: - 联想节流

    /// 空关键词不该发请求，也不该保留旧建议
    func testEmptyKeywordClearsSuggestions() async {
        let store = makeStore()
        store.querySuggestions("")
        XCTAssertTrue(store.suggestions.isEmpty)
        XCTAssertFalse(store.isLoadingSuggestions)

        store.querySuggestions("   ")
        XCTAssertTrue(store.suggestions.isEmpty, "纯空白等同空")
    }

    /// 节流：连续变更只应触发最后一次。
    /// 中文输入法一次输入会连发多次 onChange，逐次请求既浪费又会让结果乱序。
    func testSuggestionsAreDebounced() async {
        let source = StubSource()
        source.suggestions = [SearchSuggestion(kind: .song, title: "周杰伦", targetID: "1")]
        let store = makeStore(source: source)

        for partial in ["周", "周杰", "周杰伦", "周杰伦的"] {
            store.querySuggestions(partial)
        }
        // 节流窗口内：一次都不该发出去
        XCTAssertTrue(source.suggestionCalls.isEmpty, "节流窗口内不应发请求")
        XCTAssertTrue(store.suggestions.isEmpty)

        // 等过节流窗口
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(source.suggestionCalls, ["周杰伦的"], "只应请求最后一个关键词")
        XCTAssertEqual(store.suggestions.count, 1)
        XCTAssertFalse(store.isLoadingSuggestions)
    }

    /// 联想失败不该把错误抛给用户 —— 静默清空即可
    func testSuggestionFailureIsSilent() async {
        let source = StubSource()
        source.error = MusicError.networkUnavailable
        let store = makeStore(source: source)
        store.querySuggestions("test")
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(store.suggestions.isEmpty)
        XCTAssertFalse(store.isLoadingSuggestions, "失败后必须复位 loading，否则界面永久转圈")
    }

    /// 热搜只加载一次（第二次调用直接返回）
    func testHotTermsAreCachedInStore() async {
        let source = StubSource()
        source.hotTerms = [HotSearchTerm(keyword: "周杰伦", score: 100)]
        let store = makeStore(source: source)
        await store.loadHotTerms()
        await store.loadHotTerms()
        XCTAssertEqual(source.hotCalls, 1, "热搜不应重复请求")
        XCTAssertEqual(store.hotTerms.count, 1)
    }

    func testClearSuggestionsResetsState() {
        let store = makeStore()
        store.querySuggestions("test")
        store.clearSuggestions()
        XCTAssertTrue(store.suggestions.isEmpty)
    }

    // MARK: - 搜索历史

    func testRecordSearchPrependsAndDeduplicates() {
        let store = makeStore()

        store.recordSearch("周杰伦")
        store.recordSearch("林俊杰")
        XCTAssertEqual(store.history, ["林俊杰", "周杰伦"], "最新的在最前")

        // 重复搜索应移到最前而不是多出一条
        store.recordSearch("周杰伦")
        XCTAssertEqual(store.history, ["周杰伦", "林俊杰"])
        XCTAssertEqual(store.history.count, 2)
    }

    /// 大小写不同的同一关键词不应重复
    func testRecordSearchIsCaseInsensitive() {
        let store = makeStore()
        store.recordSearch("Adele")
        store.recordSearch("adele")
        XCTAssertEqual(store.history.count, 1)
        // 保留最近一次书写的形式
        XCTAssertEqual(store.history.first, "adele")
    }

    func testBlankSearchIsNotRecorded() {
        let store = makeStore()
        store.recordSearch("")
        store.recordSearch("   \n ")
        XCTAssertTrue(store.history.isEmpty)
    }

    /// 历史条数有上限，否则 UserDefaults 会被撑大
    func testHistoryIsCapped() {
        let store = makeStore()
        for i in 0..<40 {
            store.recordSearch("词\(i)")
        }
        XCTAssertEqual(store.history.count, 20, "历史上限应为 20 条")
        XCTAssertEqual(store.history.first, "词39", "保留的是最近的 20 条")
    }

    func testRemoveAndClearHistory() {
        let store = makeStore()
        store.recordSearch("A")
        store.recordSearch("B")
        store.removeHistory("A")
        XCTAssertEqual(store.history, ["B"])
        store.clearHistory()
        XCTAssertTrue(store.history.isEmpty)
    }

    /// 历史要能落盘并在下次启动读回来
    func testHistoryPersists() {
        let suite = "SearchAssistStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let store = SearchAssistStore(defaults: defaults)
        store.recordSearch("持久化测试")
        // 新实例模拟冷启动：同一个 defaults 必须读回历史
        let reloaded = SearchAssistStore(defaults: defaults)
        XCTAssertEqual(reloaded.history, ["持久化测试"])
    }

    // MARK: - 热搜与历史的失败路径

    /// `.task { loadHotTerms() }` 被取消（切侧栏 / 窗口失焦）后，
    /// `isLoadingHot` 必须复位，否则面板永久转圈、空态占位与重试按钮都不显示，
    /// 且下次进来被 `!isLoadingHot` 守卫直接挡掉 —— 本进程内热搜永远空白、无报错。
    func testCancelledHotTermsLoadDoesNotStickSpinner() async {
        let source = StubSource()
        source.hotTerms = [HotSearchTerm(keyword: "周杰伦", score: 100)]
        let store = makeStore(source: source)

        // 在任务开跑前就取消，模拟 `.task` 立刻被拿掉
        let task = Task { await store.loadHotTerms() }
        task.cancel()
        await task.value

        XCTAssertFalse(store.isLoadingHot, "取消路径必须复位 loading（原先三处 early-return 全跳过了收尾赋值）")

        // 复位之后必须还能重新拉取
        await store.loadHotTerms()
        XCTAssertEqual(source.hotCalls, 2, "取消后要能重来，不能被 !isLoadingHot 挡死")
        XCTAssertEqual(store.hotTerms.count, 1)
    }

    /// 热搜失败要有错误态 + 能重试
    func testHotTermsFailureIsSurfacedAndRetryable() async {
        let source = StubSource()
        source.error = MusicError.networkUnavailable
        let store = makeStore(source: source)

        await store.loadHotTerms()
        XCTAssertNotNil(store.hotError)
        XCTAssertFalse(store.isLoadingHot, "失败后必须复位，否则重试按钮出不来")

        source.error = nil
        source.hotTerms = [HotSearchTerm(keyword: "重试", score: 1)]
        await store.loadHotTerms()
        XCTAssertNil(store.hotError, "重试成功后错误要清掉")
        XCTAssertEqual(store.hotTerms.count, 1)
    }

    /// 删除历史必须与 `recordSearch` 用同一套大小写比较 ——
    /// 否则记录时按大小写归一、删除时按 `==`，点掉一条会留着它的另一个变体。
    func testRemoveHistoryIsCaseInsensitive() {
        let store = makeStore()
        store.recordSearch("周杰伦")
        store.removeHistory("周杰伦")
        XCTAssertTrue(store.history.isEmpty)

        store.recordSearch("Adele")
        store.removeHistory("adele")
        XCTAssertTrue(store.history.isEmpty, "大小写不同的同一关键词删不掉就是历史残留")
    }

    /// 上限改小（或历史是老版本写的）时，从磁盘读进来的超限条目也要裁掉。
    func testHistoryIsCappedOnLoad() {
        let suite = "SearchAssistStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set((0..<40).map { "旧词\($0)" }, forKey: "cleartone.search.history")

        let store = SearchAssistStore(defaults: defaults)
        XCTAssertEqual(
            store.history.count, 20,
            "只在写入侧裁剪的话，磁盘上的超限旧条目会永久超限、界面上删不干净"
        )
    }
}

/// 播放模式轮转 + 相对 seek 的策略（菜单快捷键依赖这两个方法）
@MainActor
final class PlaybackCommandTests: XCTestCase {

    func testCyclePlayModeOrder() {
        let player = PlayerController.shared
        let original = player.queue.mode
        defer { player.setPlayMode(original) }

        player.setPlayMode(.sequential)
        player.cyclePlayMode()
        XCTAssertEqual(player.queue.mode, .loopAll)

        player.cyclePlayMode()
        XCTAssertEqual(player.queue.mode, .loopOne)

        player.cyclePlayMode()
        XCTAssertEqual(player.queue.mode, .shuffle)

        // 随机再轮一次回到顺序，形成闭环
        player.cyclePlayMode()
        XCTAssertEqual(player.queue.mode, .sequential)
    }

    /// ±15 秒不能把进度推到 song 之外
    func testSeekByClampsToValidRange() {
        let player = PlayerController.shared
        // 没有在播放时不应崩溃，也不应产生非法进度
        let before = player.currentTime
        player.seek(by: 15)
        XCTAssertGreaterThanOrEqual(player.currentTime, 0)
        player.seek(by: -1000)
        XCTAssertGreaterThanOrEqual(player.currentTime, 0)
        XCTAssertNotEqual(player.currentTime, -1, "进度不能为负")
        _ = before
    }
}
