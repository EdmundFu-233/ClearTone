import Foundation
import Combine

/// 搜索会话：把「输入框草稿」与「已提交的查询」彻底分开，并给所有在途请求做代次隔离。
///
/// 为什么从 `SearchView` 抽出来：这两个 bug 都只在异步边界上出现，
/// 留在视图的 `@State` 里没法写回归测试（本仓库第二轮复核就是这么漏掉的）。
///
/// 三条不变量：
/// 1. `draftQuery` 只是草稿。**只有 `submit()` 才会把草稿变成一次真正的查询**。
/// 2. 分页 / 重试 / 登录态变化后的重搜只读 `activeQuery`/`activeType`
///    ——也就是产生当前结果集的那次提交，绝不读草稿。否则用户改了几个字没按回车，
///    下一个滚动就会拿新词去翻页并追加到旧结果后面。
/// 3. 每次提交/重置/离页都递增 `generation`，所有迟到回调一律丢弃：
///    清空搜索框后旧请求返回，不得把已经清掉的结果再填回来。
@MainActor
final class SearchSession: ObservableObject {
    /// 输入框当前内容（草稿）。仅 `submit()` 会读取它发起查询。
    @Published var draftQuery: String = ""
    /// 当前结果集；nil 表示「没有结果集」而不是「结果为空」
    @Published private(set) var result: SearchResult?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// 当前结果集对应的已提交参数（结果集的身份）
    private(set) var activeQuery: String?
    private(set) var activeType: SearchType?
    private(set) var currentPage = 1

    /// 结果该按哪种类型渲染：跟随**已提交的类型**，而不是 Picker 的当前值。
    /// 否则改一下类型选择就会把旧结果的列表形态换掉（对着歌单结果显示歌手行）。
    var displayType: SearchType { activeType ?? .song }
    /// 是否已有结果集（登录态变化时决定要不要重搜）
    var hasActiveQuery: Bool { activeQuery != nil }

    private var generation = 0
    private var searchTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?

    private let provider: MusicProvider
    private let pageSize = 30

    init(provider: MusicProvider = NeteaseProvider.shared) {
        self.provider = provider
    }

    // MARK: - 查询

    /// 提交当前草稿（回车 / 切换搜索类型）。空草稿不发起请求。
    func submit(type: SearchType) {
        let query = draftQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        start(query: query, type: type)
    }

    /// 失败重试：重跑产生这次失败的那次查询，而不是重跑当前草稿
    func retry(type: SearchType) {
        guard let query = activeQuery else {
            submit(type: type)
            return
        }
        start(query: query, type: activeType ?? type)
    }

    /// 登录态变化后重搜：草稿优先（输入框里写的就是它，界面与结果才对得上），
    /// 草稿已空则退回到已提交查询。
    func refreshDataContext(type: SearchType) {
        if draftQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let query = activeQuery else { return }
            start(query: query, type: activeType ?? type)
            return
        }
        submit(type: type)
    }

    private func start(query: String, type: SearchType) {
        generation += 1
        let generation = self.generation
        searchTask?.cancel()
        searchTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        // 记录结果集身份：分页与重试之后只认这一份参数
        activeQuery = query
        activeType = type
        currentPage = 1
        isLoading = true
        errorMessage = nil

        searchTask = Task {
            do {
                let found = try await provider.search(query: query, type: type, page: 1, limit: pageSize)
                guard !Task.isCancelled, generation == self.generation else { return }
                self.result = found
                isLoading = false
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                errorMessage = error.ctUserMessage
                isLoading = false
            }
        }
    }

    /// 加载下一页并追加。
    ///
    /// 参数全部取自已提交的那次查询（`activeQuery`/`activeType`），
    /// 不看 `draftQuery`：用户改了输入框没按回车时，翻页仍必须是同一个查询的第 2 页。
    func loadMore() {
        guard let result, result.hasMore, !isLoading, loadMoreTask == nil,
              let query = activeQuery, let type = activeType else { return }
        let generation = self.generation
        let page = currentPage + 1
        currentPage = page

        loadMoreTask = Task {
            // 只有「本次分页仍属于当前代次」时才清空句柄：reset/新搜索已经作废了它，
            // 无条件置 nil 会把后来那次 loadMore 的在途句柄一起清掉，
            // 于是下一次翻页会在上一次还没回来时再次发起，页码错乱。
            defer { if generation == self.generation { loadMoreTask = nil } }
            do {
                let more = try await provider.search(query: query, type: type, page: page, limit: pageSize)
                // 期间发起了新搜索 / 清空了结果集：本次分页作废，旧结果不得混入
                guard !Task.isCancelled, generation == self.generation else { return }
                var merged = self.result ?? SearchResult()
                // 四种类型都要能翻页。此前只追加 songs，于是歌手/专辑/歌单
                // 永远停在第一页 30 条 —— 接口是支持 offset 分页的。
                switch type {
                case .song: merged.songs.append(contentsOf: more.songs)
                case .artist: merged.artists.append(contentsOf: more.artists)
                case .album: merged.albums.append(contentsOf: more.albums)
                case .playlist: merged.playlists.append(contentsOf: more.playlists)
                }
                // 分页只影响当前类型的计数，别的类型保持原值
                merged.totalCount = more.totalCount
                merged.hasMore = more.hasMore
                self.result = merged
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                currentPage = page - 1
            }
        }
    }

    // MARK: - 重置

    /// 清空搜索（输入框叉号）：作废在途请求并重置结果、分页、加载与错误态
    func reset() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        activeQuery = nil
        activeType = nil
        result = nil
        currentPage = 1
        isLoading = false
        errorMessage = nil
        draftQuery = ""
    }

    /// 离开搜索页：只作废在途请求，保留结果（回到页面时不该重新加载一遍）。
    /// `isLoading` 必须复位 —— 任务已被取消，不会再有回调把它置回 false，
    /// 留着 true 会让回到页面时永远卡在转圈，且 `loadMore` 的 `!isLoading` 也会被卡死。
    func cancelInFlight() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        loadMoreTask?.cancel()
        loadMoreTask = nil
        isLoading = false
    }
}
