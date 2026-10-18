import XCTest

/// 更新检查的纯逻辑：版本解析 / 比较 / GitHub 响应解析 / 下载地址校验。
///
/// 与 Windows 版 `windows/src/ClearTone/Core/Updates/WindowsRelease.cpp` 语义一致：
/// 只认稳定三段版本、拒绝 draft/prerelease、下载链接必须落在本仓库 releases 下。
/// 网络调用不在这里测（离线环境）。
final class ReleaseCheckerTests: XCTestCase {

    // MARK: - 版本解析

    func testAcceptsSemanticVersionsWithOptionalPrefix() {
        XCTAssertEqual(ReleaseChecker.versionParts("1.0.4"), [1, 0, 4])
        XCTAssertEqual(ReleaseChecker.versionParts("v1.0.4"), [1, 0, 4])
        XCTAssertEqual(ReleaseChecker.versionParts("V2.13.0"), [2, 13, 0])
    }

    func testRejectsNonStableForms() {
        for bad in ["1.0", "1.0.4.5", "v1.0.4-beta", "v1.0.4+build", "latest", "", "v", "1..4", "v1.0.x", "-1.0.0"] {
            XCTAssertNil(ReleaseChecker.versionParts(bad), "\(bad) 不该被当成稳定版本")
        }
    }

    // MARK: - 版本比较

    func testIsNewer() {
        XCTAssertTrue(ReleaseChecker.isNewer("v1.0.5", than: "1.0.4"))
        XCTAssertTrue(ReleaseChecker.isNewer("2.0.0", than: "v1.99.99"))
        XCTAssertTrue(ReleaseChecker.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(ReleaseChecker.isNewer("1.0.4", than: "1.0.4"))
        XCTAssertFalse(ReleaseChecker.isNewer("1.0.3", than: "1.0.4"))
        // 任一侧非法：宁可不提示更新
        XCTAssertFalse(ReleaseChecker.isNewer("1.0.5-beta", than: "1.0.4"))
        XCTAssertFalse(ReleaseChecker.isNewer("1.0.5", than: "0.1"))
    }

    // MARK: - 响应解析

    private func makeResponse(
        tag: String = "v1.2.0",
        draft: Bool = false,
        prerelease: Bool = false,
        htmlURL: String = "https://github.com/EdmundFu-233/ClearTone/releases/tag/v1.2.0",
        assets: [[String: String]] = []
    ) -> Data {
        let object: [String: Any] = [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "html_url": htmlURL,
            "assets": assets,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testParsesStableRelease() {
        let release = ReleaseChecker.parseLatestRelease(makeResponse())
        XCTAssertEqual(release?.version, "v1.2.0")
        XCTAssertEqual(release?.pageURL?.absoluteString, "https://github.com/EdmundFu-233/ClearTone/releases/tag/v1.2.0")
    }

    func testRejectsDraftAndPrereleaseAndBadTags() {
        XCTAssertNil(ReleaseChecker.parseLatestRelease(makeResponse(draft: true)))
        XCTAssertNil(ReleaseChecker.parseLatestRelease(makeResponse(prerelease: true)))
        XCTAssertNil(ReleaseChecker.parseLatestRelease(makeResponse(tag: "v1.2")))
        XCTAssertNil(ReleaseChecker.parseLatestRelease(Data("not json".utf8)))
    }

    func testKeepsOnlyTrustedDownloadAssets() {
        let assets: [[String: String]] = [
            ["name": "ClearTone-win-x64.zip",
             "browser_download_url": "https://github.com/EdmundFu-233/ClearTone/releases/download/v1.2.0/ClearTone-win-x64.zip"],
            // 外部域名：伪造响应不得把用户引去下载任意文件
            ["name": "evil.zip",
             "browser_download_url": "https://evil.example.com/ClearTone-win-x64.zip"],
            // 仓库不同
            ["name": "other.zip",
             "browser_download_url": "https://github.com/attacker/ClearTone/releases/download/v1.2.0/other.zip"],
            // 非 https
            ["name": "plain.zip",
             "browser_download_url": "http://github.com/EdmundFu-233/ClearTone/releases/download/v1.2.0/plain.zip"],
        ]
        let release = ReleaseChecker.parseLatestRelease(makeResponse(assets: assets))
        XCTAssertEqual(release?.assets.map(\.name), ["ClearTone-win-x64.zip"])
    }

    func testRejectsUntrustedReleasePageURL() {
        let release = ReleaseChecker.parseLatestRelease(
            makeResponse(htmlURL: "https://evil.example.com/releases/tag/v1.2.0")
        )
        XCTAssertEqual(release?.version, "v1.2.0", "版本仍可用，只是不给不可信页面链接")
        XCTAssertNil(release?.pageURL)
    }

    // MARK: - 平台安装包挑选

    func testPlatformAssetSelection() {
        let release = ReleaseChecker.Release(
            version: "v1.2.0",
            pageURL: nil,
            assets: [
                ReleaseChecker.Asset(name: "ClearTone-win-x64.zip", downloadURL: URL(string: "https://github.com/x")!),
                ReleaseChecker.Asset(name: "ClearTone-macos.zip", downloadURL: URL(string: "https://github.com/y")!),
                ReleaseChecker.Asset(name: "ClearTone-ios.ipa", downloadURL: URL(string: "https://github.com/z")!),
            ]
        )
        #if os(iOS)
        XCTAssertEqual(ReleaseChecker.platformAsset(in: release)?.name, "ClearTone-ios.ipa")
        #else
        XCTAssertEqual(ReleaseChecker.platformAsset(in: release)?.name, "ClearTone-macos.zip")
        #endif
    }

    func testPlatformAssetAbsentReturnsNil() {
        let release = ReleaseChecker.Release(
            version: "v1.2.0", pageURL: nil,
            assets: [ReleaseChecker.Asset(name: "ClearTone-win-x64.zip", downloadURL: URL(string: "https://github.com/x")!)]
        )
        #if os(iOS)
        XCTAssertNil(ReleaseChecker.platformAsset(in: release))
        #else
        XCTAssertNil(ReleaseChecker.platformAsset(in: release))
        #endif
    }
}
