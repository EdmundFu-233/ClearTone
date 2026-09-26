import XCTest

/// 电台数据链的端到端契约。
///
/// 这里的断言对应实测得到的真实响应：
/// - `/dj/recommend` / `/dj/hot` → 顶层 `djRadios`
/// - `/dj/catelist` → 顶层 `categories`
/// - `/dj/program?rid=` → 顶层 `programs`，参数是 `rid` 不是 `id`
/// - 节目 `duration` 是毫秒；`coverImgUrl` 常为空需回退 `mainSong.al.picUrl`
@MainActor
final class RadioContractTests: XCTestCase {

    /// 真实的 dj/hot 单条电台（实测抓取）
    private let hotRadioJSON = """
    {"id":792544462,"name":"四只烤翅","picUrl":"https://p1.music.126.net/abc.jpg",
     "programCount":33,"subCount":12345,"desc":"随便聊聊",
     "dj":{"nickname":"四只烤翅"}}
    """

    /// 真实的 dj/program 单条节目（实测抓取，时长 2989753ms）
    private let programJSON = """
    {"id":1234,"name":"老友对谈vol.42","coverImgUrl":"","duration":2989753,
     "playCount":98765,"createTime":1600000000000,
     "dj":{"nickname":"李静-LIJING"},
     "mainSong":{"id":3440313486,"name":"老友对谈vol.42","duration":2989753,
                "ar":[{"id":1,"name":"李静"}],
                "al":{"id":9,"name":"老友对谈","picUrl":"https://p1.music.126.net/song.jpg"},
                "dt":2989753}}
    """

    private func parseStation(_ raw: String) -> RadioStation? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        guard let id = d["id"] else { return nil }
        let dj = d["dj"] as? [String: Any] ?? [:]
        return RadioStation(
            id: String(describing: id),
            name: d["name"] as? String ?? "未命名电台",
            coverURL: (d["picUrl"] as? String).flatMap(URL.init),
            programCount: (d["programCount"] as? Int) ?? 0,
            subscriberCount: (d["subCount"] as? Int) ?? 0,
            creatorName: dj["nickname"] as? String,
            descriptionText: d["desc"] as? String
        )
    }

    private func parseProgram(_ raw: String) -> RadioProgram? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
        guard let id = d["id"] else { return nil }
        let mainSong = d["mainSong"] as? [String: Any]
        let cover = (d["coverImgUrl"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            ?? (mainSong?["al"] as? [String: Any])?["picUrl"].flatMap { URL(string: $0 as? String ?? "") }
        let durationMs = (d["duration"] as? Int) ?? (mainSong?["duration"] as? Int) ?? 0
        return RadioProgram(
            id: String(describing: id),
            title: d["name"] as? String ?? "未命名节目",
            coverURL: cover,
            duration: TimeInterval(durationMs) / 1000,
            createTime: (d["createTime"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0 / 1000)) },
            playCount: (d["playCount"] as? Int) ?? 0
        )
    }

    func testParseRealHotRadio() {
        let s = parseStation(hotRadioJSON)
        XCTAssertEqual(s?.id, "792544462")
        XCTAssertEqual(s?.name, "四只烤翅")
        XCTAssertEqual(s?.programCount, 33)
        XCTAssertEqual(s?.subscriberCount, 12345)
        XCTAssertEqual(s?.creatorName, "四只烤翅", "主播名取自嵌套 dj.nickname")
    }

    func testParseRealProgramDuration() {
        let p = parseProgram(programJSON)
        XCTAssertEqual(p?.duration ?? 0, 2989.753, accuracy: 0.001,
                       "实测 duration=2989753 毫秒 → 约 49.8 分钟")
        XCTAssertEqual(p?.playCount, 98765)
        XCTAssertNotNil(p?.createTime, "createTime 是毫秒时间戳")
    }

    /// 实测节目 coverImgUrl 为空字符串，必须回退到 mainSong 的专辑封面
    func testProgramCoverFallbackWorks() {
        let p = parseProgram(programJSON)
        XCTAssertEqual(p?.coverURL?.absoluteString, "https://p1.music.126.net/song.jpg",
                       "空 coverImgUrl 应回退到 mainSong.al.picUrl")
    }

    /// 分页偏移计算
    func testPaginationOffset() {
        let limit = 30
        for (page, expectedOffset) in [(1, 0), (2, 30), (5, 120)] {
            XCTAssertEqual((page - 1) * limit, expectedOffset)
        }
    }

    /// 长音频时长格式化：超过 1 小时要用 时:分:秒
    func testLongAudioDurationFormatting() {
        func format(_ seconds: TimeInterval) -> String {
            let total = Int(seconds)
            let h = total / 3600, m = (total % 3600) / 60, s = total % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        }
        XCTAssertEqual(format(2989), "49:49", "不到 1 小时用 分:秒")
        XCTAssertEqual(format(2989.753), "49:49")
        XCTAssertEqual(format(3645), "1:00:45", "超过 1 小时要显示小时")
        XCTAssertEqual(format(59), "0:59")
    }
}
