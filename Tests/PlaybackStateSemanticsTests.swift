import XCTest

/// 播放状态的「意图」语义与缓冲态。
///
/// P1-8 之前 `PlaybackState.buffering` 是纯死设计（声明后零赋值），
/// 网络抖动时界面无任何提示。引入后最大的风险是语义混淆：
/// 缓冲中既不是 playing 也不是 paused，按钮图标与 toggle 逻辑很容易搞错。
@MainActor
final class PlaybackStateSemanticsTests: XCTestCase {

    func testBufferingIsNotPlayingButIsPlayIntent() {
        let state = PlaybackState.buffering(songID: "1")
        XCTAssertFalse(state.isPlaying, "缓冲中此刻没有出声")
        XCTAssertTrue(state.isPlayIntentActive, "但用户意图是播放，按钮必须继续显示暂停图标")
        XCTAssertTrue(state.isBuffering)
    }

    /// 关键回归：若 buffering 不算 play intent，缓冲的瞬间播放按钮会跳成 ▶，
    /// 看着像被自动暂停了
    func testPlayButtonNeverFlickersDuringBuffering() {
        let before = PlaybackState.playing(songID: "1")
        let during = PlaybackState.buffering(songID: "1")
        XCTAssertTrue(before.isPlayIntentActive)
        XCTAssertTrue(during.isPlayIntentActive)
        XCTAssertEqual(before.isPlayIntentActive, during.isPlayIntentActive,
                       "从 playing 进入 buffering 时，播放按钮的图标语义不能变")
    }

    func testLoadingAlsoCountsAsPlayIntent() {
        // 点「播放全部」后到 readyToPlay 之间是 loading，此时按钮也该显示暂停
        XCTAssertTrue(PlaybackState.loading(songID: "1").isPlayIntentActive)
    }

    func testPausedAndIdleAreNotPlayIntent() {
        XCTAssertFalse(PlaybackState.paused(songID: "1").isPlayIntentActive)
        XCTAssertFalse(PlaybackState.idle.isPlayIntentActive)
        XCTAssertFalse(PlaybackState.ended(songID: "1").isPlayIntentActive)
        XCTAssertFalse(PlaybackState.failed(songID: "1", reason: "x").isPlayIntentActive)
    }

    func testOnlyBufferingIsMarkedBuffering() {
        XCTAssertTrue(PlaybackState.buffering(songID: "1").isBuffering)
        for state in [PlaybackState.playing(songID: "1"), .paused(songID: "1"), .loading(songID: "1"), .idle] {
            XCTAssertFalse(state.isBuffering, "\(state) 不应被标记为缓冲中")
        }
    }

    func testSongIDSurvivesBufferingTransition() {
        let id = "347230"
        XCTAssertEqual(PlaybackState.buffering(songID: id).songID, id,
                       "缓冲态必须保留 songID，否则切歌校验会失效")
    }
}
