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
/// 封面下载 + 下采样 + 多级缓存
extension CoverImage where Placeholder == AnyView {
    /// 常见占位样式：圆角底色 + 图标。
    /// 仅用于非列表场景（卡片、详情页头）；列表行请用泛型 + 具体视图，
    /// 避免每行多一层类型擦除。
    init(
        url: URL?,
        size: CGFloat,
        contentMode: ContentMode = .fill,
        cornerRadius: CGFloat = CTRadius.small,
        systemImage: String = "music.note",
        tint: Color = .secondary
    ) {
        self.init(url: url, size: size, contentMode: contentMode) {
            AnyView(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(
                        Image(systemName: systemImage)
                            .foregroundStyle(tint)
                    )
            )
        }
    }
}

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
        // 连接建立是封面慢的真正瓶颈（不是带宽）：网易云图片分散在
        // p1~p4 / m1~m8 等多个 host，DNS 随机解析到的节点有时完全不可达，
        // 实测同一张图在可达 host 上 0.66s、在不可达 host 上要等满 20s。
        // 超时压到 2.5s 并配合换 host 重试，把最坏等待从 20s 降到几秒。
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 15
        // 同一 host 的并发连接数：列表滚动会同时要十几张封面
        config.httpMaximumConnectionsPerHost = 6
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    /// 已知可达的图片 host。用于失败后切换，路径部分在所有 host 上通用。
    private static let mirrorHosts = ["p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8"]

    func load(url: URL?, pointSize: CGFloat) async -> NSImage? {
        guard let url else { return nil }
        let sized = Self.sizedURL(url, pointSize: pointSize)
        let key = sized.absoluteString

        if let cached = memory.object(forKey: key as NSString) { return cached }

        if let existing = inFlight[key] { return await existing.value }

        let task = Task<NSImage?, Never> { [session] in
            await Self.fetchImage(session: session, from: sized, pointSize: pointSize)
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

    /// 下载并解码图片；连接失败时换一个 host 重试。
    ///
    /// 实测同一张封面的路径部分在 p1~p8 上通用，但某些 host 在当前网络下
    /// 完全无法建立 TCP 连接（time_connect = 0，直接超时）。随机命中就表现为
    /// 「封面一直不出来」。所以这里把 host 当作可替换的镜像逐个尝试。
    private static func fetchImage(
        session: URLSession,
        from url: URL,
        pointSize: CGFloat
    ) async -> NSImage? {
        if let raw = await downloadOnce(session: session, from: url) {
            return downsample(raw, to: pointSize)
        }
        // 主 host 不可达：换镜像 host 重试
        return await retryWithMirrorHosts(session: session, from: url, pointSize: pointSize)
    }

    /// 单次下载；只发一个请求（data(from:) 同时返回 body 与 response）
    private static func downloadOnce(session: URLSession, from url: URL) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return NSImage(data: data)
    }

    private static func retryWithMirrorHosts(
        session: URLSession,
        from url: URL,
        pointSize: CGFloat
    ) async -> NSImage? {
        guard let host = url.host, host.hasSuffix("music.126.net") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let currentHost = host.split(separator: ".").first.map(String.init) else { return nil }
        // 从当前 host 之后开始试，最多 3 个，避免无谓请求
        let start = (mirrorHosts.firstIndex(of: currentHost) ?? 0) + 1
        guard start < mirrorHosts.count else { return nil }

        for offset in 0..<min(3, mirrorHosts.count - start) {
            components?.host = "\(mirrorHosts[(start + offset) % mirrorHosts.count]).music.126.net"
            guard let candidate = components?.url else { continue }
            if let raw = await downloadOnce(session: session, from: candidate) {
                return downsample(raw, to: pointSize)
            }
        }
        return nil
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
