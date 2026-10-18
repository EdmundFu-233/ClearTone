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
    @State private var loadedURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let image, loadedURL == url {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: taskKey) {
            let loaded = await CoverLoader.shared.load(url: url, pointSize: size)
            // 切歌 / 改尺寸时 SwiftUI 会取消旧 task，但 `CoverLoader.load` 不认取消，
            // 旧请求可能在新请求**之后**才返回。写回前必须确认自己没被取消，
            // 否则上一首（慢 CDN）的封面会覆盖当前（命中缓存、快）的封面。
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                loadedURL = url
                image = loaded
            }
        }
    }

    /// 尺寸变化时需要重新取更合适的图，因此纳入 task id。
    /// 与 `CoverLoader` 使用同一套量化：微小尺寸变化不会触发重新请求。
    private var taskKey: String {
        "\(url?.absoluteString ?? "-")@\(Int(CoverLoader.quantizedPointSize(size).rounded()))"
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
        memory.countLimit = 200
        // 必须同时限体积：只限条数时 120 张 400pt 封面就是约 300MB 常驻；
        // 且 NSCache 在内存压力下会整体清空，一次清空等于全列表封面重下。
        // 32MB ≈ 10 张 400pt（系统媒体中心）或数百张列表小图 —— 足够覆盖
        // 当前页面 + 最近若干首，与 Windows 版的 24MB 目标同一量级。
        memory.totalCostLimit = 32 * 1024 * 1024
        // 原图动辄几百 KB，磁盘缓存给足，回滚/重进页面直接命中
        let cache = URLCache(
            memoryCapacity: 8 * 1024 * 1024,
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

    /// 已知可达的图片 host，按实测可达率降序，用于失败后切换。
    ///
    /// 路径部分在所有 host 上通用，但 host 本身差别很大。实测同一张封面 × 4 轮：
    ///     p1 → 4/4 可达      p2 → 2/4      p3 → 1/4      p4 → 3/4
    ///     p5 → 0/4，全 404   p6 → 0/4，全 404
    ///     p7 → 0/4，连接超时  p8 → 0/4，连接超时
    ///
    /// **p5~p8 不是有效镜像**：p5/p6 直接 404（纯浪费一次请求），
    /// p7/p8 TCP 都建不上（每轮白等满超时）。所以池子里只保留 p1~p4，
    /// 并按可达率排序，让最可靠的先试。
    private static let mirrorHosts = ["p1", "p4", "p2", "p3"]

    /// 把显示尺寸量化到 32pt 网格（下限 64，上限 1200）。
    ///
    /// 不量化的后果：正在播放页封面随窗口实时变化，每个像素级变化都会生成
    /// 一个不同的 `?param=WxH`，一次窗口拖拽可产生上百个 URL / 解码 / 缓存条目，
    /// 既浪费网络又把真正有用的缓存冲掉。量化后同一档位共享下载与缓存。
    static func quantizedPointSize(_ pointSize: CGFloat) -> CGFloat {
        let step: CGFloat = 32
        let clamped = pointSize.clamped(to: 64...1200)
        return min(1200, (clamped / step).rounded(.up) * step)
    }

    func load(url: URL?, pointSize: CGFloat) async -> NSImage? {
        guard let url else { return nil }
        let quantized = Self.quantizedPointSize(pointSize)
        let sized = Self.sizedURL(url, pointSize: quantized)
        let key = CoverImageDecoder.cacheKey(url: sized, pixels: Int(quantized * 2))

        if let cached = memory.object(forKey: key as NSString) { return cached }

        if let existing = inFlight[key] { return await existing.value }

        let task = Task<NSImage?, Never> { [session] in
            await Self.fetchImage(session: session, from: sized, pointSize: quantized)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            memory.setObject(result, forKey: key as NSString, cost: Self.cacheCost(of: result))
        }
        return result
    }

    /// 头像：与封面共用同一条下载链路，但烘成**圆形裁剪**的位图。
    ///
    /// 原先有个独立的 `AvatarLoader`，与本 loader 逻辑重复，且缺了三样东西：
    /// 在途去重（消息列表滚动会把同一头像请求十几次）、磁盘缓存、
    /// 以及不可达 host 的换镜像重试。合并后头像和封面走完全一样的策略。
    ///
    /// 圆角必须在**图片层**裁：菜单标签会绕过 SwiftUI 的 `.clipShape(Circle())`，
    /// 只靠视图裁剪会露出方角。
    func avatar(url: URL?, pointSize: CGFloat) async -> NSImage? {
        guard let url else { return nil }
        let quantized = Self.quantizedPointSize(pointSize)
        let sized = Self.sizedURL(url, pointSize: quantized)
        let key = "avatar:" + CoverImageDecoder.cacheKey(url: sized, pixels: Int(quantized * 2))

        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let task = Task<NSImage?, Never> { [session] in
            guard let raw = await Self.fetchImage(
                session: session, from: sized, pointSize: Self.quantizedPointSize(pointSize)
            ) else { return nil }
            return Self.bakeCircular(raw, pointSize: quantized)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            memory.setObject(result, forKey: key as NSString, cost: Self.cacheCost(of: result))
        }
        return result
    }

    /// 居中裁成正方形并烘成圆形位图。
    ///
    /// 和 `downsample` 一样**立即栅格化**：返回带 drawingHandler 的惰性 NSImage
    /// 会在任意绘制线程上执行闭包，那里没有主线程保证。
    static func bakeCircular(_ image: NSImage, pointSize: CGFloat) -> NSImage {
        let side = max(1, pointSize * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(side), pixelsHigh: Int(side),
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return image }
        rep.size = NSSize(width: side, height: side)

        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        let src = image.size
        let crop = min(src.width, src.height)
        let srcRect = NSRect(
            x: (src.width - crop) / 2, y: (src.height - crop) / 2,
            width: crop, height: crop
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSBezierPath(ovalIn: rect).addClip()
        image.draw(in: rect, from: srcRect, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let baked = NSImage(size: NSSize(width: side, height: side))
        baked.addRepresentation(rep)
        return baked
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
            return await decode(raw, pointSize: pointSize)
        }
        // 主 host 不可达：换镜像 host 重试
        return await retryWithMirrorHosts(session: session, from: url, pointSize: pointSize)
    }

    /// 单次下载；只发一个请求（data(from:) 同时返回 body 与 response）
    private static func downloadOnce(session: URLSession, from url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              data.count < 15 * 1024 * 1024 else { return nil }
        return data
    }

    private static func retryWithMirrorHosts(
        session: URLSession,
        from url: URL,
        pointSize: CGFloat
    ) async -> NSImage? {
        guard let host = url.host, host.hasSuffix("music.126.net") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let currentHost = host.split(separator: ".").first.map(String.init)

        // 按 mirrorHosts 已排好的可达率顺序试，跳过刚失败的当前 host。
        //
        // 之前这里是「从当前 host 之后顺序走」：从 p4 失败会依次试
        // p5(404) → p6(404) → p7(超时)，全是不该试的 host，
        // 反而永远够不到 4/4 可达的 p1。改成整体排序 + 跳过当前，
        // 无论原始 host 是哪个，下一次尝试都落在最可靠的候选上。
        for candidateHost in mirrorHosts where candidateHost != currentHost {
            components?.host = "\(candidateHost).music.126.net"
            guard let candidate = components?.url else { continue }
            if let raw = await downloadOnce(session: session, from: candidate) {
                return await decode(raw, pointSize: pointSize)
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

        // 明文 http 升级为 https。
        //
        // 本项目**没有配置任何 ATS 例外**（Info.plist 里零个 ATS 键），
        // 也就是走默认 ATS —— 默认禁止明文 HTTP。
        // 而网易云各接口返回的协议并不统一，实测：
        //     /recommend/songs  → http://p3|p4.music.126.net   ← 明文
        //     /song/detail      → https://p3.music.126.net      ← 加密
        // 于是「每日推荐」的封面全部被 ATS **静默拦截**（无报错、无日志、
        // 只是永远转圈），其他页面正常 —— 表现为只有每日推荐没封面。
        // 这里在唯一的 URL 准备漏斗里统一升级，比开 ATS 例外更安全。
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }

        var items = components.queryItems ?? []
        items.removeAll { $0.name == "param" }
        items.append(URLQueryItem(name: "param", value: "\(pixels)y\(pixels)"))
        components.queryItems = items
        return components.url ?? url
    }

    /// 位图的真实像素尺寸。
    ///
    /// **不能用 `NSImage.size`**：那是 point 尺寸，受 DPI 元数据影响 ——
    /// 300dpi 的 3000×3000 图会报告成 720pt，于是下采样判断（按 point 比较）
    /// 认为"已经够小"而跳过，NSCache 计费也按 point 算成约 2MB（真实约 36MB），
    /// 64MB 的体积上限形同虚设。取最大 representation 的像素数才是真实占用。
    private static func pixelSize(of image: NSImage) -> CGSize {
        let best = image.representations.max { lhs, rhs in
            lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
        }
        if let best, best.pixelsWide > 0, best.pixelsHigh > 0 {
            return CGSize(width: best.pixelsWide, height: best.pixelsHigh)
        }
        return image.size
    }

    /// NSCache 计费：真实像素 × 4 字节（BGRA）
    private static func cacheCost(of image: NSImage) -> Int {
        let pixels = pixelSize(of: image)
        return Int(pixels.width * pixels.height) * 4
    }

    static func decode(_ data: Data, pointSize: CGFloat) async -> NSImage? {
        guard let thumbnail = await CoverImageDecoder.decode(
            data, maxPixelSize: Int(quantizedPointSize(pointSize) * 2)
        ) else { return nil }
        let rep = NSBitmapImageRep(cgImage: thumbnail)
        let image = NSImage(size: NSSize(width: thumbnail.width, height: thumbnail.height))
        image.addRepresentation(rep)
        return image
    }

}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
