import XCTest

/// 歌词状态机（`Core/Lyrics/LyricsSession.swift`）。
///
/// macOS 与 iOS 的正在播放页原先各手写一份，两个视图都**不在测试 target 里**，
/// 于是「切歌先清空」「迟到响应丢弃」「取消后复位 loading」这些边界一条都测不到。
/// 抽到 Core 之后在这里锁死。
@MainActor
final class LyricsSessionTests: XCTestCase {

    /// 可控歌词桩：`hold` 打开时挂起直到测试显式放行（用来制造在途请求）。
    private actor StubProvider: MusicProvider {
        let identifier = "lyrics-stub"
        let displayName = "歌词桩"

        private var result = LyricResult(lines: [], hasWordTiming: false, isPureMusic: false)
        private var error: Error?
        private var hold = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var calls = 0
        private(set) var requestedSongIDs: [String] = []

        func setResult(_ value: LyricResult) { result = value }
        func setError(_ value: Error?) { error = value }
        func setHold(_ value: Bool) { hold = value }
        func callCount() -> Int { calls }
        var pendingCount: Int { waiting.count }

        func fetchLyrics(songID: String) async throws -> LyricResult {
            calls += 1
            requestedSongIDs.append(songID)
            // 在**发起时**固定结果，而不是放行时才读 —— 否则「旧请求晚到」的用例里，
            // 旧请求会返回新歌的数据，漏掉代次校验也照样通过。
            let captured = result
            let capturedError = error
            if hold { await withCheckedContinuation { waiting.append($0) } }
            if let capturedError { throw capturedError }
            return captured
        }

        /// 放行最先挂起的调用
        func resumeFirst() {
            guard !waiting.isEmpty else { return }
            waiting.removeFirst().resume()
        }

        // 以下未被本测试使用，一律报「不支持」，避免误用
        func fetchQRCodeKey() async throws -> String { throw MusicError.unknown("unsupported") }
        func fetchQRCodeImage(key: String) async throws -> URL { throw MusicError.unknown("unsupported") }
        func checkQRCodeStatus(key: String) async throws -> QRLoginStatus { throw MusicError.unknown("unsupported") }
        func logout() async throws { throw MusicError.unknown("unsupported") }
        func fetchAccountInfo() async throws -> AccountInfo? { nil }
        func search(query: String, type: SearchType, page: Int, limit: Int) async throws -> SearchResult { throw MusicError.unknown("unsupported") }
        func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail { throw MusicError.unknown("unsupported") }
        func fetchPlaylistTracks(id: String, page: Int, limit: Int) async throws -> [Song] { throw MusicError.unknown("unsupported") }
        func fetchAlbumDetail(id: String) async throws -> PlaylistDetail { throw MusicError.unknown("unsupported") }
        func fetchArtistDetail(id: String) async throws -> ArtistDetail { throw MusicError.unknown("unsupported") }
        func fetchPlayableURL(songID: String, quality: AudioQuality.QualityLevel) async throws -> PlayableURL { throw MusicError.unknown("unsupported") }
        func fetchUserPlaylists() async throws -> [Playlist] { throw MusicError.unknown("unsupported") }
        func fetchLikedSongs() async throws -> [Song] { throw MusicError.unknown("unsupported") }
        func likeSong(id: String, like: Bool) async throws { throw MusicError.unknown("unsupported") }
        func fetchRecommendPlaylists() async throws -> [Playlist] { throw MusicError.unknown("unsupported") }
        func fetchDailyRecommendSongs() async throws -> [Song] { throw MusicError.unknown("unsupported") }
    }

    private func song(_ id: String) -> Song {
        Song(id: id, title: "歌-\(id)", artists: [Artist(id: "a1", name: "人")], source: .netease)
    }

    private func line(_ time: TimeInterval, _ text: String) -> LyricLine {
        LyricLine(time: time, text: text)
    }

    private func waitUntil(
        _ label: String, timeout: TimeInterval = 2, condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待\(label)超时")
    }

