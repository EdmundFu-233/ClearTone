import SwiftUI

/// 统一封面加载视图，替代 AsyncImage。
///
/// AsyncImage 的两个问题：
/// 1. 网易云 `picUrl` 不带尺寸参数时返回原图（实测 307KB / 1.66s），
///    而列表行只显示 40~56pt，拉原图纯属浪费；`?param=` 可把同一张图压到 3.7KB / 0.63s
/// 2. 没有跨视图缓存，列表来回滚动会反复重新下载
///
/// 这里按显示尺寸换算像素数（×2 屏密度）拼 `?param=WxH`，并叠加
/// 内存 NSCache + URLSession 磁盘缓存 + 在途请求去重。
struct CoverImage<Placeholder: View>: View {
    let url: URL?
    /// 显示尺寸（pt），用于决定请求多大的图
    var size: CGFloat
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: taskKey) {
            image = await CoverLoader.shared.load(url: url, pointSize: size)
        }
    }

    /// 尺寸变化时需要重新取更合适的图，因此纳入 task id
    private var taskKey: String {
        "\(url?.absoluteString ?? "-")@\(Int(size.rounded()))"
    }
}

/// 封面下载 + 下采样 + 多级缓存
@MainActor
final class CoverLoader {
    static let shared = CoverLoader()

    private let memory = NSCache<NSString, NSImage>()
    /// 在途请求：同一 URL 并发时复用同一个 Task，避免列表复用时重复下载
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private let session: URLSession

    private init() {
        memory.countLimit = 120
        // 必须同时限体积：360×360 BGRA 约 0.5MB/张，只限条数时
        // 120 张就是约 60MB 常驻；且 NSCache 在内存压力下会整体清空，
        // 一次清空等于全列表封面重下。
        memory.totalCostLimit = 64 * 1024 * 1024
        // 原图动辄几百 KB，磁盘缓存给足，回滚/重进页面直接命中
        let cache = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: "com.cleartone.covercache"
        )
        let config = URLSessionConfiguration.default
        config.urlCache = cache
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    func load(url: URL?, pointSize: CGFloat) async -> NSImage? {
        guard let url else { return nil }
        let sized = Self.sizedURL(url, pointSize: pointSize)
        let key = sized.absoluteString

        if let cached = memory.object(forKey: key as NSString) { return cached }

        if let existing = inFlight[key] { return await existing.value }

        let task = Task<NSImage?, Never> { [session] in
            guard let (data, _) = try? await session.data(from: sized),
                  let raw = NSImage(data: data) else { return nil }
            return Self.downsample(raw, to: pointSize)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            // 按实际像素数记账，供 totalCostLimit 淘汰
            let cost = Int(result.size.width * result.size.height) * 4
            memory.setObject(result, forKey: key as NSString, cost: cost)
        }
        return result
    }

    /// 网易云图片服务支持 `?param=宽x高` 服务端裁剪；其他来源（本地文件等）原样使用
    static func sizedURL(_ url: URL, pointSize: CGFloat) -> URL {
        guard url.host?.hasSuffix("music.126.net") == true else { return url }
        // 列表行 40~56pt、播放栏 56pt 用 2x 屏密度已足够，避免过度下载
        let pixels = Int((pointSize * 2).rounded()).clamped(to: 64...1200)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "param" }
        items.append(URLQueryItem(name: "param", value: "\(pixels)y\(pixels)"))
        components.queryItems = items
        return components.url ?? url
    }

    /// 在主线程把原图重绘到目标像素尺寸，顺带完成圆角外的裁剪基准
    private static func downsample(_ image: NSImage, to pointSize: CGFloat) -> NSImage {
        let side = max(1, pointSize * 2)
        guard image.size.width > side || image.size.height > side else { return image }
        let target = NSSize(width: side, height: side)
        let output = NSImage(size: target, flipped: false) { rect in
            image.draw(in: rect, from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1)
            return true
        }
        return output
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
