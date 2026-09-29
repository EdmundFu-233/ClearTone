import Foundation

/// 本地缓存对当前播放的影响
public enum CacheHint: Equatable, Sendable {
    /// 没有缓存信息
    case none
    /// 正在写入缓存（此刻播的仍是在线流）
    case caching
    /// 已有完整缓存
    case cached(format: String, bitrateKbps: Int)

    public var isPresent: Bool { self != .none }
}

/// 「现在到底在放什么」的可读描述。
///
/// 设计取舍：**主信息永远是此刻真正出声的「编码 + 码率」，缓存只作为次要信息。**
/// 反过来做（缓存状态顶掉码率）会有个具体的坑：后台缓存是「开始播放就写」，
/// 所以一首第一次听的歌，从点下播放到听完，界面上显示的一直是「缓存中 / OPUS 128k」，
/// 而它此刻播的其实是 320k 在线流 —— 用户看到的码率和耳朵听到的对不上。
/// 只有真的在播缓存文件时，缓存格式才是「实际音质」。
///
/// 为什么是「编码 + 码率」而不是音质名：只写「极高 320k」看不出容器格式，
/// 而 320k 可以是 MP3 也可以是 AAC，无损更是 FLAC —— 编码才是可核对的事实。
/// 音质名（标准/极高/无损）是网易云的营销档位，留在 tooltip 里。
public struct PlayingSourceInfo: Equatable, Sendable {
    /// 主文案，例如 "FLAC 1050k"（在线无损）/ "OPUS 128k"（缓存文件）/ "AAC 256k"
    public let text: String
    /// 紧凑文案（窄栏位用）：仍然带编码，只在实在放不下时才退到纯码率
    public let shortText: String
    /// 主文案描述的是否是本地缓存文件
    public let isFromCache: Bool
    /// 缓存状态（次要信息，决定是否显示 internaldrive / arrow.down 图标）
    public let cache: CacheHint
    /// 完整说明，供 tooltip / 旁注使用
    public let detail: String
}

public enum PlayingSourceFormatter {

    /// - Parameters:
    ///   - actualQuality: 实际拿到的音质（`PlayerController.actualQuality`）
    ///   - requestedLevel: 用户请求的音质（写进 tooltip）
    ///   - isFromCache: 当前是否在播本地缓存
    ///   - cacheFormat: 已完成缓存的格式名（无缓存为 nil）
    ///   - cacheBitrateKbps: 已完成缓存的实测码率
    ///   - isCaching: 是否正在写入缓存
    /// - Returns: 没有任何可展示信息时返回 nil（视图直接不渲染这个位置）
    public static func describe(
        actualQuality: AudioQuality?,
        requestedLevel: AudioQuality.QualityLevel,
        isFromCache: Bool,
        cacheFormat: String? = nil,
        cacheBitrateKbps: Int? = nil,
        isCaching: Bool = false
    ) -> PlayingSourceInfo? {
        let cache: CacheHint
        if let format = cacheFormat, let bitrate = cacheBitrateKbps, bitrate > 0 {
            cache = .cached(format: format, bitrateKbps: bitrate)
        } else if isCaching {
            cache = .caching
        } else {
            cache = .none
        }

        // 正在播缓存文件：缓存格式就是实际音质，主信息用它
        if isFromCache, case .cached(let format, let bitrate) = cache {
            return PlayingSourceInfo(
                text: "\(format) \(bitrate)k",
                shortText: "\(format) \(bitrate)k",
                isFromCache: true,
                cache: cache,
                detail: "正在播放本地缓存：\(format) \(bitrate)kbps\n本地缓存优先于在线流"
            )
        }

        // 在线流：主信息是「编码 + 码率」，拿不到就不显示
        guard let quality = actualQuality else { return nil }
        let level = quality.level
        let bitrate = quality.bitrate
        guard let text = primaryText(level: level, bitrate: bitrate, codec: quality.codec) else { return nil }

        let actualLine = bitrate.map { "\(level.rawValue) \($0)kbps" } ?? level.rawValue
        let codecLine = quality.codec.map { "\n编码：\($0)" } ?? ""
        let cacheLine: String
        switch cache {
        case .none: cacheLine = "本地缓存：无"
        case .caching: cacheLine = "本地缓存：正在写入（本次播放仍为在线流）"
        case .cached(let format, let bitrate): cacheLine = "本地缓存：\(format) \(bitrate)kbps（下次播放优先使用）"
        }
        return PlayingSourceInfo(
            text: text,
            // 窄栏位退到纯码率，但只在真的放不下时；编码信息优先保留在 text 里
            shortText: bitrate.map { "\($0)k" } ?? text,
            isFromCache: false,
            cache: cache,
            detail: "请求音质：\(requestedLevel.rawValue)\n实际返回：\(actualLine)\(codecLine)\(cacheLine)"
        )
    }

    /// 「编码 + 码率」优先，其次音质名 + 码率，最后只有音质名；
    /// 三者都没有（level == .unknown 又无码率无编码）则不展示
    private static func primaryText(
        level: AudioQuality.QualityLevel,
        bitrate: Int?,
        codec: String?
    ) -> String? {
        let cleanCodec = codec?.trimmingCharacters(in: .whitespaces).uppercased()
        let hasCodec = !(cleanCodec?.isEmpty ?? true)
        let rate = (bitrate.flatMap { $0 > 0 ? $0 : nil }).map { "\($0)k" }
        if hasCodec, let rate = rate { return "\(cleanCodec!) \(rate)" }
        if hasCodec { return cleanCodec }
        if let rate = rate { return level == .unknown ? rate : "\(level.rawValue) \(rate)" }
        guard level != .unknown else { return nil }
        return level.rawValue
    }
}
