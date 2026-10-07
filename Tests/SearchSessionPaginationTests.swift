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
        /// 这些页码的请求会挂起（直到被取消），用来制造「翻页在途」
        var hangPages: Set<Int> = []
        /// 这些页码的请求直接抛错
        var failingPages: Set<Int> = []
        /// 这些关键词的请求直接抛错（用于「新搜索失败」）
        var failingQueries: Set<String> = []

        init(totalPages: Int) { self.totalPages = totalPages }

        func search(query: String, type: SearchType, page: Int, limit: Int) async throws -> SearchResult {
            calls.append((type, page))
            if failingQueries.contains(query) { throw MusicError.networkUnavailable }
            if failingPages.contains(page) { throw MusicError.networkUnavailable }
            if hangPages.contains(page) {
                // 取消时抛 CancellationError → 走 catch 分支 → 被 Task.isCancelled 守卫挡下
                try await Task.sleep(for: .seconds(60))
            }
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

    // MARK: - 分页的失败与取消

    /// 翻页在途时离开搜索页，**页码必须回滚**。
    ///
    /// `loadMore()` 在发请求**之前**就同步把 `currentPage` 加了 1，而失败分支的
    /// `guard !Task.isCancelled ... else { return }` 会让取消路径跳过回滚。
    /// 于是：滚到第 2 页 → 在途时切走侧栏（`onDisappear` 调 `cancelInFlight`）
    /// → 回来再滚 → 直接请求**第 3 页**，31–60 条永久缺失且界面上毫无异常。
    func testCancelInFlightRollsBackInFlightPage() async {
        let provider = StubProvider(totalPages: 5)
        provider.hangPages = [2]
        let session = makeSession(provider)

        session.draftQuery = "test"
        session.submit(type: .song)
        await waitForSearch(session)
        XCTAssertEqual(session.currentPage, 1)

        session.loadMore()
        XCTAssertTrue(session.isLoadingMore, "翻页在途必须有独立的 loading 标志")
        XCTAssertEqual(session.currentPage, 2, "页码在发起请求前同步推进")
        // 让分页任务真的跑起来
        try? await Task.sleep(for: .milliseconds(30))

        session.cancelInFlight()

        XCTAssertFalse(session.isLoadingMore, "取消后转圈必须复位，否则回到页面永远卡在加载中")
        XCTAssertEqual(
            session.currentPage, 1,
            "在途翻页被取消必须回滚页码 —— 否则下次直接跳到第 3 页"
        )

        // 回到页面，再翻页必须请求第 2 页（而不是第 3 页）
        provider.hangPages = []
        session.loadMore()
        await waitForCalls(provider, expected: 3)
        XCTAssertEqual(provider.calls.last?.1, 2, "取消后再次翻页必须请求第 2 页")
    }

    /// 翻页失败：保留已有结果、回滚页码、给一条**独立**的分页错误，并可直接重试。
    func testPaginationFailureKeepsResultAndSurfacesError() async {
        let provider = StubProvider(totalPages: 5)
        provider.failingPages = [2]
        let session = makeSession(provider)

        session.draftQuery = "test"
        session.submit(type: .song)
        await waitForSearch(session)
        let before = session.result
        XCTAssertNotNil(before)

        session.loadMore()
        for _ in 0..<400 {
            if session.paginationError != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertNotNil(session.paginationError, "翻页失败原先只回滚页码、不设任何错误 —— 点「加载更多」像没反应")
        XCTAssertNil(session.errorMessage, "分页错误不该污染整页搜索的错误态")
        XCTAssertNotNil(session.result, "分页失败必须保留已有结果，不能整个换成错误页")
        XCTAssertEqual(session.result?.songs.count, before?.songs.count)
        XCTAssertEqual(session.currentPage, 1, "失败要回滚页码")
        XCTAssertFalse(session.isLoadingMore)

        // 直接重试同一页
        provider.failingPages = []
        session.loadMore()
        await waitForCalls(provider, expected: 3)
        XCTAssertNil(session.paginationError, "重试成功后错误必须清掉")
        XCTAssertEqual(session.result?.songs.count, (before?.songs.count ?? 0) + 1)
    }

    /// 新搜索失败时不得留下上一次的结果。
    ///
    /// `activeQuery`/`activeType` 已经是新查询，而 `result` 还是旧查询的 ——
    /// 此时 `displayType` 跟着新类型走（用 B 的列表形态渲染 A 的数据），
    /// 且 A 的 `hasMore` 若为 true，`loadMore()` 会把 **B 的第 2 页追加进 A 的列表**。
    func testFailedNewSearchDoesNotLeaveStaleResult() async {
        let provider = StubProvider(totalPages: 3)
        let session = makeSession(provider)

        session.draftQuery = "A"
        session.submit(type: .song)
        await waitForSearch(session)
        XCTAssertNotNil(session.result, "前置：A 必须有结果")
        let callsAfterA = provider.calls.count

        provider.failingQueries = ["B"]
        session.draftQuery = "B"
        session.submit(type: .song)
        await waitForSearch(session)

        XCTAssertNotNil(session.errorMessage, "失败要有提示")
        XCTAssertNil(session.result, "失败的查询不得留下上一次的结果集")
        XCTAssertFalse(session.isLoading)

        // 失败那次搜索本身也发了一次请求（A 一次 + B 一次）
        let callsAfterFailure = provider.calls.count
        XCTAssertEqual(callsAfterFailure, callsAfterA + 1)

        // 结果都没了，分页自然也不该发起
        session.loadMore()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(provider.calls.count, callsAfterFailure, "失败后不该还能翻页")
    }
}
