import XCTest
import Foundation

// MARK: - 测试替身

/// 记录每次 search 的参数，并可按 query 挂门闩（控制回包时机）/ 指定前 N 次失败
actor RecordingSearchProvider: MusicProvider {
    struct Call: Equatable, Sendable {
        let query: String
        let type: SearchType
        let page: Int
    }

    let identifier: String
    let displayName: String

    private(set) var calls: [Call] = []
    private var gates: [String: ManualGate] = [:]
    private var failuresLeft: [String: Int] = [:]

    init(identifier: String = "recording-test") {
        self.identifier = identifier
        self.displayName = identifier
    }

    /// 让该 query 的下一次 search 挂起，直到 `gate.open()`
    func setGate(_ gate: ManualGate, forQuery query: String) {
        gates[query] = gate
    }

    /// 该 query 的前 `count` 次 search 抛错
    func setFailures(_ count: Int, forQuery query: String) {
        failuresLeft[query] = count
    }

    func search(query: String, type: SearchType, page: Int, limit: Int) async throws -> SearchResult {
        calls.append(Call(query: query, type: type, page: page))
        // 门闩先摘：同 query 的后续调用不再挂起
        if let gate = gates.removeValue(forKey: query) {
            await gate.wait()
        }
        if let left = failuresLeft[query], left > 0 {
            failuresLeft[query] = left - 1
            throw MusicError.unknown("搜索失败（测试注入）")
        }
        let songs: [Song] = type == .song
            ? [Song(id: "\(query)-p\(page)", title: "\(query) 第\(page)页",
                    artists: [Artist(id: "a1", name: "Artist")], source: .netease)]
            : []
        return SearchResult(songs: songs, totalCount: 100, hasMore: page < 2)
    }

    func fetchQRCodeKey() async throws -> String { throw MusicError.unknown("unsupported") }
    func fetchQRCodeImage(key: String) async throws -> URL { throw MusicError.unknown("unsupported") }
    func checkQRCodeStatus(key: String) async throws -> QRLoginStatus { .failed("unsupported") }
    func logout() async throws { throw MusicError.unknown("unsupported") }
    func fetchAccountInfo() async throws -> AccountInfo? { nil }
    func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail { throw MusicError.unknown("unsupported") }
    func fetchPlaylistTracks(id: String, page: Int, limit: Int) async throws -> [Song] { throw MusicError.unknown("unsupported") }
    func fetchAlbumDetail(id: String) async throws -> PlaylistDetail { throw MusicError.unknown("unsupported") }
    func fetchArtistDetail(id: String) async throws -> ArtistDetail { throw MusicError.unknown("unsupported") }
    func fetchPlayableURL(songID: String, quality: AudioQuality.QualityLevel) async throws -> PlayableURL { throw MusicError.unknown("unsupported") }
    func fetchLyrics(songID: String) async throws -> LyricResult { throw MusicError.unknown("unsupported") }
    func fetchUserPlaylists() async throws -> [Playlist] { throw MusicError.unknown("unsupported") }
    func fetchLikedSongs() async throws -> [Song] { throw MusicError.unknown("unsupported") }
    func likeSong(id: String, like: Bool) async throws { throw MusicError.unknown("unsupported") }
    func fetchRecommendPlaylists() async throws -> [Playlist] { throw MusicError.unknown("unsupported") }
    func fetchDailyRecommendSongs() async throws -> [Song] { throw MusicError.unknown("unsupported") }
}

// MARK: - 测试

/// 第二轮复核 #4 / #5：搜索的「草稿 vs 已提交」与在途请求代次隔离
@MainActor
final class SearchSessionTests: XCTestCase {

    private func makeSession() -> (SearchSession, RecordingSearchProvider) {
        let provider = RecordingSearchProvider(identifier: "netease-stub")
        return (SearchSession(provider: provider), provider)
    }

