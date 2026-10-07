import Foundation
import Combine

/// 歌曲评论页数据。
@MainActor
final class CommentsStore: ObservableObject {

    @Published private(set) var comments: [Comment] = []
    @Published private(set) var total = 0
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var paginationError: String?
    @Published private(set) var likeError: String?
    @Published private(set) var pendingLikeIDs: Set<String> = []
    @Published var sort: CommentSort = .recommended

    /// 当前查看评论的歌曲。切歌必须换掉它，否则旧歌的评论会显示在新歌页上。
    @Published private(set) var song: Song?

    private let provider: any CommentProvider
    private var loadToken = UUID()
    private var page = 1
    private var cursor: String?
    private var loadedSort: CommentSort = .recommended
    private var likeTokens: [String: UUID] = [:]

    private let pageSize = 20

    init(provider: any CommentProvider = NeteaseProvider.shared) {
        self.provider = provider
    }

    func load(song: Song, sort: CommentSort? = nil) async {
        let token = UUID()
        loadToken = token
        self.song = song
        if let sort { self.sort = sort }
        loadedSort = self.sort
        page = 1
        cursor = nil
        comments = []
        total = 0
        hasMore = false
        isLoadingMore = false
        errorMessage = nil
        paginationError = nil
        // 上一首歌的点赞失败提示不能跟到这一首来：likeError 只在 toggleLike 里
        // 被置位，不清的话它会一直挂在页面上，直到用户再点一次赞。
        likeError = nil
        pendingLikeIDs = []
        likeTokens = [:]
        isLoading = true
        defer { if loadToken == token { isLoading = false } }
        await fetchPage(token: token, requestedPage: 1, reset: true)
    }

    func reload() async {
        guard let song else { return }
        await load(song: song, sort: sort)
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let token = loadToken
        paginationError = nil
        defer { if loadToken == token { isLoadingMore = false } }
        await fetchPage(token: token, requestedPage: page + 1, reset: false)
    }

    private func fetchPage(token: UUID, requestedPage: Int, reset: Bool) async {
        guard let song else { return }
        do {
            let result = try await provider.fetchComments(
                songID: song.id, sort: loadedSort, page: requestedPage, pageSize: pageSize, cursor: cursor
            )
            guard loadToken == token, !Task.isCancelled else { return }
            var seen = Set(reset ? [] : comments.map(\.id))
            let fresh = result.comments.filter { seen.insert($0.id).inserted }
            if reset { comments = fresh }
            else { comments.append(contentsOf: fresh) }
            page = requestedPage
            total = result.total
            // 缺游标或游标不前进时不能再次请求最新第一页。
            hasMore = result.hasMore && !result.comments.isEmpty
                && (loadedSort != .newest || (result.nextCursor != nil && result.nextCursor != cursor))
            cursor = result.nextCursor
        } catch {
            guard loadToken == token, !Task.isCancelled else { return }
            if reset {
                errorMessage = error.ctUserMessage
                comments = []
            } else {
                // 加载更多失败不该把已加载的内容也清掉
                paginationError = error.ctUserMessage
            }
        }
    }

    /// 点赞/取消点赞。乐观更新 + 失败回滚。
    func toggleLike(_ comment: Comment) async {
        guard let song, !pendingLikeIDs.contains(comment.id),
              let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        let token = loadToken
        let writeToken = UUID()
        likeTokens[comment.id] = writeToken
        pendingLikeIDs.insert(comment.id)
        defer {
            if loadToken == token, likeTokens[comment.id] == writeToken {
                likeTokens.removeValue(forKey: comment.id)
                pendingLikeIDs.remove(comment.id)
            }
        }
        likeError = nil
        let target = !comments[index].isLiked
        let previous = comments[index]
        comments[index].isLiked = target
        comments[index].likedCount = max(0, comments[index].likedCount + (target ? 1 : -1))
        do {
            try await provider.likeComment(
                songID: song.id, commentID: comment.id, like: target
            )
        } catch {
            // 按 id 回滚，不能按 index：`load(song:)` 会把 comments 换成**另一首歌**的
            // 列表而长度仍然 ≥ index，于是下标合法、但那一行现在是别人的评论 ——
            // 表现为「打开 B 歌的评论，里面混进了 A 歌的一条评论」。
            guard loadToken == token, likeTokens[comment.id] == writeToken,
                  let current = comments.firstIndex(where: { $0.id == previous.id }) else { return }
            comments[current] = previous
            likeError = error.ctUserMessage
            CTLog.general.error("评论点赞失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }
}
