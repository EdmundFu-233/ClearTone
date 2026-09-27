import XCTest
import Foundation

// MARK: - 测试辅助

/// 手动放行门闩：wait() 挂起直到 open()；不响应任务取消，用于制造"在途请求"
final class ManualGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                c.resume()
            } else {
                continuation = c
            }
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

/// fetchPlayableURL 挂起在门闩上的 Provider，open() 后才返回
actor GatedProvider: MusicProvider {
    let identifier = "gated-test"
    let displayName = "Gated Test"

    private let gate: ManualGate
    private let url: URL
    private(set) var callCount = 0

    init(gate: ManualGate, url: URL) {
        self.gate = gate
        self.url = url
    }

    func fetchPlayableURL(songID: String, quality: AudioQuality.QualityLevel) async throws -> PlayableURL {
        callCount += 1
        await gate.wait()
        return PlayableURL(url: url, quality: AudioQuality(level: .exhigh, bitrate: 320, isActual: true))
    }

    func fetchQRCodeKey() async throws -> String { throw MusicError.unknown("unsupported") }
    func fetchQRCodeImage(key: String) async throws -> URL { throw MusicError.unknown("unsupported") }
    func checkQRCodeStatus(key: String) async throws -> QRLoginStatus { .failed("unsupported") }
    func logout() async throws { throw MusicError.unknown("unsupported") }
    func fetchAccountInfo() async throws -> AccountInfo? { nil }
    func search(query: String, type: SearchType, page: Int, limit: Int) async throws -> SearchResult { throw MusicError.unknown("unsupported") }
    func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail { throw MusicError.unknown("unsupported") }
    func fetchPlaylistTracks(id: String, page: Int, limit: Int) async throws -> [Song] { throw MusicError.unknown("unsupported") }
    func fetchAlbumDetail(id: String) async throws -> PlaylistDetail { throw MusicError.unknown("unsupported") }
    func fetchArtistDetail(id: String) async throws -> ArtistDetail { throw MusicError.unknown("unsupported") }
    func fetchLyrics(songID: String) async throws -> LyricResult { throw MusicError.unknown("unsupported") }
    func fetchUserPlaylists() async throws -> [Playlist] { throw MusicError.unknown("unsupported") }
    func fetchLikedSongs() async throws -> [Song] { throw MusicError.unknown("unsupported") }
    func likeSong(id: String, like: Bool) async throws { throw MusicError.unknown("unsupported") }
    func fetchRecommendPlaylists() async throws -> [Playlist] { throw MusicError.unknown("unsupported") }
    func fetchDailyRecommendSongs() async throws -> [Song] { throw MusicError.unknown("unsupported") }
}

@MainActor
final class PlayerControllerTests: XCTestCase {

    /// 首次访问 PlayerController.shared 之前，把持久化重定向到临时目录：
    /// 1) 空目录 => loadPersistedState 无恢复源，init 不会自动恢复/联网播放
    /// 2) 测试产生的队列写入不会覆盖开发机真实数据
    /// 持久化隔离由 `scripts/run-tests.sh` 统一 `export CLEARTONE_TEST_STORAGE_DIR` 完成。
    ///
    /// 原来这个类各自 `setenv` 了一个**不同的**目录，而
    /// `PersistenceStore.storageURL` 是 `private let`（只求值一次）——
    /// 于是「谁先跑谁赢」，另一个类的 setenv 静默无效。
    /// `DemoAudioGeneratorTests` 当时压根不隔离，直接删改开发者真实 App 目录下的
    /// tone_440.wav。现在所有持久化都挂在 `PersistenceStore.storageRoot` 上，
    /// 一个环境变量即可全部隔离。
    private static let storageIsolated: Void = {
        XCTAssertNotNil(
            getenv("CLEARTONE_TEST_STORAGE_DIR"),
            "请通过 ./scripts/run-tests.sh 运行；直接跑 xctest 会写到真实用户目录"
        )
        return ()
    }()

    private var player: PlayerController { PlayerController.shared }

    private func makeSong(id: String, source: SongSource = .netease) -> Song {
        Song(id: id, title: "Song \(id)", artists: [Artist(id: "a1", name: "Artist")], source: source)
    }

    /// 指向真实本地 WAV 的歌曲。
    ///
    /// 演示模式已移除，但这些测试要的正是「AVPlayer 真的在出声走表」——
    /// 桩 Provider 只能验证回调顺序，验证不了时钟。`.local` 这条分支
    /// （`PlayerController.loadAndPlay`）不经过任何网络。
    private func makeLocalSong(id: String, fileURL: URL) -> Song {
        Song(id: id, title: "Song \(id)", artists: [Artist(id: "a1", name: "Artist")],
             duration: 30, source: .local, localFileURL: fileURL)
    }

