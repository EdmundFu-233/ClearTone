import XCTest
@testable import ClearTone

@MainActor
final class CommentsStoreTests: XCTestCase {
    private func comment(_ id: String, liked: Bool = false, count: Int = 0) -> Comment {
        Comment(id: id, content: id, userID: "u", nickname: "用户",
                time: Date(timeIntervalSince1970: 100), likedCount: count, isLiked: liked)
    }

    private func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("受控请求没有启动")
    }

    func testSwitchDuringPaginationDoesNotLeaveLoadingMoreLocked() async {
        let provider = ControlledCommentProvider()
        let store = CommentsStore(provider: provider)
        await provider.enqueue(CommentPage(comments: [comment("a")], total: 40, hasMore: true))
        await store.load(song: .fixture(id: "A"))
        let oldPage = Task { await store.loadMore() }
        await waitFor { await provider.fetchCount == 2 }
        await provider.enqueue(CommentPage(comments: [comment("b")], total: 40, hasMore: true))
        await store.load(song: .fixture(id: "B"))
        XCTAssertFalse(store.isLoadingMore)
        await provider.finishPage(CommentPage(comments: [comment("old")]))
        await oldPage.value
        XCTAssertEqual(store.comments.map(\.id), ["b"])
        await provider.enqueue(CommentPage(comments: [comment("c")]))
        await store.loadMore()
        XCTAssertEqual(store.comments.map(\.id), ["b", "c"])
    }

    func testFailedReloadClearsPreviousTotalAndPagination() async {
        let provider = ControlledCommentProvider()
        let store = CommentsStore(provider: provider)
        await provider.enqueue(CommentPage(comments: [comment("a")], total: 90, hasMore: true))
        await store.load(song: .fixture(id: "A"))
        await provider.failNextPage()
        await store.load(song: .fixture(id: "B"))
        XCTAssertEqual(store.total, 0)
        XCTAssertFalse(store.hasMore)
        XCTAssertNotNil(store.errorMessage)
    }

    func testOldLikeFailureCannotRollbackReloadedComment() async {
        let provider = ControlledCommentProvider()
        let store = CommentsStore(provider: provider)
        await provider.enqueue(CommentPage(comments: [comment("same")]))
        await store.load(song: .fixture(id: "A"))
        let write = Task { await store.toggleLike(store.comments[0]) }
        await waitFor { await provider.likeCount == 1 }
        // 同一首歌刷新，服务端已经带回了较新的点赞数。
        await provider.enqueue(CommentPage(comments: [comment("same", liked: true, count: 30)]))
        await store.reload()
        await provider.finishLike(failing: true)
        await write.value
        XCTAssertTrue(store.comments[0].isLiked)
        XCTAssertEqual(store.comments[0].likedCount, 30)
    }

    func testRepeatedLikeWhilePendingSendsOnlyOneWrite() async {
        let provider = ControlledCommentProvider()
        let store = CommentsStore(provider: provider)
        await provider.enqueue(CommentPage(comments: [comment("a")]))
        await store.load(song: .fixture(id: "A"))
        let first = Task { await store.toggleLike(store.comments[0]) }
        await waitFor { await provider.likeCount == 1 }
        let second = Task { await store.toggleLike(store.comments[0]) }
        for _ in 0..<50 { await Task.yield() }
        let count = await provider.likeCount
        XCTAssertEqual(count, 1)
        await provider.finishLike(failing: false)
        await first.value
        await second.value
        XCTAssertTrue(store.comments[0].isLiked)
        XCTAssertEqual(store.comments[0].likedCount, 1)
    }

    func testNewestPaginationRetriesSamePageAndCursorAfterFailure() async {
        let provider = ControlledCommentProvider()
        let store = CommentsStore(provider: provider)
        await provider.enqueue(CommentPage(comments: [comment("a")], total: 40, hasMore: true, nextCursor: "100000"))
        await store.load(song: .fixture(id: "A"), sort: .newest)
        await provider.failNextPage()
        await store.loadMore()
        XCTAssertEqual(store.comments.map(\.id), ["a"])
        XCTAssertNotNil(store.paginationError)
        XCTAssertFalse(store.isLoadingMore)
        XCTAssertTrue(store.hasMore)
        await provider.enqueue(CommentPage(comments: [comment("b")], nextCursor: "90000"))
        await store.loadMore()
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.page), [1, 2, 2])
        XCTAssertEqual(requests.map(\.cursor), [nil, "100000", "100000"])
        XCTAssertNil(store.paginationError)
        XCTAssertEqual(store.comments.map(\.id), ["a", "b"])
    }

    func testCancelledPaginationUnlocksAndDoesNotAdvancePage() async {
        let provider = ControlledCommentProvider()
        let store = CommentsStore(provider: provider)
        await provider.enqueue(CommentPage(comments: [comment("a")], total: 40, hasMore: true))
        await store.load(song: .fixture(id: "A"))
        let task = Task { await store.loadMore() }
        await waitFor { await provider.fetchCount == 2 }
        task.cancel()
        await provider.finishPage(CommentPage(comments: [comment("cancelled")]))
        await task.value
        XCTAssertFalse(store.isLoadingMore)
        XCTAssertEqual(store.comments.map(\.id), ["a"])
        await provider.enqueue(CommentPage(comments: [comment("b")]))
        await store.loadMore()
        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.page), [1, 2, 2])
    }

    func testNewestWithNonadvancingCursorStopsRequestLoop() async {
        let provider = ControlledCommentProvider()
        let store = CommentsStore(provider: provider)
        let page = CommentPage(comments: [comment("a")], total: 40, hasMore: true, nextCursor: "100000")
        await provider.enqueue(page)
        await store.load(song: .fixture(id: "A"), sort: .newest)
        await provider.enqueue(page)
        await store.loadMore()
        XCTAssertFalse(store.hasMore)
        XCTAssertEqual(store.comments.map(\.id), ["a"])
        await store.loadMore()
        let count = await provider.fetchCount
        XCTAssertEqual(count, 2)
    }

    func testActiveLikeFailureRollsBackAndReleasesLock() async {
        let provider = ControlledCommentProvider()
        let store = CommentsStore(provider: provider)
        await provider.enqueue(CommentPage(comments: [comment("a", count: 10)]))
        await store.load(song: .fixture(id: "A"))
        let task = Task { await store.toggleLike(store.comments[0]) }
        await waitFor { await provider.likeCount == 1 }
        XCTAssertTrue(store.pendingLikeIDs.contains("a"))
        XCTAssertEqual(store.comments[0].likedCount, 11)
        await provider.finishLike(failing: true)
        await task.value
        XCTAssertFalse(store.comments[0].isLiked)
        XCTAssertEqual(store.comments[0].likedCount, 10)
        XCTAssertTrue(store.pendingLikeIDs.isEmpty)
    }

    /// 点赞失败的提示只属于这一首歌。`likeError` 只在 `toggleLike` 里置位，
    /// `load` 忘了清的话，A 歌的失败横幅会一直挂在 B 歌的评论页上。
    func testLikeErrorDoesNotSurviveSongSwitch() async {
        let provider = ControlledCommentProvider()
        let store = CommentsStore(provider: provider)
        await provider.enqueue(CommentPage(comments: [comment("a")]))
        await store.load(song: .fixture(id: "A"))
        let write = Task { await store.toggleLike(store.comments[0]) }
        await waitFor { await provider.likeCount == 1 }
        await provider.finishLike(failing: true)
        await write.value
        XCTAssertNotNil(store.likeError)

        await provider.enqueue(CommentPage(comments: [comment("b")]))
        await store.load(song: .fixture(id: "B"))
        XCTAssertNil(store.likeError, "切歌后不该还挂着上一首歌的点赞失败提示")
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.paginationError)
    }

    /// 下一次点赞开始时必须把上一次的失败提示抹掉，否则「失败」会一直留着
    /// 直到又失败一次。
    func testNewLikeClearsPreviousFailureBanner() async {
        let provider = ControlledCommentProvider()
        let store = CommentsStore(provider: provider)
        await provider.enqueue(CommentPage(comments: [comment("a"), comment("b")]))
        await store.load(song: .fixture(id: "A"))
        let first = Task { await store.toggleLike(store.comments[0]) }
        await waitFor { await provider.likeCount == 1 }
        await provider.finishLike(failing: true)
        await first.value
        XCTAssertNotNil(store.likeError)

        let second = Task { await store.toggleLike(store.comments[1]) }
        await waitFor { await provider.likeCount == 2 }
        XCTAssertNil(store.likeError, "新的点赞已经开始，旧的失败提示应当已经清掉")
        await provider.finishLike(failing: false)
        await second.value
        XCTAssertNil(store.likeError)
    }
}

