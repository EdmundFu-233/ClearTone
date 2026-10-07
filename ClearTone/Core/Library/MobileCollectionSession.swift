import Foundation
import Combine

/// 手机端详情/分页逻辑留在 Core，保持可离线测试。
@MainActor
final class MobileCollectionSession: ObservableObject {
    enum Kind: Hashable { case playlist(String), album(String), artist(String) }
    @Published private(set) var title = "加载中"
    @Published private(set) var descriptionText: String?
    @Published private(set) var coverURL: URL?
    @Published private(set) var songs: [Song] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?
    private let provider: any MusicProvider
    private var generation = 0
    private var kind: Kind?
    private var page = 1
    private let pageSize = 100
    private var total = 0

    init(provider: any MusicProvider = NeteaseProvider.shared) { self.provider = provider }

    func load(_ kind: Kind) async {
        generation += 1
        let token = generation
        self.kind = kind
        title = "加载中"; descriptionText = nil; coverURL = nil; songs = []; albums = []
        page = 1; total = 0; hasMore = false; errorMessage = nil; isLoadingMore = false; isLoading = true
        defer { if token == generation { isLoading = false } }
        do {
            switch kind {
            case .playlist(let id):
                let detail = try await provider.fetchPlaylistDetail(id: id)
                guard token == generation, !Task.isCancelled else { return }
                title = detail.playlist.name; descriptionText = detail.playlist.descriptionText
                coverURL = detail.playlist.coverURL; total = detail.totalTrackCount
                // detail 中的 seed 与第 1 页重叠，必须替换而非追加。
                let first = try await provider.fetchPlaylistTracks(id: id, page: 1, limit: pageSize)
                guard token == generation, !Task.isCancelled else { return }
                songs = unique(first)
                hasMore = morePages(pageCount: first.count, total: total, page: 1)
            case .album(let id):
                let detail = try await provider.fetchAlbumDetail(id: id)
                guard token == generation, !Task.isCancelled else { return }
                title = detail.playlist.name; descriptionText = detail.playlist.descriptionText
                // 专辑 / 歌手页一次给全，不分页 —— 但同样要过一遍去重，
                // 否则上游返回重复 id 时 SwiftUI 的 ForEach 会直接崩。
                coverURL = detail.playlist.coverURL; songs = unique(detail.tracks)
            case .artist(let id):
                let detail = try await provider.fetchArtistDetail(id: id)
                guard token == generation, !Task.isCancelled else { return }
                title = detail.artist.name; coverURL = detail.artist.avatarURL
                songs = unique(detail.hotSongs); albums = detail.albums
            }
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            errorMessage = error.ctUserMessage
            CTLog.general.error("详情页加载失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    func loadMore() async {
        guard case .playlist(let id) = kind, hasMore, !isLoading, !isLoadingMore else { return }
        let token = generation
        let nextPage = page + 1
        isLoadingMore = true; errorMessage = nil
        defer { if token == generation { isLoadingMore = false } }
        do {
            let next = try await provider.fetchPlaylistTracks(id: id, page: nextPage, limit: pageSize)
            guard token == generation, !Task.isCancelled else { return }
            songs = unique(songs + next)
            page = nextPage
            hasMore = morePages(pageCount: next.count, total: total, page: nextPage)
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            errorMessage = error.ctUserMessage
        }
    }

    /// 还有没有下一页。两件事按顺序判断：
    ///
    /// 1. **不满一页就到底了** —— 最硬的信号，与 `total` 无关；
    /// 2. 总数已知时按「已翻到的页 × 每页条数」推进。这里刻意用页数而不是
    ///    去重后的 `songs.count`：上游万一抽风每次都回满一页，
    ///    `songs.count` 会停在原地（去重吃光了新增），而 `page` 每次都 +1，
    ///    `page * pageSize < total` 必然收敛 —— 不会转不出去。
    ///
    /// 总数未知（`total <= 0`，`trackCount` 与 `trackIds` 都缺席）时退回
    /// 「满一页就当还有」，宁可多要一次（拿到短页自然停），
    /// 也不能在这里判死：200 首的歌单会只剩第一页的 100 首。
    private func morePages(pageCount: Int, total: Int, page: Int) -> Bool {
        guard pageCount >= pageSize else { return false }
        guard total > 0 else { return true }
        return page * pageSize < total
    }

    private func unique(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }
    func cancel() {
        generation += 1
        isLoading = false
        isLoadingMore = false
        // 取消导航后不该把上一次的报错留给下一次打开
        errorMessage = nil
    }
}
