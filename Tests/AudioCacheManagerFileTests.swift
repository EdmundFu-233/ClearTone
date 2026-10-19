import XCTest

/// `AudioCacheManager` 的索引 / 文件一致性（注入临时目录，跑真实实现）。
///
/// 这类问题只在「文件与索引不同步」时暴露，靠镜像实现测不出来：
/// - 文件被外部清理（系统回收缓存目录 / 用户手删）→ 索引项必须一起剔除，
///   否则容量统计虚高、设置页显示一个磁盘上不存在的占用；
/// - 删除失败（被占用 / 权限）→ 索引项必须保留，否则文件变成「孤儿」，
///   下次启动被重新收养（`cachedAt` 重置），过期条目又拿到新的 7 天租约；
/// - `clearAll` 后同一首歌立刻重新入队 → 旧任务的收尾不得抹掉新任务的
///   「缓存中」标记，否则同一首歌会被重复下载两遍。
@MainActor
final class AudioCacheManagerFileTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleartone-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // 恢复权限后才能删掉只读目录
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func meta(size: Int64, cachedAt: Date = Date()) -> AudioCacheManager.CacheMeta {
        AudioCacheManager.CacheMeta(
            formatName: "OPUS", bitrateKbps: 128,
            sizeBytes: size, cachedAt: cachedAt, lastAccessedAt: nil
        )
    }

    private func cacheFileURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).\(AudioCacheManager.cacheFileExtension)")
    }

    private func writeCacheFile(_ id: String, bytes: Int = 1024) throws {
        try Data(repeating: 0, count: bytes).write(to: cacheFileURL(id))
    }

    private func writeIndex(_ index: [String: AudioCacheManager.CacheMeta]) throws {
        try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("index.json"))
    }

    // MARK: - 缺文件：索引项必须一起剔除

    func testMissingFileDropsIndexEntry() throws {
        try writeCacheFile("gone")
        try writeIndex(["gone": meta(size: 1024)])
        let manager = AudioCacheManager(cacheDirectory: directory)
        XCTAssertEqual(manager.totalCacheBytes, 1024)
        XCTAssertNotNil(manager.cachedItem(for: "gone"))

        // 模拟系统清理缓存目录 / 用户手删
        try FileManager.default.removeItem(at: cacheFileURL("gone"))

        XCTAssertNil(manager.cachedItem(for: "gone"))
        XCTAssertEqual(manager.totalCacheBytes, 0, "文件不在了，索引项必须一起剔除，否则容量虚高")
        XCTAssertFalse(manager.cachedSongIDs.contains("gone"))
    }

    // MARK: - 删除失败：索引项必须保留

    func testPurgeKeepsEntryWhenDeletionFails() throws {
        try writeCacheFile("old", bytes: 2048)
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        try writeIndex(["old": meta(size: 2048, cachedAt: eightDaysAgo)])

        // 目录设为只读：removeItem 会失败（模拟文件被占用 / 权限问题）
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        let manager = AudioCacheManager(cacheDirectory: directory)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: cacheFileURL("old").path),
            "构造前提：文件因权限而删不掉"
        )
        XCTAssertEqual(
            manager.totalCacheBytes, 2048,
            "删除失败时必须保留索引项，否则孤儿文件下次启动会被重新收养、拿到新的 7 天租约"
        )
    }

    // MARK: - clearAll 后重新入队：标记归属

    private actor JobCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    /// `clearAll` 之后同一首歌立刻重新入队：旧任务的收尾不得抹掉新任务的
    /// 「缓存中」标记 —— 抹掉后同曲再入队能通过去重守卫，会被重复下载两遍。
    func testReplayAfterClearAllDoesNotDuplicateDownload() async throws {
        let counter = JobCounter()
        let manager = AudioCacheManager(cacheDirectory: directory) { _, destination, _ in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(250))
            try Data(repeating: 0, count: 512).write(to: destination)
            return (128, 512)
        }
        let source = URL(string: "https://example.invalid/cleartone-dup.mp3")!

        manager.cacheInBackground(songID: "dup", sourceURL: source)
        let started = await waitUntil { await counter.value >= 1 }
        XCTAssertTrue(started, "第一个任务应已开始下载")

        // 清除（取消在途任务）后同一首歌立刻重新入队
        manager.clearAll()
        manager.cacheInBackground(songID: "dup", sourceURL: source)

        // 等旧任务收尾、新任务跑起来
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(
            manager.cachingSongIDs.contains("dup"),
            "新任务的「缓存中」标记被旧任务的收尾抹掉了"
        )
        // 这个调用在修好前会再排第三个任务（标记没了，去重守卫放行）
        manager.cacheInBackground(songID: "dup", sourceURL: source)

        let committed = await waitUntil { manager.cachedSongIDs.contains("dup") }
        XCTAssertTrue(committed, "重新入队的任务应完成并写入索引")
        try await Task.sleep(for: .milliseconds(400))

        let calls = await counter.value
        XCTAssertEqual(calls, 2, "同一首歌被重复下载了（任务数 \(calls)，预期 2）")

        manager.clearAll()
    }
}
