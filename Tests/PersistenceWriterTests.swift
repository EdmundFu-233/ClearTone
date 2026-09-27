import XCTest

/// 持久化写入。
///
/// 回归的核心：`PersistenceWriter.writePending` 曾经写成
/// `guard let queue, let recent else { return }` —— 合取守卫，而上面两行已经把
/// 两个 pending 清空了。于是「本轮只有队列变更」这一轮的快照被**永久丢弃**
/// （不是延后重试）。
///
/// 后果面很大：队列编辑、播放进度节流、播放模式、音量、音质、清空队列
/// 全部只 schedule 了 queue，因此**一律不落盘**；只有切歌（同时 schedule 了
/// recent）才顺带把队列写出去。用户「清空队列 → ⌘Q」之后旧队列原封不动回来。
@MainActor
final class PersistenceWriterTests: XCTestCase {

    private func makeQueue(itemIDs: [String], currentTime: TimeInterval = 0) -> PersistedQueue {
        PersistedQueue(
            items: itemIDs.map { QueueItem(song: Self.song($0)) },
            currentIndex: itemIDs.isEmpty ? -1 : 0,
            mode: .sequential,
            currentTime: currentTime,
            volume: 0.8,
            isMuted: false,
            requestedQuality: .exhigh
        )
    }

    private static func song(_ id: String) -> Song {
        Song(id: id, title: "歌-\(id)", artists: [Artist(id: "a\(id)", name: "人")], source: .netease)
    }

    /// 必须先跑一次，把 PendingCache 之外的共享状态归零
    override func setUp() async throws {
        try await super.setUp()
        await PersistenceStore.PersistenceWriter.shared.reset()
    }

    override func tearDown() async throws {
        await PersistenceStore.PersistenceWriter.shared.reset()
        try await super.tearDown()
    }

    // MARK: - 只排队列也必须落盘

    /// 这是本条修复的核心断言：只 schedule(queue:) 时文件必须被写出来。
    func testQueueOnlyScheduleIsActuallyPersisted() async throws {
        let queue = makeQueue(itemIDs: ["1", "2", "3"], currentTime: 42)
        await PersistenceStore.PersistenceWriter.shared.schedule(queue: queue)
        await PersistenceStore.PersistenceWriter.shared.flushNow()

        let loaded = try XCTUnwrap(PersistenceStore.shared.loadQueue())
        XCTAssertEqual(loaded.items.map(\.song.id), ["1", "2", "3"])
        XCTAssertEqual(loaded.currentTime, 42, accuracy: 0.001)
    }

    /// 只 schedule(recentSongs:) 时最近播放必须落盘（原来也被合取守卫吃掉）
    func testRecentOnlyScheduleIsActuallyPersisted() async throws {
        let songs = [Self.song("r1"), Self.song("r2")]
        await PersistenceStore.PersistenceWriter.shared.schedule(recentSongs: songs)
        await PersistenceStore.PersistenceWriter.shared.flushNow()

        let loaded = PersistenceStore.shared.loadRecentSongs()
        XCTAssertEqual(loaded.map(\.id), ["r1", "r2"])
    }

    /// 两条链路各自触发，必须互不影响
    func testQueueAndRecentCanBeScheduledIndependently() async throws {
        await PersistenceStore.PersistenceWriter.shared.schedule(recentSongs: [Self.song("only-recent")])
        await PersistenceStore.PersistenceWriter.shared.flushNow()
        XCTAssertEqual(PersistenceStore.shared.loadRecentSongs().map(\.id), ["only-recent"])

        await PersistenceStore.PersistenceWriter.shared.schedule(queue: makeQueue(itemIDs: ["q1"]))
        await PersistenceStore.PersistenceWriter.shared.flushNow()
        XCTAssertEqual(PersistenceStore.shared.loadQueue()?.items.map(\.song.id), ["q1"])
        // 第二轮不该把第一轮的最近播放清掉
        XCTAssertEqual(PersistenceStore.shared.loadRecentSongs().map(\.id), ["only-recent"])
    }

