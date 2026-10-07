import XCTest
@testable import ClearTone

private actor MobileFixtureProvider: MobileLoginProvider {
    let identifier = "mobile-fixture"
    let displayName = "mobile-fixture"
    var accountGate: ManualGate?
    var trackGate: ManualGate?
    var failAccount = false
    var failPage = false
    private(set) var accountCalls = 0
    private(set) var pages: [Int] = []
    private var trackCount = 250
    func setTrackCount(_ value: Int) { trackCount = value }
    func holdAccount(_ gate: ManualGate) { accountGate = gate }
    func holdTracks(_ gate: ManualGate) { trackGate = gate }
    func setFailure(account: Bool = false, page: Bool = false) { failAccount = account; failPage = page }
    func fetchQRCodeKey() async throws -> String { "fixture-key" }
    func fetchQRCodeImage(key: String) async throws -> URL { try NeteaseMobileRoute.qrURL(key: key) }
    func checkQRCodeStatus(key: String) async throws -> QRLoginStatus { .expired }
    func logout() async throws {}
    func fetchAccountInfo() async throws -> AccountInfo? { nil }
    func fetchAccountInfo(cookie: String) async throws -> AccountInfo? {
        accountCalls += 1
        let gate = accountGate; accountGate = nil
        if let gate { await gate.wait() }
        if failAccount { throw MusicError.notLoggedIn }
        return AccountInfo(userID: cookie.contains("new") ? "new" : "old", nickname: "测试账号")
    }
    func search(query: String, type: SearchType, page: Int, limit: Int) async throws -> SearchResult { SearchResult() }
    func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail {
        PlaylistDetail(playlist: Playlist(id: id, name: id, source: .netease), tracks: [song(id, 0)], totalTrackCount: trackCount)
    }
    func fetchPlaylistTracks(id: String, page: Int, limit: Int) async throws -> [Song] {
        pages.append(page)
        let gate = trackGate; trackGate = nil
        if let gate { await gate.wait() }
        if failPage { failPage = false; throw MusicError.networkUnavailable }
        let count = page < 3 ? 100 : 50
        return (0..<count).map { song(id, (page - 1) * limit + $0) }
    }
    private func song(_ id: String, _ index: Int) -> Song { Song(id: "\(id)-\(index)", title: "track", artists: [], source: .netease) }
    private var duplicateAlbumTracks = false
    private var duplicateArtistSongs = false
    func setDuplicateAlbumTracks(_ value: Bool) { duplicateAlbumTracks = value }
    func setDuplicateArtistSongs(_ value: Bool) { duplicateArtistSongs = value }
    func fetchAlbumDetail(id: String) async throws -> PlaylistDetail {
        let tracks = duplicateAlbumTracks ? [song(id, 0), song(id, 0)] : [song(id, 0)]
        return PlaylistDetail(playlist: Playlist(id: id, name: id, source: .netease),
                              tracks: tracks, totalTrackCount: trackCount)
    }
    func fetchArtistDetail(id: String) async throws -> ArtistDetail {
        let hot = duplicateArtistSongs ? [song(id, 0), song(id, 0)] : [song(id, 0)]
        return ArtistDetail(artist: Artist(id: id, name: id), hotSongs: hot, albums: [])
    }
    func fetchPlayableURL(songID: String, quality: AudioQuality.QualityLevel) async throws -> PlayableURL { throw MusicError.noPlayableURL }
    func fetchLyrics(songID: String) async throws -> LyricResult { LyricResult(lines: [], hasWordTiming: false, isPureMusic: true) }
    func fetchUserPlaylists() async throws -> [Playlist] { [] }
    func fetchLikedSongs() async throws -> [Song] { [] }
    func likeSong(id: String, like: Bool) async throws {}
    func fetchRecommendPlaylists() async throws -> [Playlist] { [] }
    func fetchDailyRecommendSongs() async throws -> [Song] { [] }
}

