import XCTest

/// 搜索会话：四种类型的分页、状态机不变量。
///
/// 重点是上一轮复核发现的两个 bug 的回归防护：
/// 1. 非单曲类型永远停在第一页（`loadMore` 只追加 songs）
/// 2. `SearchResult.isEmpty` 只看 songs，导致「有专辑结果但当前是单曲类型」显示空白
@MainActor
final class SearchSessionPaginationTests: XCTestCase {

    // MARK: - 桩 Provider

    /// 记录收到的分页请求，并按类型返回可辨识的条目
    private final class StubProvider: MusicProvider, @unchecked Sendable {
        let identifier = "stub"
        let displayName = "桩"
        /// 每次 search 记一笔 (type, page)
        private(set) var calls: [(SearchType, Int)] = []
        let totalPages: Int

        init(totalPages: Int) { self.totalPages = totalPages }

        func search(query: String, type: SearchType, page: Int, limit: Int) async throws -> SearchResult {
            calls.append((type, page))
            let hasMore = page < totalPages
            func id(_ page: Int) -> String { "\(type.rawValue)-\(page)" }
            switch type {
            case .song:
                return SearchResult(
                    songs: [Song(id: id(page), title: "歌\(page)", artists: [], source: .netease)],
                    totalCount: totalPages, hasMore: hasMore
                )
            case .artist:
                return SearchResult(
                    artists: [Artist(id: id(page), name: "歌手\(page)")],
                    totalCount: totalPages, hasMore: hasMore
                )
            case .album:
                return SearchResult(
                    albums: [Album(id: id(page), name: "专辑\(page)")],
                    totalCount: totalPages, hasMore: hasMore
                )
            case .playlist:
                return SearchResult(
                    playlists: [Playlist(id: id(page), name: "歌单\(page)", source: .netease)],
                    totalCount: totalPages, hasMore: hasMore
                )
            }
        }

        // 以下为协议要求的其余方法，本测试用不到
        func fetchQRCodeKey() async throws -> String { "" }
        func fetchQRCodeImage(key: String) async throws -> URL { URL(string: "https://x")! }
        func checkQRCodeStatus(key: String) async throws -> QRLoginStatus { .waitingScan }
        func logout() async throws {}
        func fetchAccountInfo() async throws -> AccountInfo? { nil }
        func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail {
            PlaylistDetail(playlist: Playlist(id: id, name: "", source: .netease), tracks: [], totalTrackCount: 0)
        }
        func fetchPlaylistTracks(id: String, page: Int, limit: Int) async throws -> [Song] { [] }
        func fetchAlbumDetail(id: String) async throws -> PlaylistDetail {
            PlaylistDetail(playlist: Playlist(id: id, name: "", source: .netease), tracks: [], totalTrackCount: 0)
        }
        func fetchArtistDetail(id: String) async throws -> ArtistDetail {
            ArtistDetail(artist: Artist(id: id, name: ""), hotSongs: [], albums: [])
        }
        func fetchPlayableURL(songID: String, quality: AudioQuality.QualityLevel) async throws -> PlayableURL {
            throw MusicError.noPlayableURL
        }
        func fetchLyrics(songID: String) async throws -> LyricResult {
            LyricResult(lines: [], hasWordTiming: false, isPureMusic: true)
        }
        func fetchUserPlaylists() async throws -> [Playlist] { [] }
        func fetchLikedSongs() async throws -> [Song] { [] }
        func likeSong(id: String, like: Bool) async throws {}
        func fetchRecommendPlaylists() async throws -> [Playlist] { [] }
        func fetchDailyRecommendSongs() async throws -> [Song] { [] }
    }

    private func makeSession(_ provider: StubProvider) -> SearchSession {
        SearchSession(provider: provider)
    }

