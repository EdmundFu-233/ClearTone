import XCTest
@testable import ClearTone

/// `ArtistProfileSession` 的分页与代次隔离测试。
///
/// 三条不变量（见 `Core/Artist/ArtistProfileSession.swift` 顶部）：
/// 1. 换歌手 / 登录态变化后，迟到响应不得写进新歌手的页面；
/// 2. 分页锁：一次滚到底不能连发多页相同 offset；
/// 3. 翻页失败**不能**清空已加载的内容。
///
/// 这些都是异步边界上的行为，写在 `Features/` 的视图里就测不到
/// （`project.yml` 把 `Features/**` 排除在单测 target 外），
/// 所以逻辑被拆到了 `Core/Artist/`。
@MainActor
final class ArtistProfileSessionTests: XCTestCase {

    // MARK: - 复位

    /// 换歌手必须清空全部内容：留着上一个歌手的歌单比显示空态更糟。
    func testSwitchToArtistClearsEverything() async {
        let provider = StubArtistProvider()
        provider.songPages = [ArtistSongPage(songs: [.fixture(id: "s1")], total: 1, hasMore: false)]
        let session = ArtistProfileSession(artistID: "1", provider: provider)
        await session.loadProfile()
        await session.loadSongs()
        XCTAssertFalse(session.songs.isEmpty)

        session.switchTo(artistID: "2")

        XCTAssertEqual(session.artistID, "2")
        XCTAssertNil(session.profile)
        XCTAssertTrue(session.songs.isEmpty)
        XCTAssertTrue(session.albums.isEmpty)
        XCTAssertTrue(session.mvs.isEmpty)
        XCTAssertNil(session.intro)
        XCTAssertTrue(session.similarArtists.isEmpty)
    }

    /// 切换到同一个歌手是空操作 —— 否则点两次同一张卡片会白白重载。
    ///
    /// **同一个歌手 + 登录态变化**要走 `reloadForDataContext()` 而不是
    /// `switchTo`：后者被 `guard newID != artistID` 短路成什么都不做。
    func testSwitchToSameArtistIsNoOpButDataContextReloadClears() async {
        let session = ArtistProfileSession(artistID: "1", provider: StubArtistProvider())
        await session.loadProfile()
        XCTAssertNotNil(session.profile)

        session.switchTo(artistID: "1")
        XCTAssertNotNil(session.profile)

        session.reloadForDataContext()
        XCTAssertNil(session.profile)
        XCTAssertEqual(session.artistID, "1")
    }

    // MARK: - 分页

    /// offset 必须由**已加载条数**推导，页大小固定。
    func testLoadMoreSongsAdvancesOffsetByLoadedCount() async {
        let provider = StubArtistProvider()
        provider.songPages = [
            ArtistSongPage(songs: (0..<3).map { Song.fixture(id: "s\($0)") },
                           total: 9, hasMore: true),
            ArtistSongPage(songs: (3..<6).map { Song.fixture(id: "s\($0)") },
                           total: 9, hasMore: false),
        ]
        let session = ArtistProfileSession(artistID: "1", provider: provider)

        await session.loadSongs()
        XCTAssertEqual(provider.requestedSongOffsets, [0])
        XCTAssertEqual(session.songs.count, 3)
        XCTAssertEqual(session.songsTotal, 9)

        await session.loadMoreSongs()
        XCTAssertEqual(provider.requestedSongOffsets, [0, 3])
        XCTAssertEqual(session.songs.count, 6)
        XCTAssertEqual(session.songs.map(\.id), ["s0", "s1", "s2", "s3", "s4", "s5"])
    }

    /// `hasMore` 为 false 之后不该再发请求。
    func testNoMorePagesStopsLoading() async {
        let provider = StubArtistProvider()
        provider.songPages = [ArtistSongPage(songs: [.fixture(id: "s0")], total: 1, hasMore: false)]
        let session = ArtistProfileSession(artistID: "1", provider: provider)

        await session.loadSongs()
        XCTAssertFalse(session.canLoadMoreSongs)

        await session.loadMoreSongs()
        XCTAssertEqual(provider.requestedSongOffsets, [0])
    }

