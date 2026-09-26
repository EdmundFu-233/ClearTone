import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 跨平台封面加载。
///
/// 与 macOS 版 `CoverImage.swift`（`CoverLoader`）行为对齐，但用 `UIImage`。
/// iOS 侧单独一份而不是抽公共基类：两边的解码/缩放 API 不同
/// （`NSBitmapImageRep` vs `UIImage.preparingThumbnail`），
/// 强行抽象反而要在每个调用点塞平台分支。
///
/// ## 复刻自 macOS 版的三个已验证结论
///
/// 1. **明文 http 必须升级为 https**。网易云各接口返回的协议不统一：
///    `/recommend/songs` 返回 `http://`，`/song/detail` 返回 `https://`。
///    iOS 的 ATS 同样默认禁止明文 HTTP，所以每日推荐封面会**静默不显示**。
/// 2. **host 故障转移**。实测同一张封面在 p1~p8 上可达性随机：
///    p1 4/4、p4 3/4 可达，p5/p6 全部 404，p7/p8 连不上。
///    池子只留 p1~p4 并按可达率降序，重试时跳过当前 host。
/// 3. **必须立即栅格化，不能用惰性 drawingHandler**。惰性 NSImage 的闭包会被
///    MediaPlayer 在后台队列触发 → 撞 `@MainActor` 隔离 → SIGTRAP 闪退。
///    `UIImage` 没有这个坑（`UIImage` 本身线程安全），但仍做一次缩放以控制内存。
@MainActor
final class CoverLoader {
    static let shared = CoverLoader()

    /// 按实测可达率降序的镜像 host。p5/p6 是 404、p7/p8 连不上，不进池子。
    private static let mirrorHosts = ["p1", "p4", "p2", "p3"]

    private let memory = NSCache<NSString, PlatformImage>()
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        memory.totalCostLimit = 64 * 1024 * 1024

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 15
        config.httpMaximumConnectionsPerHost = 6
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
    }

    func load(url: URL?, pointSize: CGFloat) async -> PlatformImage? {
        guard let url else { return nil }
        let sized = Self.sizedURL(url, pointSize: pointSize)
        let key = sized.absoluteString as NSString

        if let cached = memory.object(forKey: key) { return cached }
        if let existing = inFlight[key as String] { return await existing.value }

        let task = Task<PlatformImage?, Never> { [session] in
            await Self.fetchImage(session: session, from: sized, pointSize: pointSize)
        }
        inFlight[key as String] = task
        let result = await task.value
        inFlight[key as String] = nil

        if let result {
            let cost = Int(result.size.width * result.size.height * 4)
            memory.setObject(result, forKey: key, cost: cost)
        }
        return result
    }

    // MARK: - 下载

    private static func fetchImage(
        session: URLSession, from url: URL, pointSize: CGFloat
    ) async -> PlatformImage? {
        if let raw = await downloadOnce(session: session, from: url) {
            return downsample(raw, to: pointSize)
        }
        return await retryWithMirrorHosts(session: session, from: url, pointSize: pointSize)
    }

    private static func downloadOnce(session: URLSession, from url: URL) async -> PlatformImage? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let image = PlatformImage(data: data)
        else { return nil }
        return image
    }

    private static func retryWithMirrorHosts(
        session: URLSession, from url: URL, pointSize: CGFloat
    ) async -> PlatformImage? {
        guard let host = url.host, host.hasSuffix("music.126.net") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let currentHost = host.split(separator: ".").first.map(String.init)

        // 按可达率降序试，跳过刚失败的 host。
        // 不要「从当前 host 之后顺序走」—— 那样从 p4 出发会依次试
        // p5(404) → p6(404) → p7(超时)，永远够不到 4/4 可达的 p1。
        for candidate in mirrorHosts where candidate != currentHost {
            components?.host = "\(candidate).music.126.net"
            guard let url = components?.url else { continue }
            if let raw = await downloadOnce(session: session, from: url) {
                return downsample(raw, to: pointSize)
            }
        }
        return nil
    }

    // MARK: - 缩放

    private static func downsample(_ image: PlatformImage, to pointSize: CGFloat) -> PlatformImage {
        let side = max(1, pointSize * 2)
        guard image.size.width > side || image.size.height > side else { return image }
        let target = CGSize(width: side, height: side)
        #if os(iOS)
        return image.preparingThumbnail(of: target) ?? image
        #else
        return image
        #endif
    }

    // MARK: - URL 准备

    /// 追加 `?param=` 裁剪参数并把 http 升级为 https
    static func sizedURL(_ url: URL, pointSize: CGFloat) -> URL {
        guard url.host?.hasSuffix("music.126.net") == true else { return url }
        let pixels = Int((pointSize * 2).rounded()).clamped(to: 64...1200)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }

        // 升级协议：默认 ATS 禁止明文 HTTP，而网易云部分接口返回 http://，
        // 表现为「封面永远转圈、不报错」。
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }

        var items = components.queryItems ?? []
        items.removeAll { $0.name == "param" }
        items.append(URLQueryItem(name: "param", value: "\(pixels)y\(pixels)"))
        components.queryItems = items
        return components.url ?? url
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
