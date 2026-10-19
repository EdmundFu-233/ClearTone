import Foundation

/// 歌单曲目内存缓存（`NeteaseProvider.playlistTrackCache`）的新鲜度判定。
///
/// 抽成独立的纯函数是为了可离线测试：原先缓存只有「600 秒内直接用、
/// 超过就整页重载」两档 —— 命中时**完全不校验**，用户看到的是最长
/// 10 分钟不更新的曲目列表（在别处加的歌曲迟迟不出现）。
///
/// 三档语义：
/// - `.fresh`：可信窗口内。直接用缓存，不发任何请求（来回切歌单不重拉）。
/// - `.stale`：还在保留期内，但不保证最新。先渲染缓存（瞬时可见），
///   同时后台重拉一遍并整体替换。
/// - `.miss`：超过保留期。视为没有缓存，走完整加载。
enum PlaylistTrackCachePolicy {
    /// 可信窗口：这段时间内的缓存不校验。
    static let trustInterval: TimeInterval = 60
    /// 保留期：超过后缓存不再用于渲染，避免长时间显示旧曲目。
    static let maximumAge: TimeInterval = 600

    enum Decision: Equatable {
        case fresh
        case stale
        case miss
    }

    /// - Note: 负年龄（系统时钟回拨）按 `.fresh` 处理：宁可少发请求，
    ///   也不能让缓存永远无法可信、每次进入都整页重载。
    static func decision(cachedAt: Date, now: Date = Date()) -> Decision {
        let age = now.timeIntervalSince(cachedAt)
        guard age.isFinite else { return .miss }
        if age < 0 { return .fresh }
        if age >= maximumAge { return .miss }
        return age < trustInterval ? .fresh : .stale
    }
}
