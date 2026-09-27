import Foundation

/// 「单曲音质覆盖」——用户为某一首歌单独指定的音质。
///
/// 与全局 `Settings.preferredQuality` 的分工：
/// - 全局：默认音质，但**只在没有本地缓存时**才决定在线流的音质；
/// - 单曲覆盖：显式要求「这一首走网易源、用这个音质」，此时**跳过本地缓存**。
///
/// 为什么不把全局音质也当成「必须走网易源」：本地缓存是 96kbps OPUS，
/// 比标准（128k）还低。用户明确说「默认吃缓存」，所以缓存优先；
/// 想要真音质时就在单曲上点一次（设置项 / 播放栏 / 正在播放页都有入口）。
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
    /// 有覆盖时不写：缓存管线会把无损流转成 96kbps OPUS，对一首点名要无损的歌
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
