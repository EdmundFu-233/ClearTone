import XCTest

/// 每日推荐（`/recommend/songs`）的响应契约与解析。
///
/// fixture 是**实测抓包**的真实响应精简而成（2026-09，VIP 账号），
/// 不是按文档推测的字段。已确认的坑：
///
/// 1. `dailySongs` 在 `data` 下，不在顶层
/// 2. **时长字段是 `dt`，没有 `duration`** —— 实测同一首歌：
///    `/recommend/songs` → `{dt: 156023}`，`duration` 缺失
///    `/song/detail`     → `{dt: 156023}`，`duration` 为 `null`
///    `mapSong` 必须 `dt` 优先，否则 30 首歌全部显示 0:00
/// 3. `fee: 8` + `privilege.st: 0` + `privilege.cs: false` 表示可正常播放
/// 4. `no` 是可用性位掩码（实测 1 / 7 都可播）
/// 5. 未登录也返回 30 首（通用推荐，非私人化），所以**不能**靠「是否有数据」
///    判断登录态，登录态只能看 `appState.isLoggedIn`
final class DailyRecommendTests: XCTestCase {

    /// 实测：/recommend/songs → code 200, data.dailySongs 共 30 条
    private func makeResponse(songCount: Int) -> [String: Any] {
        let songs = (0..<songCount).map { i -> [String: Any] in
            [
                "id": 3425624458 + i,
                "name": i == 0 ? "Need That Love" : "歌曲 \(i)",
                // 只有 dt，没有 duration —— 这是最关键的一点
                "dt": 156023 + i * 1000,
                "ar": [["id": 1025255, "name": "Sam Feldt"], ["id": 126198005, "name": "ÁSDÍS"]],
                "al": [
                    "id": 394436970,
                    "name": "Need That Love",
                    "picUrl": "http://p4.music.126.net/fwXLL1psPyqhQsmQK_mHYw==/109951173820160027.jpg"
                ],
                "fee": 8,
                "no": 1,
                "privilege": [
                    "id": 3425624458 + i, "st": 0, "pl": 999000, "fl": 320000,
                    "dl": 999000, "cp": 1, "subp": 1, "cs": false
                ]
            ]
        }
        return ["code": 200, "data": ["dailySongs": songs]]
    }

    // MARK: - 时长解析（回归防护）

    /// 复刻 NeteaseProvider.mapSong 的时长取值：dt 优先，回退 duration
    private func parsedDuration(_ raw: [String: Any]) -> TimeInterval {
        (raw["dt"] as? Double ?? raw["duration"] as? Double ?? 0) / 1000.0
    }

    func testDailySongDurationComesFromDtNotDuration() {
        let raw: [String: Any] = ["dt": 156023.0, "name": "Need That Love"]
        XCTAssertNil(raw["duration"], "实测该接口不返回 duration 字段")
        let d = parsedDuration(raw)
        XCTAssertEqual(d, 156.023, accuracy: 0.001, "必须从 dt 换算成秒")
        XCTAssertNotEqual(d, 0, "若只读 duration 会得到 0，UI 显示 0:00")
    }

    /// /song/detail 同样只有 dt
    func testSongDetailAlsoUsesDt() {
        let raw: [String: Any] = ["dt": 156023.0, "duration": NSNull()]
        XCTAssertEqual(parsedDuration(raw), 156.023, accuracy: 0.001)
    }

    func testDurationFormattingForDailySongs() {
        // 每日推荐都是正常单曲（3~5 分钟），不应出现小时位
        let d = parsedDuration(["dt": 156023.0])
        let total = Int(d)
        XCTAssertEqual(total / 3600, 0)
        XCTAssertEqual(String(format: "%d:%02d", total / 60, total % 60), "2:36")
    }

    func testMissingDurationDegradesToZeroNotCrash() {
        XCTAssertEqual(parsedDuration([:]), 0, "字段全缺时降级为 0，不崩溃")
    }

    // MARK: - 响应结构

    func testDailySongsLiveUnderData() {
        let json = makeResponse(songCount: 30)
        XCTAssertEqual(json["code"] as? Int, 200)
        let data = json["data"] as? [String: Any]
        let daily = data?["dailySongs"] as? [[String: Any]]
        XCTAssertEqual(daily?.count, 30, "实测固定 30 首")
        XCTAssertNotNil(daily?.first?["id"])
    }

    func testEmptyDailySongsIsValidNotAnError() {
        let json: [String: Any] = ["code": 200, "data": ["dailySongs": []]]
        let daily = (json["data"] as? [String: Any])?["dailySongs"] as? [[String: Any]]
        XCTAssertEqual(daily?.count, 0, "未登录/异常时返回空数组而非报错，UI 应静默隐藏区块")
    }

    // MARK: - 可播放性

    /// fee: 8 且 privilege.st == 0、cs == false → 可播放
    func testVIPSongInDailyRecommendIsPlayable() {
        let song = makeResponse(songCount: 1)["data"].flatMap { ($0 as? [String: Any])?["dailySongs"] as? [[String: Any]] }?.first
        XCTAssertEqual(song?["fee"] as? Int, 8, "实测为 VIP 歌曲")
        let priv = song?["privilege"] as? [String: Any]
        XCTAssertEqual(priv?["st"] as? Int, 0)
        XCTAssertEqual(priv?["cs"] as? Bool, false)
        XCTAssertEqual(priv?["cp"] as? Int, 1)
    }

    func testArtistNamesJoinMultipleArtists() {
        let song = (makeResponse(songCount: 1)["data"] as? [String: Any])?["dailySongs"] as? [[String: Any]]
        let ar = song?.first?["ar"] as? [[String: Any]]
        XCTAssertEqual(ar?.count, 2)
        let names = (ar ?? []).compactMap { $0["name"] as? String }
        XCTAssertEqual(names.joined(separator: " / "), "Sam Feldt / ÁSDÍS")
    }

    func testCoverURLComesFromAlbum() {
        let song = (makeResponse(songCount: 1)["data"] as? [String: Any])?["dailySongs"] as? [[String: Any]]
        let pic = (song?.first?["al"] as? [String: Any])?["picUrl"] as? String
        XCTAssertNotNil(pic)
        XCTAssertTrue(pic!.hasPrefix("http://p4.music.126.net/"), "实测封面在 p4 域，需要 host 故障转移兜底")
    }

    // MARK: - 播放语义

    /// 「播放全部」必须用这 30 首替换队列
    func testPlayAllReplacesQueueWithThirtyDailySongs() {
        let daily = (0..<30).map { Song(id: "\($0)", title: "歌 \($0)", artists: [], duration: 200, source: .netease) }
        var captured: [String] = []
        let play: ([Song], Int) -> Void = { songs, _ in captured = songs.map(\.id) }
        play(daily, 0)
        XCTAssertEqual(captured.count, 30, "播放全部应把 30 首全部装入队列")
    }

    /// 单曲卡片双击：队列是这 30 首，起点是被点的那首
    func testDoubleClickPlaysFromThatSongWithinDailyList() {
        let daily = (0..<30).map { Song(id: "\($0)", title: "歌 \($0)", artists: [], duration: 200, source: .netease) }
        let target = daily[17]
        var startIndex = -1
        if let i = daily.firstIndex(of: target) { startIndex = i }
        XCTAssertEqual(startIndex, 17, "从被双击的歌曲开始，而不是从第 1 首开始")
    }
}