    /// 等到 session 不再 loading
    private func waitForSearch(_ session: SearchSession) async {
        for _ in 0..<200 {
            if !session.isLoading { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("等待搜索超时")
    }

    /// 等到指定页的请求真的发出。
    ///
    /// **不能**用 `session.currentPage` 判断：`loadMore()` 里
    /// `currentPage = page` 是**同步**执行的，Task 还没跑。
    /// 早期版本就踩了这个坑，表现为「分页测试偶发只拿到 1 页」。
    private func waitForCalls(_ provider: StubProvider, expected: Int) async {
        for _ in 0..<400 {
            if provider.calls.count >= expected { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("等待第 \(expected) 次请求超时，实际只发了 \(provider.calls.count) 次")
    }

    // MARK: - 四种类型都能分页

    func testAllFourTypesPaginate() async {
        for type in SearchType.allCases {
            let provider = StubProvider(totalPages: 3)
            let session = makeSession(provider)
            session.draftQuery = "周杰伦"
            session.submit(type: type)
            await waitForSearch(session)
            XCTAssertEqual(provider.calls.count, 1, "\(type.rawValue) 首搜未发出")

            session.loadMore()
            await waitForCalls(provider, expected: 2)
            XCTAssertEqual(provider.calls.count, 2, "\(type.rawValue) 没有请求第 2 页")

            guard let result = session.result else {
                XCTFail("\(type.rawValue) 没有结果集")
                continue
            }
            switch type {
            case .song: XCTAssertEqual(result.songs.count, 2, "单曲应累计 2 条")
            case .artist: XCTAssertEqual(result.artists.count, 2, "歌手应累计 2 条")
            case .album: XCTAssertEqual(result.albums.count, 2, "专辑应累计 2 条")
            case .playlist: XCTAssertEqual(result.playlists.count, 2, "歌单应累计 2 条")
            }
        }
    }

    /// 早期实现只 append songs，于是另外三种类型永远停在 30 条
    func testNonSongTypesWereTheRegression() async {
        let provider = StubProvider(totalPages: 3)
        let session = makeSession(provider)
        session.draftQuery = "test"
        session.submit(type: .album)
        await waitForSearch(session)

        session.loadMore()
        await waitForCalls(provider, expected: 2)

        XCTAssertEqual(session.result?.albums.count, 2)
        XCTAssertEqual(session.result?.albums.map(\.id), ["专辑-1", "专辑-2"])
        // 其它类型的数组不应被污染
        XCTAssertTrue(session.result?.songs.isEmpty == true)
        XCTAssertTrue(session.result?.artists.isEmpty == true)
        XCTAssertTrue(session.result?.playlists.isEmpty == true)
    }

    /// hasMore 为 false 后不再翻页
    func testNoPaginationWhenHasMoreIsFalse() async {
        let provider = StubProvider(totalPages: 1)
        let session = makeSession(provider)
        session.draftQuery = "test"
        session.submit(type: .song)
        await waitForSearch(session)

        XCTAssertFalse(session.result?.hasMore ?? true)
        session.loadMore()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(provider.calls.count, 1, "hasMore=false 时不应再请求")
    }

    /// 分页必须读已提交的那次查询，不能读草稿
    func testPaginationUsesCommittedQueryNotDraft() async {
        let provider = StubProvider(totalPages: 3)
        let session = makeSession(provider)
        session.draftQuery = "原始词"
        session.submit(type: .song)
        await waitForSearch(session)

        // 用户改了输入框但没按回车
        session.draftQuery = "改过的词"
        session.loadMore()
        await waitForCalls(provider, expected: 2)

        // 第二次请求的仍是「原始词」的第 2 页
        XCTAssertEqual(provider.calls.count, 2)
        XCTAssertEqual(session.activeQuery, "原始词")
        XCTAssertEqual(session.result?.songs.count, 2)
    }

    /// 分页锁：上一次分页还在途时，再点「加载更多」不应该再发一次请求，
    /// 否则同一页会被请求两遍并追加两份。
    func testPaginationLockDropsConcurrentSecondCall() async {
        let provider = StubProvider(totalPages: 5)
        let session = makeSession(provider)
        session.draftQuery = "test"
        session.submit(type: .song)
        await waitForSearch(session)

        // 第一次分页在途时立刻再点一次
        session.loadMore()
        session.loadMore()
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(provider.calls.count, 2, "并发第二次 loadMore 应被丢弃")
        XCTAssertEqual(provider.calls.map(\.1), [1, 2], "不应重复请求第 2 页")
        XCTAssertEqual(session.result?.songs.count, 2, "不应追加重复条目")

        // 等这次分页落地后，下一次翻页才应继续到第 3 页
        session.loadMore()
        await waitForCalls(provider, expected: 3)
        XCTAssertEqual(provider.calls.map(\.1).sorted(), [1, 2, 3])
        XCTAssertEqual(session.result?.songs.count, 3)
    }

    // MARK: - SearchResult.isEmpty

    /// 只有四种结果全空才算「没搜到」
    func testIsEmptyRequiresAllFourEmpty() {
        var result = SearchResult()
        XCTAssertTrue(result.isEmpty)

        result.albums = [Album(id: "1", name: "A")]
        XCTAssertFalse(result.isEmpty, "有专辑结果就不该判空")

        result = SearchResult()
        result.artists = [Artist(id: "1", name: "A")]
        XCTAssertFalse(result.isEmpty)

        result = SearchResult()
        result.playlists = [Playlist(id: "1", name: "P", source: .netease)]
        XCTAssertFalse(result.isEmpty)

        result = SearchResult()
        result.songs = [Song(id: "1", title: "S", artists: [], source: .netease)]
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - 状态机不变量

    /// 键盘清空后切类型，必须重置结果（否则显示上一个关键词的结果）
    func testResetClearsResultAndBlocksPagination() async {
        let provider = StubProvider(totalPages: 5)
        let session = makeSession(provider)
        session.draftQuery = "test"
        session.submit(type: .song)
        await waitForSearch(session)
        XCTAssertNotNil(session.result)

        session.reset()
        XCTAssertNil(session.result, "reset 后不该残留结果")
        XCTAssertEqual(session.draftQuery, "")
        XCTAssertFalse(session.hasActiveQuery)

        session.loadMore()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(provider.calls.count, 1, "reset 后不应再翻页")
    }

    /// 新搜索作废旧的在途请求
    func testNewSearchInvalidatesPreviousResult() async {
        let provider = StubProvider(totalPages: 3)
        let session = makeSession(provider)
        session.draftQuery = "A"
        session.submit(type: .song)
        await waitForSearch(session)

        session.draftQuery = "B"
        session.submit(type: .artist)
        await waitForSearch(session)

        XCTAssertEqual(session.activeQuery, "B")
        XCTAssertEqual(session.displayType, .artist)
        XCTAssertTrue(session.result?.songs.isEmpty == true)
        XCTAssertEqual(session.result?.artists.count, 1)
    }

    /// 结果类型跟随「已提交的类型」而不是 Picker 当前值
    func testDisplayTypeFollowsCommittedQuery() async {
        let session = makeSession(StubProvider(totalPages: 1))
        XCTAssertEqual(session.displayType, .song, "没有查询时默认单曲")

        session.draftQuery = "test"
        session.submit(type: .album)
        await waitForSearch(session)
        XCTAssertEqual(session.displayType, .album)

        // 再提一次单曲查询，displayType 必须跟着变
        session.submit(type: .song)
        await waitForSearch(session)
        XCTAssertEqual(session.displayType, .song)
    }
}