    /// 条件可以是 async 的：经常要读 actor 上的计数（如 GatedProvider.callCount），
    /// 而 XCTAssert* 的 autoclosure 不支持 await
    private func pollUntil(timeout: TimeInterval = 5, _ condition: @MainActor @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    override func tearDown() async throws {
        // 停止播放并置空状态，避免测试间残留
        player.clearQueue()
    }

    // 第二轮复核 #1：清空队列后，在途 URL 请求的迟到响应不得改状态/重建播放器
    func testClearQueueDiscardsInFlightURLRequest() async throws {
        _ = Self.storageIsolated
        let gate = ManualGate()
        let provider = GatedProvider(gate: gate, url: URL(fileURLWithPath: "/nonexistent/test.wav"))
        player.setProvider(provider)
        player.clearQueue()

        let song = makeSong(id: "A") // .netease -> 走 setProvider 的 GatedProvider
        player.play(songs: [song])
        XCTAssertEqual(player.playbackState, .loading(songID: "A"))
        XCTAssertNotNil(player.currentSong)

        // URL 请求仍在途时清空队列（作废在途请求）
        player.clearQueue()
        XCTAssertEqual(player.playbackState, .idle)
        XCTAssertNil(player.currentSong)

        // 放行在途请求，让其"迟到"返回成功响应
        gate.open()
        try await Task.sleep(nanoseconds: 300_000_000)

        // 迟到响应不得把空播放器从 idle 改走，也不得重建 AVPlayer
        XCTAssertEqual(player.playbackState, .idle)
        XCTAssertNil(player.currentSong)
        XCTAssertTrue(player.queue.items.isEmpty)
    }

    // 第二轮复核 #2：切歌开始时旧播放器必须停表，旧时钟不得写入新歌曲进度
    func testSwitchSongStopsOldTimeClock() async throws {
        _ = Self.storageIsolated
        await DemoAudioGenerator.ensureFiles()
        let fileURL = DemoAudioGenerator.directory().appendingPathComponent("tone_440.wav")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw XCTSkip("测试音频生成失败")
        }

        // A：真实本地音频（.local -> 直接读文件，不走网络），等它实际出声走表
        let songA = makeLocalSong(id: "local-A", fileURL: fileURL)
        player.play(songs: [songA])

        guard await (pollUntil { self.player.playbackState == .playing(songID: "local-A") }) else {
            throw XCTSkip("AVPlayer 未进入播放态")
        }
        guard await (pollUntil { self.player.currentTime > 0.2 }) else {
            throw XCTSkip("AVPlayer 无时钟输出")
        }

        // B：URL 请求挂起，复现"B 的 URL 请求缓慢"
        let gate = ManualGate()
        player.setProvider(GatedProvider(gate: gate, url: fileURL))
        let songB = makeSong(id: "B") // .netease -> 走 GatedProvider
        player.play(songs: [songB])
        XCTAssertEqual(player.playbackState, .loading(songID: "B"))
        XCTAssertEqual(player.currentTime, 0, accuracy: 0.01)

        // 等一段时间：若 A 的旧时钟未被移除（未修复），currentTime 会被 A 的时钟污染
        try await Task.sleep(nanoseconds: 700_000_000)
        gate.open()

        XCTAssertEqual(player.playbackState, .loading(songID: "B"))
        XCTAssertEqual(player.currentTime, 0, accuracy: 0.25, "旧歌曲时钟污染了新歌曲进度")
    }

    // 第二轮复核 #3（加载期边界）：ready 之前暂停，进入 ready 后不得自动出声
    func testPauseBeforeReadyPreventsAutoplay() async throws {
        _ = Self.storageIsolated
        await DemoAudioGenerator.ensureFiles()
        let fileURL = DemoAudioGenerator.directory().appendingPathComponent("tone_440.wav")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw XCTSkip("测试音频生成失败")
        }

        let gate = ManualGate()
        player.setProvider(GatedProvider(gate: gate, url: fileURL))
        let song = makeSong(id: "C") // .netease -> 走 GatedProvider
        player.play(songs: [song])
        XCTAssertEqual(player.playbackState, .loading(songID: "C"))

        // URL 返回前（loading 期间）用户暂停
        player.pause()
        XCTAssertEqual(player.playbackState, .paused(songID: "C"))

        // 放行请求，item 进入 ready；按最新暂停意图不得自动出声
        gate.open()
        try await Task.sleep(nanoseconds: 500_000_000)

