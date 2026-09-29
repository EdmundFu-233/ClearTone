import Foundation

/// 音频缓存的**保留期限**规则。
///
/// ## 为什么单独一个文件
///
/// `AudioCacheManager` 是个 `@MainActor` 单例、私有 init、还直接读写
/// `~/Library/Caches` —— 单测里既构造不出来也不该碰真实缓存目录。
/// 所以判定规则必须落成一个纯函数（照 `SongQualityPolicy` 的先例），
/// 管理器只负责执行。
///
/// ## 期限从哪个时间点算
///
/// 从 **`cachedAt`（写入时间）**，不是 `lastAccessedAt`。
///
/// `lastAccessedAt` 仍然是 LRU 淘汰的排序键，但**不能**拿来算期限：
/// 那会让常听的歌永不过期，而需求是「每条记录最多活 7 天」——
/// 没有上限的 TTL 不是 TTL。这两个时间点各管一件事：
/// `cachedAt` 定生死，`lastAccessedAt` 决定 7 天之内谁先被腾位置。
public enum AudioCacheRetentionPolicy {

    /// 单条缓存记录的最长存活时间：7 天。
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// 该条记录是否已过期。
    ///
    /// 用 `>=` 而不是 `>`：正好 7 天即视为过期。
    /// `now` 默认取当前时间，但**必须可注入** —— 单元测试要能构造
    /// 「7 天前写入的条目」而不能靠真的等待。
    public static func isExpired(
        cachedAt: Date,
        now: Date = Date(),
        maxAge: TimeInterval = AudioCacheRetentionPolicy.maxAge
    ) -> Bool {
        // 未来时间戳（时钟回拨、用户改系统时间）不算过期，
        // 否则改一次系统时间就能把整个缓存清空。
        guard now.timeIntervalSince(cachedAt) >= 0 else { return false }
        return now.timeIntervalSince(cachedAt) >= maxAge
    }

    /// 筛出已过期的条目 id。
    public static func expiredIDs(
        cachedAtByID: [String: Date],
        now: Date = Date(),
        maxAge: TimeInterval = AudioCacheRetentionPolicy.maxAge
    ) -> Set<String> {
        Set(cachedAtByID.filter { isExpired(cachedAt: $0.value, now: now, maxAge: maxAge) }.keys)
    }
}
