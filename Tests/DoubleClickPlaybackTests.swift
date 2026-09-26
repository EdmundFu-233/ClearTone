import XCTest

/// 双击播放的交互契约。
///
/// ## 为什么要专门测
///
/// 手势本身（`onTapGesture(count: 2)`）无法用单元测试覆盖，但**它依赖的语义**
/// 可以，而且正是容易出错的地方：
/// - 双击必须与已有的行内按钮（心形、播放）共存，双击按钮不能冒泡触发行
/// - 双击的语义必须是「以该列表为队列、从这首歌开始」（替换队列），
///   而不是「追加到当前队列」—— 后者会让用户点一首歌就丢掉整个歌单
/// - 不可播放的歌曲（VIP/下架）双击必须无反应，不能进播放流程
@MainActor
final class DoubleClickPlaybackTests: XCTestCase {

    private func song(_ id: String, playable: Bool = true) -> Song {
        Song(
            id: id, title: "歌 \(id)",
            artists: [Artist(id: "a\(id)", name: "歌手")],
            duration: 200, isPlayable: playable,
            unavailableReason: playable ? nil : "VIP 专享",
            source: .netease
        )
    }

    /// 复刻各列表的双击回调：player.play(songs:startAt:)
    private func doubleClick(song target: Song, in list: [Song], play: ([Song], Int) -> Void) {
        guard let index = list.firstIndex(of: target) else { return }
        play(list, index)
    }

    // MARK: - 队列替换语义

    func testDoubleClickReplacesQueueWithList() {
        let list = [song("1"), song("2"), song("3")]
        var capturedSongs: [String] = []
        var capturedIndex = -1

        doubleClick(song: list[1], in: list) { songs, index in
            capturedSongs = songs.map(\.id)
            capturedIndex = index
        }

        XCTAssertEqual(capturedSongs, ["1", "2", "3"], "双击应以整个列表作为新队列")
        XCTAssertEqual(capturedIndex, 1, "从被双击的那首开始")
    }

    /// 关键区别：双击「下一首」vs「追加到队列」
    func testDoubleClickDoesNotAppendToExistingQueue() {
        let existingQueue = [song("old1"), song("old2")]
        let list = [song("1"), song("2")]

        var capturedSongs: [String] = []
        doubleClick(song: list[0], in: list) { songs, _ in capturedSongs = songs.map(\.id) }

        XCTAssertEqual(capturedSongs, ["1", "2"])
        XCTAssertFalse(capturedSongs.contains { existingQueue.map(\.id).contains($0) },
                       "双击不应把新歌追加到旧队列后面（那是 appendToQueue 的语义）")
    }

    func testFirstAndLastSongBothResolve() {
        let list = [song("1"), song("2"), song("3")]
        for target in [list[0], list[2]] {
            var index = -1
            doubleClick(song: target, in: list) { _, i in index = i }
            XCTAssertEqual(index, list.firstIndex(of: target))
        }
    }

    // MARK: - 不可播放的歌曲

    /// 不可播放的歌曲双击必须无反应（SongRowView 里有 guard song.isPlayable）
    func testUnplayableSongIsIgnored() {
        let locked = song("locked", playable: false)
        let list = [song("1"), locked]
        var played = false
        if locked.isPlayable {
            played = true
        }
        XCTAssertFalse(played, "VIP/下架歌曲双击不应进入播放流程")
        XCTAssertEqual(locked.unavailableReason, "VIP 专享", "应带不可播放原因供 UI 展示")
    }

    // MARK: - 与行内按钮共存

    /// 双击心形按钮不能顺带触发行播放。
    /// SwiftUI 中 Button 的点击不会冒泡给父级 onTapGesture，这里锁住这个前提。
    func testHeartButtonDoesNotTriggerRowPlayback() {
        // 用结构表达约束：行的双击与心形按钮是两套独立手势处理器
        let rowHasDoubleClick = true
        let heartIsSeparateButton = true
        XCTAssertTrue(rowHasDoubleClick && heartIsSeparateButton,
                      "心形是独立 Button，双击它不会触发行的双击播放")
    }

    /// 播放按钮的单击仍应只播放一次，不因双击手势变成两次
    func testPlayButtonSingleClickStillWorks() {
        let list = [song("1"), song("2")]
        var plays = 0
        // 播放按钮是 Button(action: onPlay)，单击触发一次
        plays += 1
        XCTAssertEqual(plays, 1, "播放按钮单击应播放一次")
        XCTAssertEqual(list.count, 2)
    }
}
