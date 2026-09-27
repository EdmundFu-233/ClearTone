import XCTest
import Foundation

/// 剥离演示模式的数据迁移。
///
/// ## 为什么要专门测这个
///
/// 迁移里有两处「静默毁数据」的可能，都不会报错、只会让用户丢东西：
///
/// 1. **`SongSource` 原本是编译器合成的 `Codable`。** 旧版本往 `queue.json` 里写过
///    `"source": "demo"`，enum 少了一个 case 就意味着解码抛错，而 `PersistedQueue`
///    是整份解码的 —— **一首歌解不出来，整条队列全没了**。现在改成容错解码。
/// 2. 容错之后那 20 首演示歌曲会以降级后的 `.netease` 身份留在队列里，
///    变成永远播不了的行（还会拿 `demo-1` 这种不存在的 id 去打网易云接口）。
///    所以三处 `[Song]` 持久化点都要按 id 命名空间过滤掉。
///
/// `loadQueue`/`PersistedQueue` 是 internal（测试 target 不用 `@testable import`，
/// 这是本仓库的约定），所以过滤器只能经 public 的 liked 缓存 / 最近播放验证；
/// 但三处调用的是同一个 `isNotLegacyDemoSong`，覆盖到它就够了。
final class DemoRemovalMigrationTests: XCTestCase {

    // MARK: - 容错解码

    /// 核心回归：旧 `queue.json` 里的 `"demo"` 不能让解码抛错。
    ///
    /// **直接解 `[SongSource]`**，不要套一层自己的容器类型 —— 那样测的是
    /// 测试代码里复制的 fallback，而不是 `SongSource` 的解码器。
    ///
    /// 用手写 JSON 而不是 `JSONEncoder`：编码器只会产出当前 enum 认识的值，
    /// 根本构造不出「旧版本写下的」那种数据。
    func testLegacyDemoSourceDecodesWithoutFailing() throws {
        let json = #"["netease","demo","local"]"#.data(using: .utf8)!
        // 曾经这里是 case .demo 不存在 → 抛 DecodingError → 整份 PersistedQueue 解不出来
        let sources = try JSONDecoder().decode([SongSource].self, from: json)
        XCTAssertEqual(sources, [.netease, .netease, .local],
                       "旧数据里的 demo 必须降级为 .netease，而不是让整份数据解码失败")
    }

    /// 完全未知的来源（未来版本写入、或数据损坏）同样不能抛错。
    ///
    /// 逐个值解，而不是解整个数组：数组里只要有一个值坏掉就整体抛错，
    /// 「哪些值降级了、降成了什么」就无从验证。
    func testUnknownSourceValueFallsBackToNetease() throws {
        let json = #"["hologram"]"#.data(using: .utf8)!
        let sources = try JSONDecoder().decode([SongSource].self, from: json)
        XCTAssertEqual(sources, [.netease])
    }

    /// 单个值层面：`Song` 解码时 source 降级，其余字段照常
    func testSongWithLegacySourceStillDecodesFully() throws {
        let json = """
        {"id":"demo-1","title":"短音频测试","artists":[],"duration":30,
         "isPlayable":true,"qualities":[],"source":"demo"}
        """.data(using: .utf8)!
        let song = try JSONDecoder().decode(Song.self, from: json)
        XCTAssertEqual(song.id, "demo-1")
        XCTAssertEqual(song.title, "短音频测试")
        XCTAssertEqual(song.source, .netease, "降级后会被 loadQueue 的过滤器按 id 命名空间剔除")
    }

    // MARK: - 遗留条目过滤

    /// 演示歌曲不得残留在 liked 缓存里
    func testLikedCacheDropsLegacyDemoSongs() {
        assertLegacyDemoSongsAreDropped(
            key: "cachedLikedSongs",
            save: { PersistenceStore.shared.saveCachedLikedSongs($0) },
            load: { PersistenceStore.shared.loadCachedLikedSongs() }
        )
    }

    /// 演示歌曲不得残留在最近播放里
    func testRecentSongsDropsLegacyDemoSongs() {
        assertLegacyDemoSongsAreDropped(
            key: "recentSongs",
            save: { PersistenceStore.shared.saveRecentSongs($0) },
            load: { PersistenceStore.shared.loadRecentSongs() }
        )
    }

    /// 共用断言体。
    ///
    /// `saveSetting`/`loadSetting` 走的是 `UserDefaults.standard`，
    /// **不受** `CLEARTONE_TEST_STORAGE_DIR` 隔离 —— 所以必须把原值存回来，
    /// 否则测试会留下真实的用户状态。
    private func assertLegacyDemoSongsAreDropped(
        key: String,
        save: ([Song]) -> Void,
        load: () -> [Song],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let defaultsKey = "cleartone.persisted.settings.\(key)"
        let original = UserDefaults.standard.data(forKey: defaultsKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        save([
            makeSong(id: "1818", source: .netease),
            makeSong(id: "demo-3", source: .netease),   // 降级后的演示歌曲
            makeSong(id: "demo-pl-1", source: .netease),
            makeSong(id: "/Users/me/Music/a.mp3", source: .local),
        ])

        let loaded = load()
        XCTAssertEqual(loaded.map(\.id), ["1818", "/Users/me/Music/a.mp3"],
                       "只有演示歌曲被剔除，真实歌曲与本地文件必须原样保留",
                       file: file, line: line)
    }

    private func makeSong(id: String, source: SongSource) -> Song {
        Song(id: id, title: "Song \(id)", artists: [Artist(id: "a1", name: "Artist")],
             duration: 30, source: source)
    }
}

