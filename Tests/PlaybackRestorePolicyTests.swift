import XCTest

/// 启动恢复进度开关的语义：
/// - 开启：从保存的位置继续
/// - 关闭：从头播放（原先关闭后手动播放仍会续播，与设置说明矛盾）
final class PlaybackRestorePolicyTests: XCTestCase {

    func testRestoresSavedPositionWhenEnabled() {
        XCTAssertEqual(PlaybackRestorePolicy.restoredPosition(saved: 42.5, restorePosition: true), 42.5)
        XCTAssertEqual(PlaybackRestorePolicy.restoredPosition(saved: 0, restorePosition: true), 0)
    }

    func testStartsFromBeginningWhenDisabled() {
        XCTAssertEqual(PlaybackRestorePolicy.restoredPosition(saved: 42.5, restorePosition: false), 0)
        XCTAssertEqual(PlaybackRestorePolicy.restoredPosition(saved: 0, restorePosition: false), 0)
    }

    func testRejectsNonFiniteOrNegativeSavedValues() {
        XCTAssertEqual(PlaybackRestorePolicy.restoredPosition(saved: .nan, restorePosition: true), 0)
        XCTAssertEqual(PlaybackRestorePolicy.restoredPosition(saved: .infinity, restorePosition: true), 0)
        XCTAssertEqual(PlaybackRestorePolicy.restoredPosition(saved: -5, restorePosition: true), 0)
    }
}
