import XCTest
@testable import ClearTone

/// Widget 快捷入口与主 App 之间只靠 URL scheme 通信（没有 App Group），
/// 所以这份解析必须是双端一致的硬约定：scheme、rawValue、host 拼错一个，
/// 桌面上的按钮就会变成「点了没反应」。这里把生成与解析都钉死。
final class ClearToneDeepLinkTests: XCTestCase {

    func testEveryCaseRoundTripsThroughItsOwnURL() {
        for link in ClearToneDeepLink.allCases {
            XCTAssertEqual(ClearToneDeepLink(url: link.url), link)
        }
    }

    func testURLsUseExpectedSchemeAndHosts() {
        XCTAssertEqual(ClearToneDeepLink.discover.url.absoluteString, "cleartone://discover")
        XCTAssertEqual(ClearToneDeepLink.search.url.absoluteString, "cleartone://search")
        XCTAssertEqual(ClearToneDeepLink.library.url.absoluteString, "cleartone://library")
        XCTAssertEqual(ClearToneDeepLink.nowPlaying.url.absoluteString, "cleartone://now-playing")
        XCTAssertEqual(ClearToneDeepLink.settings.url.absoluteString, "cleartone://settings")
    }

    func testParsesTripleSlashForm() {
        // 部分工具会把 `cleartone://search` 规整成 `cleartone:///search`。
        let url = URL(string: "cleartone:///library")!
        XCTAssertEqual(ClearToneDeepLink(url: url), .library)
    }

    func testRejectsForeignScheme() {
        XCTAssertNil(ClearToneDeepLink(url: URL(string: "https://search")!))
        XCTAssertNil(ClearToneDeepLink(url: URL(string: "clearTone2://search")!))
    }

    func testRejectsUnknownDestination() {
        XCTAssertNil(ClearToneDeepLink(url: URL(string: "cleartone://radio")!))
        XCTAssertNil(ClearToneDeepLink(url: URL(string: "cleartone://")!))
    }

    func testSchemeAndHostAreCaseInsensitive() {
        XCTAssertEqual(ClearToneDeepLink(url: URL(string: "ClearTone://Now-Playing")!), .nowPlaying)
    }

    func testNowPlayingUsesSingleCanonicalRawValue() {
        XCTAssertEqual(ClearToneDeepLink.nowPlaying.rawValue, "now-playing")
        XCTAssertEqual(ClearToneDeepLink(rawValue: "nowPlaying"), nil)
    }
}