private actor ControlledCommentProvider: CommentProvider {
    private var pages: [CommentPage] = []
    private var failPage = false
    private var pendingPage: CheckedContinuation<CommentPage, any Error>?
    private var pendingLikes: [CheckedContinuation<Void, any Error>] = []
    private(set) var fetchCount = 0
    private(set) var likeCount = 0
    struct Request: Sendable { let page: Int; let cursor: String? }
    private(set) var requests: [Request] = []

    func enqueue(_ page: CommentPage) { pages.append(page) }
    func failNextPage() { failPage = true }
    func fetchComments(songID: String, sort: CommentSort, page: Int, pageSize: Int, cursor: String?) async throws -> CommentPage {
        fetchCount += 1
        requests.append(Request(page: page, cursor: cursor))
        if failPage { failPage = false; throw MusicError.networkUnavailable }
        if !pages.isEmpty { return pages.removeFirst() }
        return try await withCheckedThrowingContinuation { pendingPage = $0 }
    }
    func finishPage(_ page: CommentPage) {
        pendingPage?.resume(returning: page)
        pendingPage = nil
    }
    func likeComment(songID: String, commentID: String, like: Bool) async throws {
        likeCount += 1
        try await withCheckedThrowingContinuation { pendingLikes.append($0) }
    }
    func finishLike(failing: Bool) {
        let continuations = pendingLikes
        pendingLikes = []
        for continuation in continuations {
            if failing { continuation.resume(throwing: MusicError.networkUnavailable) }
            else { continuation.resume() }
        }
    }
}
