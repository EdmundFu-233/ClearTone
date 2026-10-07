import XCTest

/// 持久化模型的后向兼容：后加字段缺 key 时，不能被整份解码失败带走。
///
/// 这是 Swift `Codable` 的经典陷阱：属性声明上的默认值只在 memberwise init
/// 生效，合成的 `init(from:)` 对非可选属性一律 `decode` 并要求 key 存在。
/// `queue.json` / `recentSongs` / `cachedLikedSongs` 都是整份解码的，
/// 一首歌缺一个 key 就会把整个队列/历史/收藏缓存静默清空。
final class ModelDecodingCompatibilityTests: XCTestCase {

    private let decoder = JSONDecoder()

    /// 旧格式歌手（只有 id + name）必须解出来，alias 回落为空数组。
    func testArtistDecodesWithoutAliasAndAvatar() throws {
        let json = #"{"id":"a1","name":"周杰伦"}"#
        let artist = try decoder.decode(Artist.self, from: Data(json.utf8))
        XCTAssertEqual(artist.id, "a1")
        XCTAssertEqual(artist.name, "周杰伦")
        XCTAssertTrue(artist.alias.isEmpty, "缺 alias 必须回落到空数组，而不是解码失败")
        XCTAssertNil(artist.avatarURL)
    }

    /// 旧格式队列（没有 playbackRate、歌手没有 alias）必须整份解出来。
    func testPersistedQueueDecodesWithoutPlaybackRateAndOldArtist() throws {
        let json = """
        {
          "items": [
            {
              "id": "8B1C3D2A-0000-4000-8000-000000000001",
              "song": {
                "id": "1",
                "title": "歌",
                "artists": [{"id": "a1", "name": "歌手"}],
                "duration": 12.5,
                "isPlayable": true,
                "qualities": [],
                "source": "netease"
              },
              "addedAt": 0
            }
          ],
          "currentIndex": 0,
          "mode": "顺序播放",
          "currentTime": 3.5,
          "volume": 1.0,
          "isMuted": false,
          "requestedQuality": "极高"
        }
        """
        let queue = try decoder.decode(PersistedQueue.self, from: Data(json.utf8))
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(queue.items.first?.song.title, "歌")
        XCTAssertTrue(queue.items.first?.song.artists.first?.alias.isEmpty ?? false)
        XCTAssertEqual(queue.playbackRate, 1.0, "缺字段时应回落到 1.0，而不是整份解码失败")
        XCTAssertEqual(queue.currentTime, 3.5, accuracy: 0.001)
    }
}
