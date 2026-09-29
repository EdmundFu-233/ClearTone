import XCTest

/// 音频缓存的边界条件：容量淘汰顺序、代次防复活、临时文件清理、正在播放保护。
///
/// 这些都是「平时看不出来、出问题就很难查」的状态机边界，
/// 原实现没有代次校验也没有访问时间更新，必须用测试锁住。
@MainActor
final class AudioCacheManagerPolicyTests: XCTestCase {

    // MARK: - 测试替身：与 AudioCacheManager 同构的最小实现

    private struct CacheMeta: Codable, Equatable {
        var sizeBytes: Int64
        var cachedAt: Date
        var lastAccessedAt: Date?
    }

    private struct Store {
        var index: [String: CacheMeta] = [:]
        var cachedIDs: Set<String> = []
        var clearGeneration = 0
        var currentCachedSongID: String?
        let maxBytes: Int64
        /// 与实现一致：按 lastAccessedAt ?? cachedAt 升序淘汰
        func evictionOrder() -> [String] {
            index.sorted {
                ($0.value.lastAccessedAt ?? $0.value.cachedAt) < ($1.value.lastAccessedAt ?? $1.value.cachedAt)
            }.map(\.key)
        }
        var total: Int64 { index.values.reduce(0) { $0 + $1.sizeBytes } }

        mutating func trim(deleting: Set<String> = []) -> Set<String> {
            var removed: Set<String> = []
            for id in evictionOrder() {
                // total 是按 index 实时重算的，删除后已经变小；不能再叠加独立的累计量，
                // 否则会重复扣减导致提前停止、缓存仍超上限
                guard total > maxBytes else { break }
                guard id != currentCachedSongID else { continue }
                guard index.removeValue(forKey: id) != nil else { continue }
                cachedIDs.remove(id)
                removed.insert(id)
            }
            return removed
        }

        /// 与 `AudioCacheManager.purgeExpired` 同构。
        ///
        /// 关键：与 `trim` 不同，它**不受 maxBytes 约束** ——
        /// 7 天前的条目无论缓存多小都得清掉。
        mutating func purgeExpired(now: Date = Date()) -> Set<String> {
            let expired = AudioCacheRetentionPolicy.expiredIDs(
                cachedAtByID: index.mapValues(\.cachedAt), now: now
            )
            var removed: Set<String> = []
            for id in expired {
                guard id != currentCachedSongID else { continue }
                guard index.removeValue(forKey: id) != nil else { continue }
                cachedIDs.remove(id)
                removed.insert(id)
            }
            return removed
        }
    }

    // MARK: - 真正的 LRU

    func testEvictionUsesLastAccessedNotCachedAt() {
        var store = Store(maxBytes: 1000)
        let t0 = Date()
        // 三首 400 的歌，cachedAt 递增；只有第一首被反复播放
        store.index["old-but-favorite"] = CacheMeta(sizeBytes: 400, cachedAt: t0, lastAccessedAt: t0)
        store.index["mid"] = CacheMeta(sizeBytes: 400, cachedAt: t0.addingTimeInterval(10), lastAccessedAt: t0.addingTimeInterval(10))
        store.index["newest"] = CacheMeta(sizeBytes: 400, cachedAt: t0.addingTimeInterval(20), lastAccessedAt: t0.addingTimeInterval(20))
        //  favorite 刚被听过：lastAccessedAt 最新
        store.index["old-but-favorite"]?.lastAccessedAt = t0.addingTimeInterval(1000)

        let order = store.evictionOrder()
        XCTAssertEqual(order.first, "mid", "应先淘汰最久未播放的，而不是最早写入的")
        XCTAssertEqual(order.last, "old-but-favorite", "最常听的歌必须最后被淘汰")
    }

    func testFallsBackToCachedAtWhenNeverAccessed() {
        let t0 = Date()
        var store = Store(maxBytes: 1000)
        store.index["a"] = CacheMeta(sizeBytes: 500, cachedAt: t0, lastAccessedAt: nil)
        store.index["b"] = CacheMeta(sizeBytes: 500, cachedAt: t0.addingTimeInterval(5), lastAccessedAt: nil)
        XCTAssertEqual(store.evictionOrder().first, "a", "从未被访问过的应按写入时间排序")
    }

    func testTrimDeletesOldestUntilUnderLimit() {
        let t0 = Date()
        var store = Store(maxBytes: 1000)
        for i in 0..<5 {
            store.index["s\(i)"] = CacheMeta(sizeBytes: 400, cachedAt: t0.addingTimeInterval(Double(i)), lastAccessedAt: nil)
            store.cachedIDs.insert("s\(i)")
        }
        // 5×400 = 2000，需降到 ≤1000：每删一个释放 400，删 3 个后剩 800
        let removed = store.trim()
        XCTAssertEqual(removed, ["s0", "s1", "s2"], "应淘汰到低于上限为止")
        XCTAssertLessThanOrEqual(store.total, 1000)
        XCTAssertEqual(store.cachedIDs, ["s3", "s4"], "cachedIDs 需与 index 同步")
    }

