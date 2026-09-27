import Foundation
import Combine

/// 排行榜页数据：榜单目录 + 各榜单曲目 + 新歌速递。
@MainActor
final class TopListStore: ObservableObject {

    @Published private(set) var lists: [TopList] = []
    @Published private(set) var isLoadingLists = false
    @Published private(set) var listsError: String?

    @Published private(set) var tracks: [Song] = []
    @Published private(set) var isLoadingTracks = false
    @Published private(set) var tracksError: String?
    @Published private(set) var loadedListID: String?

    @Published var newSongsArea: TopSongArea = .all
    @Published private(set) var newSongs: [Song] = []
    @Published private(set) var isLoadingNewSongs = false

    @Published private(set) var hotPlaylists: [Playlist] = []
    @Published private(set) var playlistCategories: [PlaylistCategoryGroup] = []
    @Published var selectedCategory: String?
    @Published var playlistOrder: TopPlaylistOrder = .hot
    @Published private(set) var isLoadingPlaylists = false

    private let provider = NeteaseProvider.shared
    private var listToken = UUID()
    private var trackToken = UUID()
    /// 新歌速递与歌单广场各自独立 —— 与 listToken/trackToken 同样的理由：
    /// 四个资源共用一个令牌会互相作废（同 ProfileStore 的教训）。
    private var newSongsToken = UUID()
    private var playlistsToken = UUID()
    /// 歌单广场的在途闸：并发分页会取到同一个 offset，追加出重复卡片
    private var isLoadingHotPlaylists = false

    // MARK: - 榜单目录

    func loadLists() async {
        let token = UUID()
        listToken = token
        isLoadingLists = lists.isEmpty
        listsError = nil
        do {
            let loaded = try await provider.fetchTopLists()
            guard listToken == token, !Task.isCancelled else { return }
            lists = loaded
        } catch {
            guard listToken == token else { return }
            listsError = error.ctUserMessage
        }
        guard listToken == token else { return }
        isLoadingLists = false
    }

    // MARK: - 榜单曲目

    /// 榜单本身就是一个歌单，id 直接喂给 playlist/detail
    func loadTracks(for list: TopList) async {
        let token = UUID()
        trackToken = token
        isLoadingTracks = true
        tracksError = nil
        tracks = []
        loadedListID = list.id
        do {
            let detail = try await provider.fetchPlaylistDetail(id: list.id)
            guard trackToken == token, !Task.isCancelled else { return }
            var collected = detail.tracks
            // 榜单通常 50~200 首，首页给的 tracks 往往不全，补齐分页
            if collected.count < detail.totalTrackCount {
                let pageSize = 100
                let pages = min(4, Int(ceil(Double(detail.totalTrackCount) / Double(pageSize))))
                for page in 1...pages {
                    let more = try await provider.fetchPlaylistTracks(id: list.id, page: page, limit: pageSize)
                    guard trackToken == token, !Task.isCancelled else { return }
                    collected = mergeUnique(collected, with: more)
                    if collected.count >= detail.totalTrackCount { break }
                }
            }
            tracks = collected
        } catch {
            guard trackToken == token else { return }
            tracksError = error.ctUserMessage
        }
        guard trackToken == token else { return }
        isLoadingTracks = false
    }

    /// 按 id 去重合并（榜单分页偶尔会重复边界项）
    private func mergeUnique(_ base: [Song], with extra: [Song]) -> [Song] {
        var seen = Set(base.map(\.id))
        var out = base
        for song in extra where !seen.contains(song.id) {
            seen.insert(song.id)
            out.append(song)
        }
        return out
    }

    // MARK: - 新歌速递

    /// 原先只有 `!Task.isCancelled` 而没有代次令牌，而调用方用的是**非结构化**
    /// `Task { await store.loadNewSongs(area:) }`（Picker 的 set）—— 切 tab、
    /// 离页面都不会取消它，也不校验 `target == newSongsArea`。
    /// 快速切「华语 → 欧美」时华语的响应后到，就把欧美的高亮配上华语的歌。
    func loadNewSongs(area: TopSongArea? = nil) async {
        let target = area ?? newSongsArea
        newSongsArea = target
        let token = UUID()
        newSongsToken = token
        isLoadingNewSongs = true
        do {
            let loaded = try await provider.fetchTopSongs(area: target)
            guard newSongsToken == token, !Task.isCancelled else { return }
            newSongs = loaded
        } catch {
            guard newSongsToken == token, !Task.isCancelled else { return }
            newSongs = []
            CTLog.general.error("加载新歌速递失败: \(CTLog.sanitize(error.localizedDescription))")
        }
        guard newSongsToken == token else { return }
        isLoadingNewSongs = false
    }

    // MARK: - 歌单广场

    func loadCategories() async {
        guard playlistCategories.isEmpty else { return }
        do {
            playlistCategories = try await provider.fetchPlaylistCategories()
        } catch {
            CTLog.general.error("加载歌单分类失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    /// 原先没有任何在途闸：`InfiniteScrollGrid` 的「加载更多」按钮虽然按
    /// `!isLoading` 隐藏，但 `onAppear` 自动触发的加载没有这层判断，
    /// 两者在同一帧内都可能发起 —— 两个请求用**同一个 offset**，
    /// `append` 又不去重，于是 30 条重复卡片常驻列表。
    /// `reset` 那一路必须能打断在途请求，所以闸只在非 reset 时拦。
    func loadHotPlaylists(reset: Bool) async {
        if reset {
            let token = UUID()
            playlistsToken = token
            isLoadingHotPlaylists = false
            hotPlaylists = []
            isLoadingPlaylists = true
            do {
                let page = try await provider.fetchHotPlaylists(
                    category: selectedCategory,
                    order: playlistOrder,
                    limit: 30,
                    offset: 0
                )
                guard playlistsToken == token, !Task.isCancelled else { return }
                hotPlaylists = Self.dedupe(page)
            } catch {
                guard playlistsToken == token, !Task.isCancelled else { return }
                CTLog.general.error("加载歌单广场失败: \(CTLog.sanitize(error.localizedDescription))")
            }
            guard playlistsToken == token else { return }
            isLoadingPlaylists = false
            return
        }

        guard !isLoadingHotPlaylists else { return }
        isLoadingHotPlaylists = true
        defer { isLoadingHotPlaylists = false }
        let token = UUID()
        playlistsToken = token
        isLoadingPlaylists = true
        do {
            let page = try await provider.fetchHotPlaylists(
                category: selectedCategory,
                order: playlistOrder,
                limit: 30,
                offset: hotPlaylists.count
            )
            guard playlistsToken == token, !Task.isCancelled else { return }
            hotPlaylists = Self.dedupe(hotPlaylists + page)
        } catch {
            guard playlistsToken == token, !Task.isCancelled else { return }
            CTLog.general.error("加载歌单广场加载更多失败: \(CTLog.sanitize(error.localizedDescription))")
        }
        guard playlistsToken == token else { return }
        isLoadingPlaylists = false
    }

    /// 追加前按 id 去重。offset 分页在有并发/重入时不保证不重叠。
    private static func dedupe(_ playlists: [Playlist]) -> [Playlist] {
        var seen = Set<String>()
        return playlists.filter { seen.insert($0.id).inserted }
    }
}
