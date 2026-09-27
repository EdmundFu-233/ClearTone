import XCTest

/// 把歌曲拖进队列面板。
///
/// 回归的核心：早先 `SongTransfer` 只带 `songID`，落点按 id 去
/// 「当前队列 + 播放历史」里查 —— 搜索结果、榜单、歌单里从没播放过的歌
/// 查不到就被静默丢掉，用户看到的是「拖了没反应」。
@MainActor
final class QueueDropTests: XCTestCase {

    private func song(_ id: String, title: String = "歌", artist: String = "人") -> Song {
        Song(id: id, title: title, artists: [Artist(id: "a-\(id)", name: artist)], source: .netease)
    }

    /// 队列里没有、也没播放过 —— 早先就是这一种会丢
    func testSongAbsentFromLocalPoolStillResolves() {
        let target = song("999", title: "搜索结果")
        let resolved = SongTransfer.resolveSongs([SongTransfer(song: target)], pool: [])
        XCTAssertEqual(resolved.map(\.id), ["999"])
        XCTAssertEqual(resolved.first?.title, "搜索结果")
    }

    /// 本地池里的副本优先：它可能带 `qualities` 等更完整的信息
    func testLocalPoolCopyWins() {
        let local = song("1", title: "本地完整版")
        let stale = song("1", title: "载荷快照")
        let resolved = SongTransfer.resolveSongs([SongTransfer(song: stale)], pool: [local])
        XCTAssertEqual(resolved.map(\.title), ["本地完整版"])
    }

    /// 顺序按拖放给出的来，不能被 pool 的顺序带偏
    func testOrderFollowsDragOrder() {
        let resolved = SongTransfer.resolveSongs(
            [song("3"), song("1"), song("2")].map { SongTransfer(song: $0) },
            pool: [song("1"), song("2"), song("3")]
        )
        XCTAssertEqual(resolved.map(\.id), ["3", "1", "2"])
    }

    /// 同一批里的重复 id 只入队一次
    func testDuplicateIDsInOneBatchAreCollapsed() {
        let resolved = SongTransfer.resolveSongs(
            [song("1"), song("2"), song("1")].map { SongTransfer(song: $0) },
            pool: []
        )
        XCTAssertEqual(resolved.map(\.id), ["1", "2"])
    }

    func testEmptyBatchResolvesToNothing() {
        XCTAssertTrue(SongTransfer.resolveSongs([], pool: [song("1")]).isEmpty)
    }

    /// 载荷必须能编解码 —— `CodableRepresentation` 靠它，编不出就等于没有拖放
    func testTransferRoundTripsThroughCodable() throws {
        let original = SongTransfer(song: song("42", title: "圆周率", artist: "甲 / 乙"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SongTransfer.self, from: data)
        XCTAssertEqual(decoded.songID, "42")
        XCTAssertEqual(decoded.song.title, "圆周率")
        XCTAssertEqual(decoded.song.artistNames, "甲 / 乙")
        XCTAssertEqual(decoded.song, original.song)
    }

    /// 载荷必须**自足**：不依赖本地池也能拼出一条可用的队列项。
    /// 只传 id 的老做法就是漏在这里 —— 落点查不到就把歌丢了。
    func testPayloadCarriesEveryFieldAQueueRowNeeds() throws {
        let original = Song(
            id: "42",
            title: "圆周率",
            artists: [Artist(id: "a1", name: "甲"), Artist(id: "a2", name: "乙")],
            album: Album(id: "al1", name: "辑"),
            duration: 217,
            coverURL: URL(string: "https://example.com/c.jpg"),
            isPlayable: true,
            source: .netease
        )
        let decoded = try JSONDecoder().decode(
            SongTransfer.self, from: JSONEncoder().encode(SongTransfer(song: original))
        )
        XCTAssertEqual(decoded.song, original, "编解码不该丢任何字段")
        XCTAssertEqual(decoded.song.artistNames, "甲 / 乙")
        XCTAssertEqual(decoded.song.album?.name, "辑")
        XCTAssertEqual(decoded.song.duration, 217, accuracy: 0.001)
        XCTAssertNotNil(decoded.song.coverURL)
        XCTAssertTrue(decoded.song.isPlayable)
    }
}
