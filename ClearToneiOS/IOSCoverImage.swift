import SwiftUI
import UIKit
import ImageIO

struct IOSCover: View {
    let url: URL?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 10
    @State private var image: UIImage?
    @State private var loadedURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if let image, loadedURL == url { Image(uiImage: image).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary).overlay { Image(systemName: "music.note").foregroundStyle(.secondary) } }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        // 与 CoverLoader 用同一套尺寸量化：动态尺寸（正在播放页随几何变化）
        // 不会每个像素都触发一次重新加载
        .task(id: "\(url?.absoluteString ?? "")@\(Int(CoverLoader.quantizedPointSize(size).rounded()))") {
            let loaded = await CoverLoader.shared.load(url: url, pointSize: size)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                loadedURL = url
                image = loaded
            }
        }
    }
}

/// iOS 封面加载器 —— 与 macOS 的 `CoverLoader`（ClearTone/DesignSystem/CoverImage.swift）
/// 保持同一套策略：
/// - 在途请求去重：同一个 URL 被多个视图（迷你播放器在多个 tab 都有）同时请求时只下载一次
/// - 不可达 host 的镜像重试：p5~p8 不是有效镜像，池子只留 p1~p4 并按可达率排序
/// - 2.5s 请求超时（默认 20s 会让命中坏 host 的封面白等满超时）
/// - 显式 URLCache：冷启动直接命中磁盘，不重新下载
/// - 尺寸量化 + 按像素计费的内存缓存
@MainActor
final class CoverLoader {
    static let shared = CoverLoader()
    private let memory = NSCache<NSString, UIImage>()
    /// 在途请求：同一 URL 并发时复用同一个 Task
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    private init() {
        memory.countLimit = 200
        memory.totalCostLimit = 32 * 1024 * 1024
        let cache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            diskPath: "com.cleartone.ios.covercache"
        )
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        // 连接建立是封面慢的真正瓶颈：网易云图片分散在 p1~p4 / m1~m8 等
        // 多个 host，随机解析到不可达节点时默认要等满 20s。压到 2.5s +
        // 镜像重试，把最坏等待从 20s 降到几秒。
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 15
        config.httpMaximumConnectionsPerHost = 6
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    /// 已知可达的图片 host，按实测可达率降序（与 macOS 同一份实测数据）。
    /// p5/p6 直接 404、p7/p8 连不上，放进池子只是白费一次请求/一次超时。
    static let mirrorHosts = ["p1", "p4", "p2", "p3"]

    /// 把显示尺寸量化到 32pt 网格（下限 64，上限 600）。见 macOS 侧说明：
    /// 动态尺寸不量化会产生大量一次性 `?param` 变体，冲掉真正有用的缓存。
    static func quantizedPointSize(_ pointSize: CGFloat) -> CGFloat {
        let step: CGFloat = 32
        let clamped = min(max(pointSize, 64), 600)
        return min(600, (clamped / step).rounded(.up) * step)
    }

    /// 网易云图片服务支持 `?param=宽x高`；其他来源原样使用。
    /// `pixels` 为服务端裁剪尺寸（3x 屏密度）。
    static func sizedURL(_ url: URL, pixels: Int) -> URL {
        guard url.host?.hasSuffix("music.126.net") == true else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        // 各接口返回的协议不统一，明文 http 一律升级 https
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "param" }
        query.append(URLQueryItem(name: "param", value: "\(pixels)y\(pixels)"))
        components.queryItems = query
        return components.url ?? url
    }

    func load(url: URL?, pointSize: CGFloat) async -> UIImage? {
        guard let url else { return nil }
        let quantized = Self.quantizedPointSize(pointSize)
        let pixels = min(1800, max(96, Int(quantized * 3)))
        let sized = Self.sizedURL(url, pixels: pixels)
        let key = "\(sized.absoluteString)@\(pixels)"

        if let image = memory.object(forKey: key as NSString) { return image }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<UIImage?, Never> { [session] in
            await Self.fetchImage(session: session, from: sized, pixels: pixels)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            memory.setObject(result, forKey: key as NSString, cost: Self.cacheCost(of: result))
        }
        return result
    }

    /// 下载并解码；连接失败时换一个 host 重试（路径在 p1~p4 上通用）
    private static func fetchImage(session: URLSession, from url: URL, pixels: Int) async -> UIImage? {
        if let raw = await downloadOnce(session: session, from: url) {
            return await decode(raw, pixels: pixels)
        }
        guard let host = url.host, host.hasSuffix("music.126.net") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let currentHost = host.split(separator: ".").first.map(String.init)
        for candidateHost in mirrorHosts where candidateHost != currentHost {
            components?.host = "\(candidateHost).music.126.net"
            guard let candidate = components?.url else { continue }
            if let raw = await downloadOnce(session: session, from: candidate) {
                return await decode(raw, pixels: pixels)
            }
        }
        return nil
    }

    private static func downloadOnce(session: URLSession, from url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 15 * 1024 * 1024 else { return nil }
        return data
    }

    /// ImageIO 在后台下采样，避免列表滚动时在主线程解码原图
    private static func decode(_ data: Data, pixels: Int) async -> UIImage? {
        guard let thumbnail = await CoverImageDecoder.decode(data, maxPixelSize: pixels) else { return nil }
        return UIImage(cgImage: thumbnail)
    }

    /// NSCache 计费：真实像素 × 4 字节
    private static func cacheCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.width * cgImage.height * 4
    }
}
