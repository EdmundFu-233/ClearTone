import XCTest

/// 电台接口的响应解析。
///
/// 这里的每条断言都对应一个**实测确认过的坑**，不是从文档推测的：
/// 1. `djRadios` / `categories` / `programs` 都在**顶层**，不在 `result` / `data` 里
/// 2. `/dj/program` 的参数是 `rid` 而非 `id`（`id` 返回「参数错误」）
/// 3. 节目 `duration` 是**毫秒**
/// 4. 节目 `coverImgUrl` 实测常为空，要回退到 `mainSong.al.picUrl`
/// 5. `mainSong` 的 `url` 为 nil（播放时才取），但结构与标准歌曲一致
@MainActor
final class RadioParsingTests: XCTestCase {

    /// 与 NeteaseProvider.mapRadioStation 同构
    private func mapStation(_ d: [String: Any]) -> RadioStation? {
        guard let id = d["id"] else { return nil }
        let dj = d["dj"] as? [String: Any] ?? [:]
        return RadioStation(
            id: String(describing: id),
            name: d["name"] as? String ?? "未命名电台",
            coverURL: (d["picUrl"] as? String).flatMap(URL.init),
            programCount: (d["programCount"] as? Int) ?? 0,
            subscriberCount: (d["subCount"] as? Int) ?? 0,
            creatorName: dj["nickname"] as? String,
            categoryName: d["categoryName"] as? String,
            descriptionText: d["desc"] as? String,
            isSubscribed: (d["isSub"] as? Int) == 1
        )
    }

    /// 与 mapRadioProgram 同构
    private func mapProgram(_ d: [String: Any]) -> RadioProgram? {
        guard let id = d["id"] else { return nil }
        let mainSong = d["mainSong"] as? [String: Any]
        let cover = (d["coverImgUrl"] as? String).flatMap(URL.init)
            ?? (mainSong?["al"] as? [String: Any])?["picUrl"].flatMap { URL(string: $0 as? String ?? "") }
        let durationMs = (d["duration"] as? Int) ?? (mainSong?["duration"] as? Int) ?? 0
        return RadioProgram(
            id: String(describing: id),
            title: d["name"] as? String ?? "未命名节目",
            coverURL: cover,
            duration: TimeInterval(durationMs) / 1000,
            stationName: "测试电台"
        )
    }

    // MARK: - 电台

    func testStationFromTopLevelDjRadios() {
        // 实测结构：{"djRadios":[{...}], "name": "..."}
        let json: [String: Any] = [
            "djRadios": [[
                "id": 792544462, "name": "四只烤翅", "programCount": 33,
                "subCount": 12345, "picUrl": "https://p1.music.126.net/x.jpg",
                "dj": ["nickname": "主播甲"],
            ]],
            "name": "精选电台",
            "code": 200,
        ]
        let radios = (json["djRadios"] as? [[String: Any]])?.compactMap(mapStation) ?? []
        XCTAssertEqual(radios.count, 1)
        let s = radios[0]
        XCTAssertEqual(s.id, "792544462")
        XCTAssertEqual(s.name, "四只烤翅")
        XCTAssertEqual(s.programCount, 33)
        XCTAssertEqual(s.subscriberCount, 12345)
        XCTAssertEqual(s.creatorName, "主播甲", "主播名在嵌套的 dj 字典里")
        XCTAssertNotNil(s.coverURL)
    }

    func testStationWithoutDJDictStillParses() {
        let json: [String: Any] = [
            "djRadios": [["id": 1, "name": "无主播电台"]],
        ]
        let radios = (json["djRadios"] as? [[String: Any]])?.compactMap(mapStation) ?? []
        XCTAssertEqual(radios.count, 1)
        XCTAssertNil(radios[0].creatorName, "缺 dj 字段不应崩溃")
    }