    /// 清空队列必须真的落盘 —— 这正是原来「清空后 ⌘Q，旧队列又回来了」那条
    func testEmptyQueueIsPersisted() async throws {
        await PersistenceStore.PersistenceWriter.shared.schedule(queue: makeQueue(itemIDs: ["stale"]))
        await PersistenceStore.PersistenceWriter.shared.flushNow()
        XCTAssertEqual(PersistenceStore.shared.loadQueue()?.items.count, 1)

        await PersistenceStore.PersistenceWriter.shared.schedule(queue: makeQueue(itemIDs: []))
        await PersistenceStore.PersistenceWriter.shared.flushNow()
        let loaded = try XCTUnwrap(PersistenceStore.shared.loadQueue())
        XCTAssertTrue(loaded.items.isEmpty, "清空队列必须落盘，否则退出后旧队列会复活")
        XCTAssertEqual(loaded.currentIndex, -1)
    }

    /// 连续多次只改队列，每一次都要落盘（防抖不能吞掉中间态）
    func testRepeatedQueueOnlySchedulesAllReachDisk() async throws {
        for round in 1...3 {
            await PersistenceStore.PersistenceWriter.shared.schedule(
                queue: makeQueue(itemIDs: Array(1...round).map { "\($0)" })
            )
            await PersistenceStore.PersistenceWriter.shared.flushNow()
        }
        let loaded = try XCTUnwrap(PersistenceStore.shared.loadQueue())
        XCTAssertEqual(loaded.items.count, 3, "每一轮 queue-only 落盘都应生效")
    }

    // MARK: - 退出时的原子落盘

    /// 退出走 `persistAndFlush`：`schedule` + `flush` 合成一个 actor 方法。
    /// 分成两个 Task 时它们在 actor 上的先后没有保证，flush 完全可能先跑而刷了个空。
    func testPersistAndFlushWritesSnapshotGivenAsArgument() async throws {
        try await PersistenceStore.PersistenceWriter.shared.persistAndFlush(
            queue: makeQueue(itemIDs: ["quit-1"]),
            recentSongs: [Self.song("quit-recent")]
        )
        XCTAssertEqual(PersistenceStore.shared.loadQueue()?.items.map(\.song.id), ["quit-1"])
        XCTAssertEqual(PersistenceStore.shared.loadRecentSongs().map(\.id), ["quit-recent"])
    }

    /// 参数为 nil 时不该把已有内容清掉
    func testPersistAndFlushWithNilArgumentsKeepsExistingData() async throws {
        try await PersistenceStore.PersistenceWriter.shared.persistAndFlush(
            queue: makeQueue(itemIDs: ["keep"]), recentSongs: [Self.song("keep-recent")]
        )
        try await PersistenceStore.PersistenceWriter.shared.persistAndFlush(queue: nil, recentSongs: nil)
        XCTAssertEqual(PersistenceStore.shared.loadQueue()?.items.map(\.song.id), ["keep"])
        XCTAssertEqual(PersistenceStore.shared.loadRecentSongs().map(\.id), ["keep-recent"])
    }

    // MARK: - 存储隔离

    /// 测试必须跑在临时目录里。原先由两个测试类各自 `setenv` 不同的目录，
    /// 而 `storageURL` 是 `private let`（只求值一次）—— 谁先跑谁赢，
    /// `DemoAudioGeneratorTests` 当时压根不隔离，直接删改真实 App 目录下的音频。
    func testStorageRootHonoursTestOverride() {
        let expected = ProcessInfo.processInfo.environment["CLEARTONE_TEST_STORAGE_DIR"]
        let root = PersistenceStore.storageRoot.path
        if let expected, !expected.isEmpty {
            XCTAssertEqual(root, expected, "持久化必须落在 run-tests.sh 指定的临时目录")
        } else {
            XCTFail("CLEARTONE_TEST_STORAGE_DIR 未设置 —— 请通过 ./scripts/run-tests.sh 运行，"
                    + "否则会写到真实用户目录")
        }
    }

    /// 测试音频目录也必须跟着隔离走（它原先硬编码 Application Support）
    func testTestAudioDirectoryIsIsolatedToo() {
        let expected = ProcessInfo.processInfo.environment["CLEARTONE_TEST_STORAGE_DIR"] ?? ""
        guard !expected.isEmpty else {
            return XCTFail("CLEARTONE_TEST_STORAGE_DIR 未设置")
        }
        XCTAssertTrue(
            DemoAudioGenerator.directory().path.hasPrefix(expected),
            "测试音频目录必须在临时目录内，否则测试会删改开发者真实 App 的音频文件"
        )
    }
}