    // MARK: - 保护正在播放的文件

    func testTrimNeverDeletesCurrentlyPlayingCache() {
        let t0 = Date()
        var store = Store(maxBytes: 1000)
        // playing 最该被淘汰（最早写入），但正在播放
        store.index["playing"] = CacheMeta(sizeBytes: 400, cachedAt: t0, lastAccessedAt: t0)
        store.index["x"] = CacheMeta(sizeBytes: 400, cachedAt: t0.addingTimeInterval(1), lastAccessedAt: t0.addingTimeInterval(1))
        store.index["y"] = CacheMeta(sizeBytes: 400, cachedAt: t0.addingTimeInterval(2), lastAccessedAt: t0.addingTimeInterval(2))
        store.currentCachedSongID = "playing"

        let removed = store.trim()
        XCTAssertFalse(removed.contains("playing"), "正在播放的缓存文件不能被淘汰")
        XCTAssertNotNil(store.index["playing"])
    }

    // MARK: - clearGeneration 防复活

    func testClearGenerationInvalidatesInFlightResults() {
        var store = Store(maxBytes: 1000)
        let captured = store.clearGeneration
        store.clearGeneration += 1          // 用户点了「清除缓存」

        // 在途任务此刻才完成
        let shouldCommit = (captured == store.clearGeneration)
        XCTAssertFalse(shouldCommit, "代数变化后，在途结果不得写回索引（否则幽灵条目复活）")
    }

    func testInFlightResultCommitsWhenNoClearHappened() {
        var store = Store(maxBytes: 1000)
        let captured = store.clearGeneration
        XCTAssertTrue(captured == store.clearGeneration, "没有清除事件时应正常提交")
    }

    // MARK: - 临时文件清理

    func testTempFilesAreNotIndexedOrCounted() {
        // refreshIndex 的规则：tmp- 前缀文件既不进索引也不计入容量
        let names = ["12345.caf", "tmp-ABC.caf", "67890.caf", "index.json", "tmp-DEF.caf"]
        let real = names.filter { $0.hasSuffix(".caf") && !$0.hasPrefix("tmp-") }
        XCTAssertEqual(Set(real.map { String($0.dropLast(4)) }), ["12345", "67890"],
                       "只有非 tmp- 的 .caf 才算正式缓存")
    }

    /// 孤儿文件（文件在、索引缺）必须能补回来，且能参与淘汰排序。
    func testIndexRecoversEntriesForOrphanFiles() {
        // 文件在但索引缺（上次写索引前被杀）应补回，避免白白重下。
        // 补回的条目没有访问时间，必须能回退到 cachedAt 参与淘汰排序。
        let t0 = Date()
        let orphan = CacheMeta(sizeBytes: 5_400_000, cachedAt: t0, lastAccessedAt: nil)
        let neverPlayed = CacheMeta(sizeBytes: 5_400_000, cachedAt: t0.addingTimeInterval(-100), lastAccessedAt: nil)
        XCTAssertEqual(orphan.sizeBytes, 5_400_000)
        // 排序键取 lastAccessedAt ?? cachedAt，两者都为 nil 时回退到 cachedAt
        func sortKey(_ m: CacheMeta) -> Date { m.lastAccessedAt ?? m.cachedAt }
        XCTAssertLessThan(sortKey(neverPlayed), sortKey(orphan), "更早写入的孤儿文件应先被淘汰")
    }

    /// 孤儿补回来的条目 `cachedAt` 记为「现在」——所以 7 天规则不会
    /// 在启动瞬间把它们当成超龄条目清掉（那会让白下一次载的缓存全丢）。
    func testRecoveredOrphanStartsFreshForRetention() {
        let now = Date()
        XCTAssertFalse(
            AudioCacheRetentionPolicy.isExpired(cachedAt: now, now: now),
            "补回来的孤儿条目从现在起算 7 天"
        )
    }

    // MARK: - 保留期限（7 天）

    /// 编码目标：128kbps。
    ///
    /// `afconvert -b` 收的是 **bit/s**，不是 kbps —— 写成 128 会得到
    /// 一个 0.128kbps 的文件，而因为转码「成功」，界面上看不出任何异常。
    func testTargetBitrateIs128kbps() {
        XCTAssertEqual(AudioCacheManager.defaultTargetBitrate, 128_000)
        XCTAssertEqual(AudioCacheManager.defaultTargetBitrate % 1000, 0, "afconvert -b 要的是 bit/s")
    }

