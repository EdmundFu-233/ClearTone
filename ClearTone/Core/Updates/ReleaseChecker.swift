import Foundation

/// 版本更新检查：从 GitHub Releases 读取最新稳定版并与当前版本比较。
///
/// 与 Windows 版（windows/src/ClearTone/Core/Updates/WindowsRelease.cpp）同一套语义：
/// - 只接受 `v?x.y.z` 形式的稳定版本，draft / prerelease 一律忽略；
/// - 安装包链接必须是本仓库 releases 的 https 地址（防伪造响应指向任意下载）；
/// - 解析与版本比较是纯函数，可离线单测；网络调用单独一层。
enum ReleaseChecker {
    static let repository = "EdmundFu-233/ClearTone"
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    struct Release: Equatable {
        let version: String
        let pageURL: URL?
        let assets: [Asset]
    }

    struct Asset: Equatable {
        let name: String
        let downloadURL: URL
    }

    enum CheckError: LocalizedError {
        case http(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .http(let status):
                return status == 404 ? "还没有发布过安装包。" : "检查更新失败（HTTP \(status)），请稍后重试。"
            case .malformed:
                return "检查更新失败：无法解析发布信息。"
            }
        }
    }

    // MARK: - 纯逻辑（可离线测试）

    /// 解析 `v?x.y.z`。`v1.0.4-beta`、`1.0`、`v1.0.4.5` 都不接受。
    static func versionParts(_ version: String) -> [Int]? {
        var text = version
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        return numbers
    }

    /// `latest` 是否比 `installed` 新。任一侧不是合法稳定版本时返回 false（宁可不提示）。
    static func isNewer(_ latest: String, than installed: String) -> Bool {
        guard let new = versionParts(latest), let old = versionParts(installed) else { return false }
        return new != old && old.lexicographicallyPrecedes(new)
    }

    static func parseLatestRelease(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              versionParts(tag) != nil,
              (object["draft"] as? Bool) != true,
              (object["prerelease"] as? Bool) != true else { return nil }
        let pageURL = (object["html_url"] as? String).flatMap(acceptedPageURL)
        // 只保留指向本仓库 releases/download 的 https 资产
        let assets = (object["assets"] as? [[String: Any]] ?? []).compactMap { raw -> Asset? in
            guard let name = raw["name"] as? String,
                  let url = (raw["browser_download_url"] as? String).flatMap(acceptedDownloadURL) else { return nil }
            return Asset(name: name, downloadURL: url)
        }
        return Release(version: tag, pageURL: pageURL, assets: assets)
    }

    /// 当前平台对应的安装包。macOS 找名字含 mac 的 zip，iOS 找 ipa。
    /// 找不到时返回 nil —— 发布渠道尚未提供该平台产物时只提示新版本并给出发布页。
    static func platformAsset(in release: Release) -> Asset? {
        #if os(iOS)
        return release.assets.first { $0.name.lowercased().hasSuffix(".ipa") }
        #else
        return release.assets.first {
            let name = $0.name.lowercased()
            return name.hasSuffix(".zip") && name.contains("mac")
        }
        #endif
    }

    // MARK: - 网络

    static func latestRelease() async throws -> Release {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("ClearTone", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await checkSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.malformed }
        guard http.statusCode == 200 else { throw CheckError.http(http.statusCode) }
        guard let release = parseLatestRelease(data) else { throw CheckError.malformed }
        return release
    }

    private static let checkSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    // MARK: - URL 校验

    private static func isTrustedGithubURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host == "github.com"
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    private static func acceptedPageURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), isTrustedGithubURL(url),
              url.path.hasPrefix("/\(repository)/releases/") else { return nil }
        return url
    }

    private static func acceptedDownloadURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), isTrustedGithubURL(url),
              url.path.hasPrefix("/\(repository)/releases/download/") else { return nil }
        return url
    }
}
