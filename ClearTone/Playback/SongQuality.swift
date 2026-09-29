import Foundation

/// 「单曲音质覆盖」——用户为某一首歌单独指定的音质。
///
/// 与全局 `Settings.preferredQuality` 的分工：
/// - 全局：默认音质，但**只在没有本地缓存时**才决定在线流的音质；
/// - 单曲覆盖：显式要求「这一首走网易源、用这个音质」，此时**跳过本地缓存**。
///
/// 为什么不把全局音质也当成「必须走网易源」：本地缓存是 128kbps OPUS，
/// 大致相当于「标准」那一档（受约束 VBR，实测平均码率随内容浮动）。
/// 用户明确说「默认吃缓存」，所以缓存优先；
/// 想要真音质（极高 / 无损 / Hi-Res）时就在单曲上点一次
/// （设置项 / 播放栏 / 正在播放页都有入口）。
public struct SongQualityOverride: Codable, Equatable, Sendable, Identifiable {
    public var songID: String
    public var level: AudioQuality.QualityLevel
    public var updatedAt: Date

    public var id: String { songID }

    public init(songID: String, level: AudioQuality.QualityLevel, updatedAt: Date = Date()) {
        self.songID = songID
        self.level = level
        self.updatedAt = updatedAt
    }
}

/// 音质决策规则。刻意做成纯函数：这里决定「听的是不是耳朵以为的那一档」，
/// 值得能脱离 AVPlayer / 网络单测。
public enum SongQualityPolicy {

    /// 网易音质选项（`.unknown` 是内部占位，不出现在菜单里）
    public static var selectableLevels: [AudioQuality.QualityLevel] {
        AudioQuality.QualityLevel.allCases.filter { $0 != .unknown }
    }

    /// 「跟随账号自动」这个**偏好值**本身。
    ///
    /// 复用 `.unknown`：它本来就是个不出现在菜单里的占位值，
    /// 而 AppSettings 需要一个「用户没指定」的第三态 ——
    /// 原来 `preferredQuality` 只有「指定某档」和「默认 极高」两种，
    /// 于是无法区分「用户主动选了极高」与「从没碰过这个设置」。
    /// 有了这个第三态，VIP 才能在不覆盖用户显式选择的前提下改变默认值。
    public static let autoLevel: AudioQuality.QualityLevel = .unknown

    /// 无显式偏好时的默认档位：**有 VIP 走无损，否则极高**。
    ///
    /// 无损（FLAC）要 VIP 或黑胶会员才拿得到；对非 VIP 账号默认要无损，
    /// 得到的只会是 403 / 空流，用户表现为「设置了却放不出声」。
    public static func defaultLevel(isVIP: Bool) -> AudioQuality.QualityLevel {
        isVIP ? .lossless : .exhigh
    }

    /// 把「用户偏好」解析成实际请求的全局档位。
    ///
    /// `.unknown`（自动）才看 VIP；用户显式选过的档位原样使用，
    /// **绝不因为 VIP 状态变化而改动**。
    public static func effectiveGlobalLevel(
        preference: AudioQuality.QualityLevel,
        isVIP: Bool
    ) -> AudioQuality.QualityLevel {
        preference == autoLevel ? defaultLevel(isVIP: isVIP) : preference
    }

    /// 实际请求的音质：单曲覆盖优先于全局
    public static func effectiveLevel(
        override: AudioQuality.QualityLevel?,
        global: AudioQuality.QualityLevel
    ) -> AudioQuality.QualityLevel {
        override ?? global
    }

    /// 能否直接吃本地缓存。
    ///
    /// 有单曲覆盖 = 用户明确点名要网易源的某个音质 → 不用缓存。
    /// 没有覆盖 = 默认行为，缓存优先（秒开、不吃流量）。
    public static func useLocalCache(hasOverride: Bool) -> Bool {
        !hasOverride
    }

    /// 这次拉流要不要顺手写缓存。
    ///
    /// 有覆盖时不写：缓存管线会把无损流转成 128kbps OPUS，对一首点名要无损的歌
    /// 是降级；而下次播放只要覆盖还在就仍然不走这份缓存，纯属占磁盘。
    public static func shouldWriteCache(hasOverride: Bool, isPreview: Bool) -> Bool {
        !hasOverride && !isPreview
    }

    /// 无损流的真实平均码率（kbps）。
    ///
    /// `/song/url/v1` 对 FLAC 常常把 `br` 报成 0 或干脆不给，只给 `size`（字节数）。
    /// 直接显示「无损」而不带码率，用户没法判断自己是不是真的在听无损，
    /// 所以用 `size × 8 / 时长` 反算一个平均值。
    /// 返回 nil 表示数据不足（不该编一个数字出来）。
    public static func derivedBitrateKbps(sizeBytes: Int?, duration: TimeInterval) -> Int? {
        guard let sizeBytes = sizeBytes, sizeBytes > 0, duration > 1 else { return nil }
        let kbps = Double(sizeBytes) * 8 / duration / 1000
        guard kbps.isFinite, kbps >= 1 else { return nil }
        return Int(kbps.rounded())
    }
}