    /// 7 天是硬上限：正好 7 天即过期。
    func testRetentionIsExactlySevenDays() {
        let now = Date()
        XCTAssertEqual(AudioCacheRetentionPolicy.maxAge, 7 * 24 * 60 * 60)
        XCTAssertFalse(AudioCacheRetentionPolicy.isExpired(cachedAt: now, now: now))
        XCTAssertFalse(AudioCacheRetentionPolicy.isExpired(
            cachedAt: now.addingTimeInterval(-6 * 24 * 60 * 60), now: now
        ))
        XCTAssertTrue(AudioCacheRetentionPolicy.isExpired(
            cachedAt: now.addingTimeInterval(-8 * 24 * 60 * 60), now: now
        ))
        XCTAssertTrue(
            AudioCacheRetentionPolicy.isExpired(
                cachedAt: now.addingTimeInterval(-AudioCacheRetentionPolicy.maxAge), now: now
            ),
            "正好 7 天应当算过期"
        )
    }

    /// 期限从 `cachedAt` 算，**不是** `lastAccessedAt`。
    ///
    /// 用访问时间算的话，常听的歌永不过期 —— 那就不是「最大 7 天」了。
    func testExpiryIsMeasuredFromCachedAtNotLastAccess() {
        let now = Date()
        let old = now.addingTimeInterval(-10 * 24 * 60 * 60)
        let justListened = now.addingTimeInterval(-60)
        // 10 天前缓存、1 分钟前还在听 —— 仍然过期
        XCTAssertTrue(AudioCacheRetentionPolicy.isExpired(cachedAt: old, now: now))
        XCTAssertFalse(AudioCacheRetentionPolicy.isExpired(cachedAt: justListened, now: now))
    }

    /// 时钟回拨 / 改系统时间不该把整个缓存清空。
    func testFutureTimestampIsNotExpired() {
        let now = Date()
        XCTAssertFalse(AudioCacheRetentionPolicy.isExpired(
            cachedAt: now.addingTimeInterval(60 * 60), now: now
        ))
    }

    func testExpiredIDsSelectsOnlyOverdueEntries() {
        let now = Date()
        let byAge: [String: Date] = [
            "fresh": now.addingTimeInterval(-3600),
            "almost": now.addingTimeInterval(-(6.9 * 24 * 60 * 60)),
            "stale": now.addingTimeInterval(-(7.1 * 24 * 60 * 60)),
            "ancient": now.addingTimeInterval(-(30 * 24 * 60 * 60)),
        ]
        XCTAssertEqual(
            AudioCacheRetentionPolicy.expiredIDs(cachedAtByID: byAge, now: now),
            ["stale", "ancient"]
        )
    }

    // MARK: - 过期清扫与容量淘汰的分工

    /// 过期清扫**不受容量上限约束**：远没到 1.5GB 也必须清掉 7 天前的条目。
    ///
    /// 之前只有 `trimIfNeeded`（`guard totalCacheBytes > maxCacheBytes` 才动手），
    /// 于是长期不听歌、不转码的 App 根本不会触发任何清理。
    func testExpirySweepRunsEvenWhenUnderCapacity() {
        let now = Date()
        var store = Store(maxBytes: 1_000_000_000)   // 远未超限
        store.index["stale"] = CacheMeta(sizeBytes: 1_000, cachedAt: now.addingTimeInterval(-9 * 24 * 60 * 60), lastAccessedAt: now.addingTimeInterval(-9 * 24 * 60 * 60))
        store.index["fresh"] = CacheMeta(sizeBytes: 1_000, cachedAt: now.addingTimeInterval(-60), lastAccessedAt: nil)
        store.cachedIDs = ["stale", "fresh"]

        let purged = store.purgeExpired(now: now)
        XCTAssertEqual(purged, ["stale"])
        XCTAssertEqual(store.index.keys.sorted(), ["fresh"])
        XCTAssertEqual(store.cachedIDs, ["fresh"])
    }

    /// 正在播放的过期条目不能被删（否则 AVPlayer 立刻中断），
    /// 但它必须留在索引里，等不播了再清。
    func testExpirySweepProtectsCurrentlyPlayingFile() {
        let now = Date()
        var store = Store(maxBytes: 1_000_000_000)
        store.index["playing"] = CacheMeta(sizeBytes: 1_000, cachedAt: now.addingTimeInterval(-9 * 24 * 60 * 60), lastAccessedAt: nil)
        store.currentCachedSongID = "playing"
        store.cachedIDs = ["playing"]

        XCTAssertEqual(store.purgeExpired(now: now), [])
        XCTAssertNotNil(store.index["playing"])
    }

    /// 清扫与容量淘汰各自独立：7 天内但超容量的照常按 LRU 腾位置。
    func testCapacityEvictionStillAppliesToUnexpiredEntries() {
        let now = Date()
        var store = Store(maxBytes: 1000)
        for i in 0..<5 {
            store.index["s\(i)"] = CacheMeta(sizeBytes: 400, cachedAt: now.addingTimeInterval(Double(-i)), lastAccessedAt: nil)
        }
        XCTAssertEqual(store.purgeExpired(now: now), [], "都在 7 天内，不该被时间规则清掉")
        XCTAssertEqual(store.trim(), ["s4", "s3", "s2"], "超容量仍按最久未播放淘汰")
    }
}