    private func makeSession(_ provider: StubProvider) -> LyricsSession {
        LyricsSession { _ in provider }
    }

    func testLoadPopulatesLinesAndFlags() async {
        let provider = StubProvider()
        await provider.setResult(LyricResult(
            lines: [line(0, "第一行"), line(3, "第二行")], hasWordTiming: true, isPureMusic: false
        ))
        let session = makeSession(provider)

        await session.load(for: song("1"))

        XCTAssertEqual(session.lines.map(\.text), ["第一行", "第二行"])
        XCTAssertTrue(session.hasWordTiming)
        XCTAssertFalse(session.isPureMusic)
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.isLoading, "加载完成后 spinner 必须消失")
    }

    /// 纯音乐：界面靠这个标志显示「纯音乐，请欣赏」而不是「暂无歌词」
    func testPureMusicFlagIsSurfaced() async {
        let provider = StubProvider()
        await provider.setResult(LyricResult(lines: [], hasWordTiming: false, isPureMusic: true))
        let session = makeSession(provider)

        await session.load(for: song("1"))

        XCTAssertTrue(session.isPureMusic)
        XCTAssertTrue(session.lines.isEmpty)
    }

    /// 没有正在播放的歌：清空、不发请求
    func testNilSongClearsWithoutRequest() async {
        let provider = StubProvider()
        await provider.setResult(LyricResult(lines: [line(0, "旧词")], hasWordTiming: false, isPureMusic: false))
        let session = makeSession(provider)
        await session.load(for: song("1"))
        XCTAssertFalse(session.lines.isEmpty)

        await session.load(for: nil)

        XCTAssertTrue(session.lines.isEmpty, "停播后不能把上一首的歌词留在页面上")
        XCTAssertFalse(session.isLoading)
        let calls = await provider.callCount()
        XCTAssertEqual(calls, 1, "没有歌可播时不该发请求")
    }

    /// 解析器返回 nil（例如 iOS 上的本地歌曲）时不请求，直接走空态
    func testUnresolvableSongIsSkipped() async {
        let provider = StubProvider()
        let session = LyricsSession { _ in nil }

        await session.load(for: song("1"))

        XCTAssertTrue(session.lines.isEmpty)
        XCTAssertFalse(session.isLoading)
        let calls = await provider.callCount()
        XCTAssertEqual(calls, 0)
    }

    /// 失败要暴露错误（界面的重试按钮靠它），且不留半截歌词
    func testFailureSurfacesErrorAndKeepsLinesEmpty() async {
        let provider = StubProvider()
        await provider.setError(MusicError.networkUnavailable)
        let session = makeSession(provider)

        await session.load(for: song("1"))

        XCTAssertNotNil(session.errorMessage)
        XCTAssertTrue(session.lines.isEmpty)
        XCTAssertFalse(session.isLoading)
    }

    /// 切歌必须**同步**清空旧歌词：否则新歌的前几秒会拿上一首的词配这一首的进度
    func testSwitchingSongClearsLinesBeforeResponse() async {
        let provider = StubProvider()
        await provider.setResult(LyricResult(lines: [line(0, "A 的词")], hasWordTiming: false, isPureMusic: false))
        let session = makeSession(provider)
        await session.load(for: song("A"))
        XCTAssertEqual(session.lines.map(\.text), ["A 的词"])

        // B 的请求挂住不返回，此时页面上的歌词必须已经清空
        await provider.setResult(LyricResult(lines: [line(0, "B 的词")], hasWordTiming: false, isPureMusic: false))
        await provider.setHold(true)
        let task = Task { await session.load(for: song("B")) }
        await waitUntil("B 的请求发出") { await provider.pendingCount == 1 }

        XCTAssertTrue(session.lines.isEmpty, "切歌后旧歌词必须立刻消失")
        XCTAssertTrue(session.isLoading)

        await provider.resumeFirst()
        await task.value
        XCTAssertEqual(session.lines.map(\.text), ["B 的词"])
    }

    /// 迟到的旧响应不得覆盖新歌的歌词（代次令牌）
    func testLateResponseFromPreviousSongIsDiscarded() async {
        let provider = StubProvider()
        await provider.setResult(LyricResult(lines: [line(0, "A 的词")], hasWordTiming: false, isPureMusic: false))
        await provider.setHold(true)
        let session = makeSession(provider)

        // A 的请求先发出并挂住（响应内容在发起时就固定为 A 的词）
        let first = Task { await session.load(for: song("A")) }
        await waitUntil("A 的请求发出") { await provider.pendingCount == 1 }
        // 切到 B
        await provider.setResult(LyricResult(lines: [line(0, "B 的词")], hasWordTiming: false, isPureMusic: false))
        let second = Task { await session.load(for: song("B")) }
        await waitUntil("B 的请求发出") { await provider.pendingCount == 2 }

        // 先放行 A（旧代次）：它的响应必须被丢弃
        await provider.resumeFirst()
        await first.value
        XCTAssertTrue(session.lines.isEmpty, "A 的迟到响应不得写进 B 的页面")

        await provider.resumeFirst()
        await second.value
        XCTAssertEqual(
            session.lines.map(\.text), ["B 的词"],
            "B 仍在途，之后返回的响应才是当前代次"
        )
    }

    /// `.task` 取消（视图消失）后 `isLoading` 不能停在 true，否则歌词面板永久转圈
    func testCancelledLoadResetsLoading() async {
        let provider = StubProvider()
        await provider.setHold(true)
        let session = makeSession(provider)

        let task = Task { await session.load(for: song("1")) }
        await waitUntil("请求发出") { await provider.pendingCount == 1 }
        XCTAssertTrue(session.isLoading)

        task.cancel()
        await provider.resumeFirst()
        await task.value

        XCTAssertFalse(session.isLoading, "取消后必须复位 loading")
        XCTAssertNil(session.errorMessage, "用户主动离开页面不是「加载失败」")
    }

    /// `reset()` 必须**同步**清空，供视图在创建异步加载任务之前调用。
    ///
    /// 只在 `load` 的 async 函数体里清的话，`Task { await load(...) }` 与函数体执行
    /// 之间还有一帧，那期间视图会拿上一首的词配这一首的进度。
    func testResetClearsEverythingSynchronously() async {
        let provider = StubProvider()
        await provider.setResult(LyricResult(
            lines: [line(0, "A 的词")], hasWordTiming: true, isPureMusic: true
        ))
        let session = makeSession(provider)
        await session.load(for: song("A"))
        XCTAssertFalse(session.lines.isEmpty)
        XCTAssertTrue(session.isPureMusic)
        XCTAssertTrue(session.hasWordTiming)

        session.reset()

        XCTAssertTrue(session.lines.isEmpty)
        XCTAssertFalse(session.isPureMusic)
        XCTAssertFalse(session.hasWordTiming)
        XCTAssertFalse(session.isLoading)
        XCTAssertNil(session.errorMessage)
    }

    /// 已被取消的加载不得再清空/改写状态。
    ///
    /// 取消不保证在 await 返回前生效：一个在 `reset()` 之前就被取消的任务，
    /// 若仍执行函数体，会先清空面板再因 token 不符丢弃自己的结果 —— 留下空白。
    func testAlreadyCancelledLoadDoesNotClearState() async {
        let provider = StubProvider()
        await provider.setResult(LyricResult(
            lines: [line(0, "A 的词")], hasWordTiming: false, isPureMusic: false
        ))
        let session = makeSession(provider)
        await session.load(for: song("A"))
        XCTAssertEqual(session.lines.map(\.text), ["A 的词"])

        // 在任务真正开始执行之前就取消它（同一个主线程，cancel 先于任务体）
        let task = Task { await session.load(for: song("B")) }
        task.cancel()
        await task.value

        XCTAssertEqual(
            session.lines.map(\.text), ["A 的词"],
            "被取消的加载不该清空已有歌词"
        )
    }
}
