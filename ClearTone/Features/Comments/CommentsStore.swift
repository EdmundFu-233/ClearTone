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
    @Published var sort: CommentSort = .recommended

    /// 当前查看评论的歌曲。切歌必须换掉它，否则旧歌的评论会显示在新歌页上。
    @Published private(set) var song: Song?

    private let provider = NeteaseProvider.shared
    private var loadToken = UUID()
    private var page = 1

    private let pageSize = 20

    func load(song: Song, sort: CommentSort? = nil) async {
        let token = UUID()
        loadToken = token
        self.song = song
        if let sort { self.sort = sort }
        page = 1
        comments = []
        errorMessage = nil
        isLoading = true
        await fetchPage(token: token, reset: true)
        guard loadToken == token else { return }
        isLoading = false
    }

    func reload() async {
        guard let song else { return }
        await load(song: song, sort: sort)
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let token = loadToken
        page += 1
        await fetchPage(token: token, reset: false)
        guard loadToken == token else { return }
        isLoadingMore = false
    }

    private func fetchPage(token: UUID, reset: Bool) async {
        guard let song else { return }
        do {
            let result = try await provider.fetchComments(
                songID: song.id, sort: sort, page: page, pageSize: pageSize
            )
            guard loadToken == token, !Task.isCancelled else { return }
            if reset {
                comments = result.comments
            } else {
                let existing = Set(comments.map(\.id))
                comments.append(contentsOf: result.comments.filter { !existing.contains($0.id) })
            }
            total = result.total
            hasMore = result.hasMore
        } catch {
            guard loadToken == token else { return }
            if reset {
                errorMessage = error.ctUserMessage
                comments = []
            } else {
                // 加载更多失败不该把已加载的内容也清掉
                page = max(1, page - 1)
            }
        }
    }

    /// 点赞/取消点赞。乐观更新 + 失败回滚。
    func toggleLike(_ comment: Comment) async {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        let target = !comments[index].isLiked
        let previous = comments[index]
        comments[index].isLiked = target
        comments[index].likedCount = max(0, comments[index].likedCount + (target ? 1 : -1))
        do {
            try await provider.likeComment(
                songID: song?.id ?? "", commentID: comment.id, like: target
            )
        } catch {
            // 按 id 回滚，不能按 index：`load(song:)` 会把 comments 换成**另一首歌**的
            // 列表而长度仍然 ≥ index，于是下标合法、但那一行现在是别人的评论 ——
            // 表现为「打开 B 歌的评论，里面混进了 A 歌的一条评论」。
            guard let current = comments.firstIndex(where: { $0.id == previous.id }) else { return }
            comments[current] = previous
            CTLog.general.error("评论点赞失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }
}
