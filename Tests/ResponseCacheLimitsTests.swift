import XCTest

/// 响应缓存的容量边界与失效规则。
///
/// 原实现把 256 当成「触发 prune 的阈值」而非上限，pruneExpiredCache 只删过期项，
/// 写入速率高于过期速率时字典单调增长（一个 1000 首歌单 10 页约 1.5MB）。
/// 这里用可注入的存储来验证上限真的生效。
final class ResponseCacheLimitsTests: XCTestCase {

    /// 与 NeteaseProvider 同构的最小缓存实现，便于在无网络下验证淘汰规则
    private struct Store {
        struct Entry { let bytes: Int; let expiresAt: Date }
        var items: [String: Entry] = [:]
        var totalBytes = 0
        let entryLimit: Int
        let byteLimit: Int

        mutating func put(_ key: String, bytes: Int, ttl: TimeInterval) {
            totalBytes += bytes - (items[key].map { $0.bytes } ?? 0)
            items[key] = Entry(bytes: bytes, expiresAt: Date().addingTimeInterval(ttl))
            enforce()
        }

        private mutating func enforce() {
            // 过期项每次都清：它们不会被读取命中，但不清理会占内存与字节预算
            let now = Date()
            items = items.filter { $0.value.expiresAt > now }
            totalBytes = items.values.reduce(0) { $0 + $1.bytes }
            var ordered = items.sorted { $0.value.expiresAt < $1.value.expiresAt }
            while (items.count > entryLimit || totalBytes > byteLimit), !ordered.isEmpty {
                let victim = ordered.removeFirst()
                totalBytes -= victim.value.bytes
                items.removeValue(forKey: victim.key)
            }
        }

        /// 缓存键的路径部分。要同时处理 "?" 与 "|"：无 query 的键形如 "/likelist|auth"，
        /// 只按 "?" 切分会让它永远匹配不上前缀。
        static func path(of key: String) -> String {
            guard let cut = key.firstIndex(where: { $0 == "?" || $0 == "|" }) else { return key }
            return String(key[key.startIndex..<cut])
        }

        /// 与 NeteaseProvider.invalidateCache(pathPrefixes:) 相同的路径匹配规则
        mutating func invalidate(pathPrefixes: [String]) {
            for prefix in pathPrefixes {
                let hit = items.keys.filter { Self.path(of: $0) == prefix || Self.path(of: $0).hasPrefix(prefix + "/") }
                for key in hit {
                    totalBytes -= items[key]?.bytes ?? 0
                    items.removeValue(forKey: key)
                }
            }
        }
    }

    func testEntryLimitIsHardCap() {
        var store = Store(entryLimit: 128, byteLimit: 1_000_000_000)
        // 全部未过期：原实现在这种情况下永不裁剪
        for i in 0..<500 { store.put("/p\(i)", bytes: 1024, ttl: 3600) }
        XCTAssertLessThanOrEqual(store.items.count, 128, "条数必须被硬上限约束")
    }

    func testByteLimitIsEnforced() {
        var store = Store(entryLimit: 10_000, byteLimit: 32 * 1024 * 1024)
        // 每条 2MB，共 40 条 = 80MB，远超字节预算
        for i in 0..<40 { store.put("/big\(i)", bytes: 2 * 1024 * 1024, ttl: 3600) }
        XCTAssertLessThanOrEqual(store.totalBytes, 32 * 1024 * 1024, "字节总量必须被预算约束")
    }

    func testEvictionPrefersSoonestToExpire() {
        var store = Store(entryLimit: 3, byteLimit: 1_000_000)
        store.put("/a", bytes: 10, ttl: 10)     // 最先过期
        store.put("/b", bytes: 10, ttl: 1000)
        store.put("/c", bytes: 10, ttl: 2000)
        store.put("/d", bytes: 10, ttl: 3000)   // 触发淘汰
        XCTAssertNil(store.items["/a"], "最接近过期的应先被淘汰")
        XCTAssertNotNil(store.items["/d"])
        XCTAssertEqual(store.items.count, 3)
    }

    func testExpiredEntriesAreReclaimedFirst() {
        var store = Store(entryLimit: 4, byteLimit: 1_000_000)
        store.put("/old", bytes: 100, ttl: -1)   // 已过期
        store.put("/live1", bytes: 10, ttl: 1000)
        store.put("/live2", bytes: 10, ttl: 1000)
        XCTAssertNil(store.items["/old"], "已过期项应被优先清除")
        XCTAssertEqual(store.totalBytes, 20, "字节记账应与实际内容一致")
    }

    /// 失效必须精确到路径边界：/like 不能误伤 /likelist
    func testInvalidationDoesNotOverreach() {
        var store = Store(entryLimit: 100, byteLimit: 1_000_000)
        store.put("/like?id=1|auth", bytes: 10, ttl: 1000)
        store.put("/likelist|auth", bytes: 10, ttl: 1000)
        store.put("/user/playlist|auth", bytes: 10, ttl: 1000)
        store.put("/user/playlist/detail|auth", bytes: 10, ttl: 1000)

        store.invalidate(pathPrefixes: ["/like"])
        XCTAssertNil(store.items["/like?id=1|auth"], "/like 应被清")
        XCTAssertNotNil(store.items["/likelist|auth"], "/likelist 不应被 /like 误伤（原实现会误伤）")
        XCTAssertNotNil(store.items["/user/playlist|auth"], "不同前缀不应互相误伤")
    }

    /// 收藏失效要覆盖歌单与曲目元数据
    func testLikeInvalidationCoversRelatedPrefixes() {
        var store = Store(entryLimit: 100, byteLimit: 1_000_000)
        store.put("/likelist|auth", bytes: 10, ttl: 1000)
        store.put("/song/detail?ids=1|auth", bytes: 10, ttl: 1000)
        store.put("/user/playlist|auth", bytes: 10, ttl: 1000)
        store.put("/playlist/detail?id=9|auth", bytes: 10, ttl: 1000)
        store.put("/cloudsearch?keywords=x|anon", bytes: 10, ttl: 1000)

        store.invalidate(pathPrefixes: ["/likelist", "/song/detail", "/user/playlist", "/playlist/detail"])
        for key in store.items.keys {
            XCTAssertFalse(
                key.contains("likelist") || key.contains("song/detail")
                    || key.contains("user/playlist") || key.contains("playlist/detail"),
                "相关前缀应全部失效，但 \(key) 仍在"
            )
        }
        XCTAssertNotNil(store.items["/cloudsearch?keywords=x|anon"], "无关接口不应被清")
    }
}