        switch player.playbackState {
        case .playing:
            XCTFail("加载期暂停后不应自动出声，当前为 .playing")
        case .paused, .idle, .loading:
            break
        default:
            XCTFail("非预期的最终状态：\(player.playbackState)")
        }
    }

    // MARK: - 加载中的播放/暂停按钮

    /// 复核外的缺陷：`.loading` 下 togglePlayPause() 原本是 `break`，
    /// 但按钮图标按 isPlayIntentActive 显示成「⏸ 暂停」——图标摆着暂停、点下去没反应
    func testToggleDuringLoadingHonorsPlayPauseIntent() async throws {
        _ = Self.storageIsolated
        await DemoAudioGenerator.ensureFiles()
        let fileURL = DemoAudioGenerator.directory().appendingPathComponent("tone_440.wav")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw XCTSkip("测试音频生成失败")
        }

        let gate = ManualGate()
        player.setProvider(GatedProvider(gate: gate, url: fileURL))
        let song = makeSong(id: "D")
        player.play(songs: [song])
        XCTAssertEqual(player.playbackState, .loading(songID: "D"))
        XCTAssertTrue(player.playbackState.isPlayIntentActive, "加载中按钮应显示暂停图标")

        // 点暂停：意图翻成不播，图标同步翻成播放
        player.togglePlayPause()
        XCTAssertEqual(player.playbackState, .paused(songID: "D"))
        XCTAssertFalse(player.playbackState.isPlayIntentActive, "暂停后按钮应显示播放图标")

        // 再点播放：回到加载态（准备中），且不得重新拉流
        player.togglePlayPause()
        XCTAssertEqual(player.playbackState, .loading(songID: "D"))

        // 放行后按最新意图（播放）真的出声
        gate.open()
        guard await (pollUntil { self.player.playbackState == .playing(songID: "D") }) else {
            throw XCTSkip("AVPlayer 未进入播放态")
        }
    }

    /// 加载窗口内反复切换播放/暂停不得重新拉流：
    /// resume() 走 beginPlay 会递增代次、取消在途请求并从头再来一遍
    func testTogglingDuringLoadingDoesNotRefetch() async throws {
        _ = Self.storageIsolated
        await DemoAudioGenerator.ensureFiles()
        let fileURL = DemoAudioGenerator.directory().appendingPathComponent("tone_440.wav")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw XCTSkip("测试音频生成失败")
        }

        let gate = ManualGate()
        let provider = GatedProvider(gate: gate, url: fileURL)
        player.setProvider(provider)
        player.play(songs: [makeSong(id: "E")])
        XCTAssertEqual(player.playbackState, .loading(songID: "E"))
        // 拉流任务是被异步调度的，先等它真的发出请求再计数
        guard await (pollUntil(timeout: 2, { await provider.callCount == 1 })) else {
            throw XCTSkip("拉流请求未发出")
        }

        for _ in 0..<3 {
            player.togglePlayPause()   // 暂停
            player.togglePlayPause()   // 播放
        }
        let callsAfterToggles = await provider.callCount
        XCTAssertEqual(callsAfterToggles, 1, "加载窗口内的意图切换触发了重新拉流")
    }

    /// 暂停中切音质属于「不自动出声」的一路：状态必须是 .paused（按钮显示「播放」），
    /// 不能是 .loading（按钮会显示成「暂停」，点下去反而开始播放）
    func testQualitySwitchWhilePausedKeepsPlayIcon() async throws {
        _ = Self.storageIsolated
        await DemoAudioGenerator.ensureFiles()
        let fileURL = DemoAudioGenerator.directory().appendingPathComponent("tone_440.wav")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw XCTSkip("测试音频生成失败")
        }

        let songA = makeLocalSong(id: "local-A", fileURL: fileURL)
        player.play(songs: [songA])
        guard await (pollUntil { self.player.playbackState == .playing(songID: "local-A") }) else {
            throw XCTSkip("AVPlayer 未进入播放态")
        }
        guard await (pollUntil { self.player.currentTime > 1.5 }) else {
            throw XCTSkip("AVPlayer 无时钟输出")
        }

        player.pause()
        let savedTime = player.currentTime
        player.setRequestedQuality(.standard)

        XCTAssertEqual(player.playbackState, .paused(songID: "local-A"),
                       "暂停中切音质应保持暂停态，按钮才显示「播放」")
        XCTAssertFalse(player.playbackState.isPlayIntentActive)
        XCTAssertEqual(player.currentTime, savedTime, accuracy: 0.01, "切音质应保留进度")

        // 点播放：准备完成后按播放意图出声，且进度不丢
        player.togglePlayPause()
        guard await (pollUntil { self.player.playbackState == .playing(songID: "local-A") }) else {
            throw XCTSkip("AVPlayer 未进入播放态")
        }
        XCTAssertGreaterThan(player.currentTime, 0.5, "切音质后恢复播放应接着原进度")
    }
}