@MainActor
final class MobileSessionsTests: XCTestCase {
    func testLoginValidatesThenSavesNormalizedCookie() async {
        let provider = MobileFixtureProvider()
        var saved: [(String, String)] = []
        let session = MobileLoginSession(provider: provider) { saved.append(($0, $1)) }
        await session.login(cookie: "MUSIC_U=new; Path=/; HttpOnly")
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.0, "MUSIC_U=new")
        XCTAssertEqual(session.account?.userID, "new")
        XCTAssertFalse(session.isLoading)
    }
    func testCancelledLoginDoesNotPersistLateCredentials() async {
        let provider = MobileFixtureProvider()
        let gate = ManualGate()
        await provider.holdAccount(gate)
        var saved = false
        let session = MobileLoginSession(provider: provider) { _, _ in saved = true }
        let task = Task { await session.login(cookie: "MUSIC_U=old") }
        while await provider.accountCalls == 0 { await Task.yield() }
        session.cancel(); gate.open(); await task.value
        XCTAssertFalse(saved)
        XCTAssertNil(session.account)
        XCTAssertFalse(session.isLoading)
    }
    func testOldLoginCannotOverwriteNewAccount() async {
        let provider = MobileFixtureProvider()
        let gate = ManualGate()
        await provider.holdAccount(gate)
        var savedIDs: [String] = []
        let session = MobileLoginSession(provider: provider) { _, id in savedIDs.append(id) }
        let old = Task { await session.login(cookie: "MUSIC_U=old") }
        while await provider.accountCalls == 0 { await Task.yield() }
        await session.login(cookie: "MUSIC_U=new")
        gate.open(); await old.value
        XCTAssertEqual(savedIDs, ["new"])
        XCTAssertEqual(session.account?.userID, "new")
    }
    func testRejectedLoginNeverSavesCredentials() async {
        let provider = MobileFixtureProvider()
        await provider.setFailure(account: true)
        var saved = false
        let session = MobileLoginSession(provider: provider) { _, _ in saved = true }
        await session.login(cookie: "MUSIC_U=old")
        XCTAssertFalse(saved)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertNil(session.account)
    }
    func testExpiredQRCodeStopsPollingWithoutSaving() async {
        let provider = MobileFixtureProvider()
        var saved = false
        let session = MobileLoginSession(provider: provider) { _, _ in saved = true }
        await session.poll()
        XCTAssertFalse(saved)
        XCTAssertNil(session.key)
        XCTAssertFalse(session.isLoading)
        XCTAssertTrue(session.status.contains("过期"))
    }
    func testPlaylistSeedIsReplacedAndAllPagesLoad() async {
        let provider = MobileFixtureProvider()
        let session = MobileCollectionSession(provider: provider)
        await session.load(.playlist("A"))
        XCTAssertEqual(session.songs.count, 100)
        XCTAssertEqual(Set(session.songs.map(\.id)).count, 100)
        await session.loadMore(); await session.loadMore()
        XCTAssertEqual(session.songs.count, 250)
        XCTAssertFalse(session.hasMore)
        let pages = await provider.pages
        XCTAssertEqual(pages, [1, 2, 3])
    }
    func testPageFailurePreservesSongsAndRetriesSamePage() async {
        let provider = MobileFixtureProvider()
        let session = MobileCollectionSession(provider: provider)
        await session.load(.playlist("A"))
        await provider.setFailure(page: true)
        await session.loadMore()
        XCTAssertEqual(session.songs.count, 100)
        XCTAssertNotNil(session.errorMessage)
        await session.loadMore()
        XCTAssertEqual(session.songs.count, 200)
        XCTAssertNil(session.errorMessage)
        let pages = await provider.pages
        XCTAssertEqual(pages, [1, 2, 2])
    }
    func testLatePlaylistCannotOverwriteNewDetail() async {
        let provider = MobileFixtureProvider()
        let gate = ManualGate()
        await provider.holdTracks(gate)
        let session = MobileCollectionSession(provider: provider)
        let old = Task { await session.load(.playlist("A")) }
        while await provider.pages.isEmpty { await Task.yield() }
        await session.load(.playlist("B"))
        gate.open(); await old.value
        XCTAssertEqual(session.title, "B")
        XCTAssertTrue(session.songs.allSatisfy { $0.id.hasPrefix("B-") })
        XCTAssertFalse(session.isLoading)
    }
    func testPageLockPreventsConcurrentDuplicateRequests() async {
        let provider = MobileFixtureProvider()
        let session = MobileCollectionSession(provider: provider)
        await session.load(.playlist("A"))
        let gate = ManualGate()
        await provider.holdTracks(gate)
        let first = Task { await session.loadMore() }
        while await provider.pages.count < 2 { await Task.yield() }
        await session.loadMore()
        gate.open(); await first.value
        let pages = await provider.pages
        XCTAssertEqual(pages, [1, 2])
        XCTAssertEqual(session.songs.count, 200)
    }

    /// `trackCount` 与 `trackIds` 都缺席时 `total` 会是 0。
    /// 早先的 `已加载 < total` 在这种情况下恒 false —— 200 首的歌单
    /// 只显示第一页的 100 首，而且没有任何报错。
    func testUnknownTrackCountStillPaginatesUntilShortPage() async {
        let provider = MobileFixtureProvider()
        await provider.setTrackCount(0)
        let session = MobileCollectionSession(provider: provider)
        await session.load(.playlist("A"))
        XCTAssertTrue(session.hasMore, "总数缺席时不能把分页判死")
        await session.loadMore()
        XCTAssertTrue(session.hasMore)
        await session.loadMore()   // 第 3 页只有 50 条 → 到底
        XCTAssertFalse(session.hasMore)
        XCTAssertEqual(session.songs.count, 250)
    }

    /// 专辑/歌手分支原先直接 `songs = detail.tracks` 没过去重。
    /// 上游返回重复 id 时 SwiftUI 的 `ForEach` 会因为 Identifiable 重复而崩溃。
    func testAlbumAndArtistListsAreDeduplicated() async {
        let provider = MobileFixtureProvider()
        let session = MobileCollectionSession(provider: provider)
        await provider.setDuplicateAlbumTracks(true)
        await session.load(.album("A"))
        XCTAssertEqual(session.songs.count, 1)
        await provider.setDuplicateArtistSongs(true)
        await session.load(.artist("B"))
        XCTAssertEqual(session.songs.count, 1)
    }
}
