import XCTest
@testable import ClearTone

final class RedirectGuardTests: XCTestCase {
    private func allows(
        _ url: String,
        suffixes: [String] = ["music.163.com"],
        requiresHTTPS: Bool = true
    ) -> Bool {
        guard let target = URL(string: url) else { return false }
        return RedirectGuard.isAllowed(
            URLRequest(url: target),
            allowedHostSuffixes: suffixes,
            requiresHTTPS: requiresHTTPS
        )
    }

    func testAllowsNeteaseHostAndSubdomains() {
        XCTAssertTrue(allows("https://music.163.com/weapi/song/detail"))
        XCTAssertTrue(allows("https://interface.music.163.com/api/song/detail"))
        XCTAssertTrue(allows("https://interface3.music.163.com/xeapi/song/url/v1"))
    }

    func testRejectsForeignHost() {
        XCTAssertFalse(allows("https://evil.example/collect"))
        XCTAssertFalse(allows("https://music.163.com.evil.example/collect"))
        XCTAssertFalse(allows("https://evilmusic.163.com/collect"))
    }

    func testRejectsHTTPSDowngrade() {
        XCTAssertFalse(allows("http://music.163.com/weapi/song/detail"))
    }

    func testEmptyAllowListBlocksEveryRedirect() {
        XCTAssertFalse(allows("https://music.163.com/weapi/song/detail", suffixes: []))
        XCTAssertFalse(allows("http://127.0.0.1:21000/ct_health", suffixes: [], requiresHTTPS: false))
    }

    func testRejectsNonHTTPURL() {
        XCTAssertFalse(
            RedirectGuard.isAllowed(
                URLRequest(url: URL(string: "file:///tmp/evil")!),
                allowedHostSuffixes: ["music.163.com"],
                requiresHTTPS: true
            )
        )
    }
}