    /// 空列表时不该触发翻页（否则会对着 offset 0 无限循环）
    func testEmptyListDoesNotLoadMore() async {
        let provider = StubArtistProvider()
        provider.songPages = [ArtistSongPage(songs: [], total: 0, hasMore: true)]
        let session = ArtistProfileSession(artistID: "1", provider: provider)

        await session.loadSongs()
        XCTAssertFalse(session.canLoadMoreSongs)
        await session.loadMoreSongs()
        XCTAssertEqual(provider.requestedSongOffsets, [0])
    }

    /// 翻页失败必须**保留已加载内容**，只留错误提示。
    /// 已加载的 500 首不该因为第 11 页失败就没了。
    func testLoadMoreFailureKeepsExistingSongs() async {
        let provider = StubArtistProvider()
        provider.songPages = [ArtistSongPage(songs: [.fixture(id: "s0")], total: 99, hasMore: true)]
        let session = ArtistProfileSession(artistID: "1", provider: provider)
        await session.loadSongs()

        provider.failNextSongPage = true
        await session.loadMoreSongs()

        XCTAssertEqual(session.songs.map(\.id), ["s0"])
        XCTAssertNotNil(session.songsError)
        // 仍然允许重试
        XCTAssertTrue(session.canLoadMoreSongs)
    }

    /// 首屏失败才有错误态；已经有内容时不再显示整页错误。
    func testFirstPageFailureSetsError() async {
        let provider = StubArtistProvider()
        provider.failProfile = true
        let session = ArtistProfileSession(artistID: "1", provider: provider)

        await session.loadProfile()
        XCTAssertNotNil(session.profileError)
        XCTAssertNil(session.profile)
    }

    /// 迟到页与已加载内容有重叠时按 id 去重（网易云偶尔会插歌）
    func testDuplicateSongsAcrossPagesAreDeduplicated() async {
        let provider = StubArtistProvider()
        provider.songPages = [
            ArtistSongPage(songs: [.fixture(id: "a"), .fixture(id: "b")], total: 3, hasMore: true),
            // 第二页把 a 又带回来了
            ArtistSongPage(songs: [.fixture(id: "a"), .fixture(id: "c")], total: 3, hasMore: false),
        ]
        let session = ArtistProfileSession(artistID: "1", provider: provider)

        await session.loadSongs()
        await session.loadMoreSongs()
        XCTAssertEqual(session.songs.map(\.id), ["a", "b", "c"])
    }

    // MARK: - 代次隔离

    /// 换歌手后，**旧歌手**的在途响应不得写进新页面。
    /// 这是本页最容易出的 bug：点 A 歌手 → 立刻点 B 歌手 → A 的简介填进 B 的页。
    func testLateResponseFromPreviousArtistIsDiscarded() async {
        let provider = StubArtistProvider()
        provider.songGate = ControlledGate()
        let session = ArtistProfileSession(artistID: "1", provider: provider)

        // 歌手 1 的歌曲首屏请求挂在闸门后面
        let firstPage = Task { await session.loadSongs() }
        await provider.songGate?.waitUntilHeld()

        session.switchTo(artistID: "2")
        await provider.songGate?.release()

        await firstPage.value
        // 旧歌手的那一批歌曲没有落地
        XCTAssertTrue(session.songs.isEmpty)
        XCTAssertNil(session.songsError)
    }

    /// 换歌手只改状态、不发请求 —— 加载由调用方显式驱动。
    /// 早期 `switchTo` 内部自带 `loadProfile`，于是「同一个歌手换了账号」
    /// 这条路径被 `guard` 短路成什么都不重载。
    func testSwitchToArtistDoesNotStartLoadingOnItsOwn() async {
        let provider = StubArtistProvider()
        let session = ArtistProfileSession(artistID: "1", provider: provider)
        session.switchTo(artistID: "2")
        XCTAssertEqual(session.artistID, "2")
        XCTAssertNil(session.profile)
        // 调用方负责加载
        await session.loadProfile()
        XCTAssertNotNil(session.profile)
    }

    /// 换歌手后，旧的**专辑页**也不能落地
    func testLateAlbumPageFromPreviousArtistIsDiscarded() async {
        let provider = StubArtistProvider()
        provider.albumGate = ControlledGate()
        let session = ArtistProfileSession(artistID: "1", provider: provider)

        let task = Task { await session.loadAlbums() }
        await provider.albumGate?.waitUntilHeld()

        session.switchTo(artistID: "2")
        await provider.albumGate?.release()
        await task.value

        XCTAssertTrue(session.albums.isEmpty)
        // 也不能把 followed 写进来 —— 关注状态是跟着歌手的
        XCTAssertNil(session.isFollowed)
    }

