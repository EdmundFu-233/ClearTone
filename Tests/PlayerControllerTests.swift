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

    init(gate: ManualGate, url: URL) {
        self.gate = gate
        self.url = url
    }

    func fetchPlayableURL(songID: String, quality: AudioQuality.QualityLevel) async throws -> PlayableURL {
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
    private static let storageIsolated: Void = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClearToneTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("CLEARTONE_TEST_STORAGE_DIR", dir.path, 1)
    }()

    private var player: PlayerController { PlayerController.shared }

    private func makeSong(id: String, source: SongSource = .netease) -> Song {
        Song(id: id, title: "Song \(id)", artists: [Artist(id: "a1", name: "Artist")], source: source)
    }

    private func pollUntil(timeout: TimeInterval = 5, _ condition: @MainActor @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
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
        await DemoProvider.ensureDemoAudio()
        let fileURL = DemoProvider.demoAudioDirectory().appendingPathComponent("tone_440.wav")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw XCTSkip("演示音频生成失败")
        }

        // A：真实本地演示音频（.demo -> 内部 demoProvider），等它实际出声走表
        let songA = Song(id: "demo-1", title: "A", artists: [Artist(id: "a1", name: "Artist")],
                         duration: 30, source: .demo)
        player.play(songs: [songA])

        guard await (pollUntil { self.player.playbackState == .playing(songID: "demo-1") }) else {
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
        await DemoProvider.ensureDemoAudio()
        let fileURL = DemoProvider.demoAudioDirectory().appendingPathComponent("tone_440.wav")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw XCTSkip("演示音频生成失败")
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
}