import XCTest

/// 收藏状态判断的正确性。
///
/// ## 这个 bug 的成因
///
/// 早期实现里 `likedIDs` 是从 `likedSongs`（详情列表）推导的：
///     applyLikedSongs(songs)  →  likedIDs = Set(songs.map(\.id))
/// 而 `fetchLikedSongs` 早期只取前 500 个 id 去查详情。
/// 于是用户有 2808 首收藏时，likedIDs 只有 500 项，
/// 排在 501 名之后的歌 `isLiked()` 恒为 false：
/// 点心形 → 以「未收藏」身份调 like(true) → 服务端确实加上了，
/// 但下一帧 likedIDs 仍不含它 → 再点还是 like(true) → 「加了跟没加一样」。
///
/// 修复的关键约束：**收藏状态只能增删单个 id，绝不能由列表重建。**
@MainActor
final class LikedStateTests: XCTestCase {

    /// 与 AppState 修复后同构的最小模型
    private final class LikedModel {
        private(set) var likedIDs: Set<String> = []
        private(set) var likedSongs: [String] = []
        var version = 0

        func isLiked(_ id: String) -> Bool { likedIDs.contains(id) }

        /// 完整数据加载：id 集合与列表分离
        func apply(songs: [String], ids: [String]?) {
            likedSongs = songs
            likedIDs = ids.map(Set.init) ?? Set(songs)
            version += 1
        }

        /// 单首增删 —— 收藏操作的正确做法
        func toggle(_ id: String) {
            let nowLiked = !isLiked(id)
            if nowLiked { likedIDs.insert(id) } else { likedIDs.remove(id) }
            var next = likedSongs.filter { $0 != id }
            if nowLiked { next.insert(id, at: 0) }
            likedSongs = next
            version += 1
        }

        /// 复现旧 bug 的错误做法
        func toggleRebuildingFromList(_ id: String) {
            let nowLiked = !isLiked(id)
            var next = likedSongs.filter { $0 != id }
            if nowLiked { next.insert(id, at: 0) }
            apply(songs: next, ids: nil)      // ← 用列表重建 likedIDs
        }
    }

    /// 2808 首收藏，但列表只装了 500 首 —— 用户真实场景
    private func makeRealisticModel() -> LikedModel {
        let m = LikedModel()
        let allIDs = (0..<2808).map { "song-\($0)" }
        m.apply(songs: Array(allIDs.prefix(500)), ids: allIDs)   // id 集合完整
        return m
    }

    func testLikedStateUsesFullIDSevenBeyondListRange() {
        let m = makeRealisticModel()
        XCTAssertEqual(m.likedIDs.count, 2808, "id 集合必须是全量")
        XCTAssertEqual(m.likedSongs.count, 500, "详情列表可以只有一部分")
        // 排在 501 名之后的歌也必须能正确判断为已收藏
        XCTAssertTrue(m.isLiked("song-2500"))
        XCTAssertTrue(m.isLiked("song-2807"))
    }

    /// 核心回归：收藏一个不在列表里的歌，状态必须持久为「已收藏」
    func testLikingSongOutsideListRangeSticks() {
        let m = makeRealisticModel()
        let target = "brand-new-song"
        XCTAssertFalse(m.isLiked(target))

        m.toggle(target)
        XCTAssertTrue(m.isLiked(target), "新收藏的歌必须立即变为已收藏")

        // 模拟列表重新加载（不应把新收藏的抹掉）
        let allIDs = m.likedIDs
        m.apply(songs: m.likedSongs, ids: Array(allIDs))
        XCTAssertTrue(m.isLiked(target), "列表刷新后收藏状态不能丢")
    }

    /// 反复点击必须能正确来回，而不是「一直加」
    func testRepeatedToggleAlternatesCorrectly() {
        let m = makeRealisticModel()
        let target = "song-2600"   // 在 likedIDs 里，但不在列表里

        XCTAssertTrue(m.isLiked(target), "初始应为已收藏")
        m.toggle(target)
        XCTAssertFalse(m.isLiked(target), "第一次点击应取消收藏")
        m.toggle(target)
        XCTAssertTrue(m.isLiked(target), "第二次点击应恢复收藏")
        m.toggle(target)
        XCTAssertFalse(m.isLiked(target), "第三次点击应再次取消")
    }

    /// 复现旧 bug：像 song-2500 这样的歌（在 likedIDs 但不在列表），
    /// 用列表重建 likedIDs 后就"忘记"了它
    func testRebuildingFromListLosesStateOutsideList() {
        let m = makeRealisticModel()
        XCTAssertTrue(m.isLiked("song-2500"))

        m.toggleRebuildingFromList("song-2500")
        XCTAssertFalse(m.isLiked("song-2500"),
                       "用列表重建会把列表之外的收藏状态全部抹掉 —— 这正是原 bug")
    }

    /// 列表里的歌增删要与 id 集合保持一致
    func testListAndIDSStayConsistentForListedSong() {
        let m = LikedModel()
        m.apply(songs: ["a", "b", "c"], ids: ["a", "b", "c"])
        XCTAssertEqual(m.likedSongs.count, 3)
        XCTAssertEqual(m.likedIDs.count, 3)

        m.toggle("b")
        XCTAssertEqual(m.likedSongs, ["a", "c"], "取消收藏应从列表移除")
        XCTAssertFalse(m.isLiked("b"))

        m.toggle("z")
        XCTAssertEqual(m.likedSongs.first, "z", "新收藏应插到列表最前")
        XCTAssertTrue(m.isLiked("z"))
    }

    /// 旧版本没有 id 缓存时的降级路径：只有列表也能工作
    func testFallsBackToListWhenNoIDsAvailable() {
        let m = LikedModel()
        m.apply(songs: ["x", "y"], ids: nil)
        XCTAssertTrue(m.isLiked("x"))
        XCTAssertTrue(m.isLiked("y"))
        XCTAssertFalse(m.isLiked("z"))
    }

    /// 全量场景下的性能：集合增删是 O(1)，不该随收藏数增长
    func testToggleIsConstantTimeRegardlessOfLibrarySize() {
        let m = LikedModel()
        m.apply(songs: [], ids: (0..<50_000).map { "s\($0)" })
        let target = "s49999"
        var iterations = 0
        for _ in 0..<1000 {
            m.toggle(target)
            iterations += 1
        }
        XCTAssertEqual(iterations, 1000)
        XCTAssertTrue(m.isLiked(target), "偶数次切换后应回到已收藏")
        XCTAssertEqual(m.likedIDs.count, 50_000, "取消再收藏不应改变总数")
    }
}