    // MARK: - 关注状态

    /// 关注状态由 `/artist/album` 响应里回带的 `followed` 初始化。
    /// 早期 `isSubscribed` 是 `Bool?` 且从不赋值，于是永远显示「未关注」。
    func testFollowedInitializesFromAlbumPage() async {
        let provider = StubArtistProvider()
        provider.albumPages = [
            ArtistAlbumPage(albums: [.init(id: "1", name: "A")], isFollowed: true, hasMore: false)
        ]
        let session = ArtistProfileSession(artistID: "1", provider: provider)
        await session.loadAlbums()
        XCTAssertEqual(session.isFollowed, true)
    }

    /// 后续页如果没带 `followed`，不能把第一页得到的值抹成 nil
    func testLaterPagesDoNotClearFollowedState() async {
        let provider = StubArtistProvider()
        provider.albumPages = [
            ArtistAlbumPage(albums: [.init(id: "1", name: "A")], isFollowed: true, hasMore: true),
            ArtistAlbumPage(albums: [.init(id: "2", name: "B")], isFollowed: nil, hasMore: false),
        ]
        let session = ArtistProfileSession(artistID: "1", provider: provider)
        await session.loadAlbums()
        await session.loadMoreAlbums()
        XCTAssertEqual(session.isFollowed, true)
    }

    /// 写操作后回写，避免下次点按钮时初值还是旧的
    func testSetFollowedUpdatesLocalState() {
        let session = ArtistProfileSession(artistID: "1", provider: StubArtistProvider())
        session.setFollowed(true)
        XCTAssertEqual(session.isFollowed, true)
    }

    // MARK: - 相似歌手

    /// 相似列表会把自己也带回来（实测第一个就是自己），要过滤掉
    func testSimilarArtistsExcludeSelf() async {
        let provider = StubArtistProvider()
        provider.similarArtists = [
            .init(id: "1", name: "自己"),
            .init(id: "2", name: "相似甲"),
            .init(id: "3", name: "相似乙"),
        ]
        let session = ArtistProfileSession(artistID: "1", provider: provider)
        await session.loadHighlights()
        XCTAssertEqual(session.similarArtists.map(\.id), ["2", "3"])
    }

    /// 热门/相似失败静默降级 —— 它们是「锦上添花」，不该让整页报错
    func testHighlightsFailureIsSilent() async {
        let provider = StubArtistProvider()
        provider.failHighlights = true
        let session = ArtistProfileSession(artistID: "1", provider: provider)

        await session.loadHighlights()
        XCTAssertTrue(session.hotSongs.isEmpty)
        XCTAssertTrue(session.similarArtists.isEmpty)
        XCTAssertFalse(session.isLoadingHighlights)
        // 关键：没有把错误冒泡成 profileError
        XCTAssertNil(session.profileError)
    }
}

// MARK: - 夹具

extension ArtistProfile {
    static func fixture(isFollowed: Bool? = nil) -> ArtistProfile {
        ArtistProfile(
            artist: Artist(id: "1", name: "测试歌手"),
            briefDescription: "简介",
            albumCount: 2, songCount: 10, mvCount: 1,
            isFollowed: isFollowed
        )
    }
}

extension Song {
    static func fixture(id: String) -> Song {
        Song(id: id, title: "歌\(id)", artists: [.init(id: "1", name: "测试歌手")], source: .netease)
    }
}

/// 可控闸门：让某个请求挂在中间，用来构造「在途请求」。
///
/// 做成 `actor` 而不是信号量：Swift 6 里 `DispatchSemaphore.wait()`、
/// `NSLock.lock()` 在 async 上下文都不可用（编译器直接拒），
/// 而闸门必然要跨 `await` 使用。轮询 `Task.yield()` 而不是加锁，
/// 也没有线程安全问题。
actor ControlledGate {
    private var isHeld = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    /// 在桩里 await 调用：挂起直到有人 `release()`
    func hold() async {
        guard !isReleased else { return }
        isHeld = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
    }

    /// 等到请求真的挂上了再继续
    func waitUntilHeld() async {
        while !isHeld { await Task.yield() }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