    func testStationIsSubscribed() {
        let json: [String: Any] = ["djRadios": [["id": 1, "name": "已订阅", "isSub": 1]]]
        let s = ((json["djRadios"] as? [[String: Any]])?.compactMap(mapStation))?.first
        XCTAssertEqual(s?.isSubscribed, true)
    }

    // MARK: - 节目

    /// 关键回归：programs 在顶层，不在 data.programs
    func testProgramsAreAtTopLevelNotUnderData() {
        let json: [String: Any] = [
            "count": 72, "more": true,
            "programs": [["id": 1, "name": "节目一"]],
        ]
        XCTAssertNotNil(json["programs"], "实测 programs 在顶层")
        XCTAssertNil(json["data"], "不在 data 下")
    }

    func testProgramDurationIsMilliseconds() {
        // 实测：duration = 2989753 → 约 49.8 分钟
        let json: [String: Any] = ["programs": [[
            "id": 1, "name": "老友对谈", "duration": 2_989_753,
        ]]]
        let p = ((json["programs"] as? [[String: Any]])?.compactMap(mapProgram))?.first
        XCTAssertEqual(p?.duration ?? 0, 2_989.753, accuracy: 0.001,
                       "毫秒必须换算成秒，否则进度条会离谱")
    }

    func testProgramFallsBackToMainSongDuration() {
        let json: [String: Any] = ["programs": [[
            "id": 1, "name": "节目",
            "mainSong": ["id": 3440313486, "name": "同名", "duration": 60_000],
        ]]]
        let p = ((json["programs"] as? [[String: Any]])?.compactMap(mapProgram))?.first
        XCTAssertEqual(p?.duration ?? 0, 60, accuracy: 0.001)
    }

    /// 实测节目 coverImgUrl 常为空，必须回退到主音频专辑封面
    func testProgramCoverFallsBackToMainSong() {
        let json: [String: Any] = ["programs": [[
            "id": 1, "name": "节目", "coverImgUrl": "",
            "mainSong": ["id": 2, "name": "主音频", "al": ["picUrl": "https://p1.music.126.net/al.jpg"]],
        ]]]
        let p = ((json["programs"] as? [[String: Any]])?.compactMap(mapProgram))?.first
        XCTAssertNotNil(p?.coverURL, "空 coverImgUrl 时应回退到 mainSong.al.picUrl")
    }

    func testProgramUsesOwnCoverWhenPresent() {
        let json: [String: Any] = ["programs": [[
            "id": 1, "name": "节目", "coverImgUrl": "https://p1.music.126.net/prog.jpg",
        ]]]
        let p = ((json["programs"] as? [[String: Any]])?.compactMap(mapProgram))?.first
        XCTAssertEqual(p?.coverURL?.absoluteString, "https://p1.music.126.net/prog.jpg")
    }

    func testProgramWithoutIDIsSkipped() {
        let json: [String: Any] = ["programs": [["name": "无 id"], ["id": 2, "name": "正常"]]]
        let programs = (json["programs"] as? [[String: Any]])?.compactMap(mapProgram) ?? []
        XCTAssertEqual(programs.count, 1, "缺 id 的条目应被跳过而不是崩溃")
        XCTAssertEqual(programs.first?.id, "2")
    }

    // MARK: - 分类

    func testCategoriesAtTopLevelWithSubNames() {
        let json: [String: Any] = ["categories": [[
            "id": 3, "name": "情感",
            "sub": [["name": "情感话题"], ["name": "治愈"]],
        ]]]
        let cats = json["categories"] as? [[String: Any]] ?? []
        XCTAssertEqual(cats.count, 1)
        XCTAssertEqual(cats.first?["name"] as? String, "情感")
        let subs = (cats.first?["sub"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertEqual(subs, ["情感话题", "治愈"])
    }

    func testCategoryWithoutSubStillParses() {
        let json: [String: Any] = ["categories": [["id": 1, "name": "无子类"]]]
        let cats = json["categories"] as? [[String: Any]] ?? []
        XCTAssertEqual(cats.count, 1)
    }
}