    /// 轮询直到条件成立。条件是 async 的：经常要读 actor 上的记录（如 provider.calls），
    /// 而 XCTAssert* 的 autoclosure 不是 async，`XCTAssertTrue(await ...)` 编译不过。
    private func pollUntil(timeout: TimeInterval = 3, _ condition: @MainActor @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    /// 断言「在超时内成立」，避免把 await 塞进 XCTAssert 的 autoclosure
    private func assertEventually(
        _ condition: @MainActor @escaping () async -> Bool,
        message: String = "",
        timeout: TimeInterval = 3
    ) async {
        let ok = await pollUntil(timeout: timeout, condition)
        XCTAssertTrue(ok, message)
    }

    // MARK: #4 分页只认已提交查询

    /// 核心回归：搜完 A 把输入框改成 B 但不按回车，翻页必须是 A 的第 2 页
    func testPaginationUsesCommittedQueryNotDraft() async throws {
        let (session, netease) = makeSession()

        session.draftQuery = "A"
        session.submit(type: .song)
        await assertEventually({ session.result != nil })

        // 改了草稿但没提交
        session.draftQuery = "B"
        session.loadMore()
        await assertEventually({ (session.result?.songs.count ?? 0) == 2 }, message: "分页结果没有追加进来")

        let calls = await netease.calls
        XCTAssertEqual(calls, [
            RecordingSearchProvider.Call(query: "A", type: .song, page: 1),
            RecordingSearchProvider.Call(query: "A", type: .song, page: 2)
        ], "分页读了输入框草稿，把 B 的第 2 页追加到了 A 的结果后面")
        XCTAssertEqual(session.activeQuery, "A")
        XCTAssertEqual(session.result?.songs.map(\.id), ["A-p1", "A-p2"])
    }

    /// 类型同理：已提交 .album 后翻页仍按 .album 请求
    func testPaginationUsesCommittedType() async throws {
        let (session, netease) = makeSession()
        session.draftQuery = "A"
        session.submit(type: .album)
        await assertEventually({ session.result != nil })

        session.loadMore()
        await assertEventually({ await netease.calls.count == 2 })

        let calls = await netease.calls
        XCTAssertEqual(calls.map(\.type), [.album, .album])
        XCTAssertEqual(session.displayType, .album)
    }

    /// 结果列表按已提交的类型渲染，不是 Picker 的当前值
    func testDisplayTypeFollowsCommittedType() async throws {
        let (session, _) = makeSession()
        XCTAssertEqual(session.displayType, .song, "还没有结果集时用默认值")
        session.draftQuery = "A"
        session.submit(type: .playlist)
        await assertEventually({ session.result != nil })
        XCTAssertEqual(session.displayType, .playlist)
        session.reset()
        XCTAssertEqual(session.displayType, .song)
    }

    // MARK: #5 清空作废在途请求

    /// 核心回归：清空搜索框后，先前那次 search 的迟到响应不得把结果填回来
    func testResetDiscardsInFlightSearch() async throws {
        let (session, netease) = makeSession()
        let gate = ManualGate()
        await netease.setGate(gate, forQuery: "A")

        session.draftQuery = "A"
        session.submit(type: .song)
        XCTAssertTrue(session.isLoading)
        XCTAssertNil(session.result)

        session.reset()
        XCTAssertNil(session.result)
        XCTAssertFalse(session.isLoading, "清空后仍在转圈")
        XCTAssertTrue(session.draftQuery.isEmpty)

        // 放行在途请求，让它「迟到」返回
        gate.open()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(session.result, "已清空的结果集被旧请求填回来了")
        XCTAssertFalse(session.isLoading)
        XCTAssertNil(session.errorMessage)
        XCTAssertNil(session.activeQuery)
    }

    /// 翻页途中清空：迟到的分页不得追加
    func testResetDiscardsInFlightPagination() async throws {
        let (session, netease) = makeSession()
        session.draftQuery = "A"
        session.submit(type: .song)
        await assertEventually({ session.result != nil })

        // 第 2 页挂起，然后清空
        let gate = ManualGate()
        await netease.setGate(gate, forQuery: "A")
        session.loadMore()
        try await Task.sleep(nanoseconds: 50_000_000)
        session.reset()
        gate.open()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(session.result, "清空后旧分页把结果追加回来了")
        XCTAssertEqual(session.currentPage, 1)
    }

    /// 清空后不得再能翻页
    func testLoadMoreIsNoopAfterReset() async throws {
        let (session, netease) = makeSession()
        session.draftQuery = "A"
        session.submit(type: .song)
        await assertEventually({ session.result != nil })
        let before = await netease.calls.count

        session.reset()
        session.loadMore()
        try await Task.sleep(nanoseconds: 100_000_000)

        let after = await netease.calls.count
        XCTAssertEqual(after, before, "结果集已清空，翻页不该再发请求")
    }

    // MARK: 其它异步边界

    /// 连续两次搜索：先发的那次迟到不得覆盖后发的那次
    func testStaleSearchResponseIsDiscarded() async throws {
        let (session, netease) = makeSession()
        let gateA = ManualGate()
        let gateB = ManualGate()
        await netease.setGate(gateA, forQuery: "A")
        await netease.setGate(gateB, forQuery: "B")

        session.draftQuery = "A"
        session.submit(type: .song)
        session.draftQuery = "B"
        session.submit(type: .song)

        // 后发的先回
        gateB.open()
        await assertEventually({ session.result != nil })
        XCTAssertEqual(session.result?.songs.map(\.id), ["B-p1"])

        // 先发的那次随后才回
        gateA.open()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(session.result?.songs.map(\.id), ["B-p1"], "先发起的搜索覆盖了后发起的结果")
        XCTAssertEqual(session.activeQuery, "B")
    }

    /// 离页作废在途请求：结果保留，但转圈必须结束（否则回到页面永远卡在 ProgressView）
    func testCancelInFlightStopsSpinnerAndKeepsResult() async throws {
        let (session, netease) = makeSession()
        session.draftQuery = "A"
        session.submit(type: .song)
        await assertEventually({ session.result != nil })

        let gate = ManualGate()
        await netease.setGate(gate, forQuery: "B")
        session.draftQuery = "B"
        session.submit(type: .song)
        XCTAssertTrue(session.isLoading)

        session.cancelInFlight()
        XCTAssertFalse(session.isLoading, "离页作废请求后 isLoading 残留为 true")
        XCTAssertEqual(session.result?.songs.map(\.id), ["A-p1"], "离页不该清掉已有结果")

        gate.open()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(session.result?.songs.map(\.id), ["A-p1"])
    }

    /// 失败重试重跑的是「产生这次失败的那次查询」，不是当前草稿
    func testRetryRerunsCommittedQuery() async throws {
        let (session, netease) = makeSession()
        await netease.setFailures(1, forQuery: "A")

        session.draftQuery = "A"
        session.submit(type: .song)
        await assertEventually({ session.errorMessage != nil })

        session.draftQuery = "B" // 改了草稿但没提交
        session.retry(type: .song)
        await assertEventually({ session.result != nil })

        let calls = await netease.calls
        XCTAssertEqual(calls, [
            RecordingSearchProvider.Call(query: "A", type: .song, page: 1),
            RecordingSearchProvider.Call(query: "A", type: .song, page: 1)
        ], "重试跑了草稿而不是失败的那次查询")
    }

    /// 登录态变化：草稿非空就按草稿重搜（输入框里写的就是它，界面与结果才对得上）
    func testRefreshDataContextPrefersDraft() async throws {
        let (session, provider) = makeSession()
        session.draftQuery = "A"
        session.submit(type: .song)
        await assertEventually({ session.result != nil })

        session.draftQuery = "B"
        session.refreshDataContext(type: .album)
        // 按调用数等待：`.album` 的结果是空列表，
        // 用 `result != nil` 判断会在上一次的结果上立刻通过
        await assertEventually({ await provider.calls.count == 2 })

        let calls = await provider.calls
        XCTAssertEqual(calls, [
            RecordingSearchProvider.Call(query: "A", type: .song, page: 1),
            RecordingSearchProvider.Call(query: "B", type: .album, page: 1),
        ])
    }

    /// 草稿已空（用户手动删光）时重搜要退回到已提交查询，而不是什么都不做
    func testRefreshDataContextFallsBackToCommittedQuery() async throws {
        let (session, provider) = makeSession()
        session.draftQuery = "A"
        session.submit(type: .song)
        await assertEventually({ session.result != nil })

        session.draftQuery = ""
        session.refreshDataContext(type: .song)
        await assertEventually({ await provider.calls.count == 2 })

        let calls = await provider.calls
        XCTAssertEqual(calls, [
            RecordingSearchProvider.Call(query: "A", type: .song, page: 1),
            RecordingSearchProvider.Call(query: "A", type: .song, page: 1),
        ])
    }

    /// 没有任何结果集时重搜不发请求
    func testRefreshDataContextWithoutResultsIsNoop() async throws {
        let (session, netease) = makeSession()
        session.refreshDataContext(type: .song)
        try await Task.sleep(nanoseconds: 100_000_000)
        let calls = await netease.calls
        XCTAssertTrue(calls.isEmpty)
    }

    /// 空草稿不发起查询
    func testSubmitIgnoresBlankDraft() async throws {
        let (session, netease) = makeSession()
        session.draftQuery = "   "
        session.submit(type: .song)
        try await Task.sleep(nanoseconds: 100_000_000)

        let calls = await netease.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(session.isLoading)
        XCTAssertNil(session.result)
    }

    /// 提交时空格应被裁掉，且已提交查询是裁剪后的值
    func testSubmitTrimsWhitespace() async throws {
        let (session, netease) = makeSession()
        session.draftQuery = "  周杰伦 "
        session.submit(type: .song)
        await assertEventually({ session.result != nil })

        let calls = await netease.calls
        XCTAssertEqual(calls, [RecordingSearchProvider.Call(query: "周杰伦", type: .song, page: 1)])
        XCTAssertEqual(session.activeQuery, "周杰伦")
    }
}
