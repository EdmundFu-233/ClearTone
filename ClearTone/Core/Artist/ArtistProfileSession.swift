import Foundation
import Combine

/// 歌手资料页的加载状态机。
///
/// ## 为什么放在 `Core/` 而不是 `Features/Artist/`
///
/// `project.yml` 把 `Features/**` 排除在单测 target 之外
/// （理由见那里的注释：视图层在离线测试里既用不到也构造不出来）。
/// 于是 `LibraryStore` / `CommentsStore` / `SocialStore` 这些
/// 放在 `Features/` 下的 store 一个都没测过 —— 它们的分页与代次隔离全是裸的。
///
/// 这里照 `Core/Search/SearchSession.swift` 的先例拆开：
/// 纯逻辑（代次、锁、分页游标、失败降级）放 `Core/`，可测；
/// `ArtistDetailView` 只做渲染。
///
/// ## 三条不变量
///
/// 1. **代次隔离**：换歌手 / 登录态变化时 `reset()` 递增代次，
///    所有迟到回调一律丢弃。否则「点 A 歌手 → 立刻点 B 歌手」会把
///    A 的简介填进 B 的页面。
/// 2. **分页锁**：`isLoadingMore` 为真时 `loadMore()` 直接返回，
///    否则一次滚到底能连发十几页相同 offset 的请求。
/// 3. **分块降级**：五块内容各自独立失败。专辑挂了不影响热门歌曲显示 ——
///    早期把五块塞进一个 `ArtistDetail` 一次性解析，任一接口 502 就是整页白屏。
@MainActor
final class ArtistProfileSession: ObservableObject {

    // MARK: - 歌手资料（无分页）
    @Published private(set) var profile: ArtistProfile?
    @Published private(set) var isLoadingProfile = false
    @Published private(set) var profileError: String?

    // MARK: - 歌手详情（简介）
    @Published private(set) var intro: ArtistIntro?
    @Published private(set) var isLoadingIntro = false
    @Published private(set) var introError: String?

    // MARK: - 热门歌曲（来自 artist/top/song，无分页）
    @Published private(set) var hotSongs: [Song] = []
    @Published private(set) var isLoadingHighlights = false

    // MARK: - 全部歌曲（分页）
    @Published private(set) var songs: [Song] = []
    @Published private(set) var songsTotal: Int = 0
    @Published private(set) var isLoadingSongs = false
    @Published private(set) var isLoadingMoreSongs = false
    @Published private(set) var songsError: String?
    private var songsHasMore = true

    // MARK: - 专辑（分页）
    @Published private(set) var albums: [Album] = []
    @Published private(set) var isLoadingAlbums = false
    @Published private(set) var isLoadingMoreAlbums = false
    @Published private(set) var albumsError: String?
    private var albumsHasMore = true
    /// `/artist/album` 的响应里回带了 `followed`，关注按钮的初值就来自这里
    @Published private(set) var isFollowed: Bool?

    // MARK: - MV（分页）
    @Published private(set) var mvs: [ArtistMV] = []
    @Published private(set) var isLoadingMVs = false
    @Published private(set) var isLoadingMoreMVs = false
    @Published private(set) var mvsError: String?
    private var mvsHasMore = true

    // MARK: - 相似歌手
    @Published private(set) var similarArtists: [Artist] = []

    /// 当前歌手 id。`reset()` 之外的换人入口只有它。
    private(set) var artistID: String
    private var generation = 0

    private let provider: any ArtistProfileProviding
    /// 「全部歌曲」每页条数。网易云这个接口单页上限很高，
    /// 50 条对 List 来说一屏多一点，翻页次数可控。
    private let songPageSize = 50
    private let albumPageSize = 30
    private let mvPageSize = 30

    init(artistID: String, provider: any ArtistProfileProviding = NeteaseProvider.shared) {
        self.artistID = artistID
        self.provider = provider
    }

    // MARK: - 生命周期
    //
    // 注意这三个方法**只改状态、不发请求**。加载一律由调用方（视图的 `.task`）
    // 显式驱动 —— 早期 `switchTo` 内部自带 `Task { loadProfile() }`，于是
    // 「同一个歌手 + 登录态变了」这条路径会整个被 `guard newID != artistID`
    // 短路掉，什么都不重载。

    /// 换歌手（同一个 session 复用，视图重建时不重新拉）
    func switchTo(artistID newID: String) {
        guard newID != artistID else { return }
        reset()
        artistID = newID
    }

    /// 登录态变化后重载：收藏状态与「已关注」都随账号变。
    func reloadForDataContext() {
        reset()
    }

    /// 递增代次并清空全部内容。
    ///
    /// 清空而不是保留旧内容：歌手页可能已经换人了，
    /// 留着上一个歌手的歌单比显示空态更糟。
    func reset() {
        generation += 1
        profile = nil
        isLoadingProfile = false
        profileError = nil
        intro = nil
        isLoadingIntro = false
        introError = nil
        hotSongs = []
        isLoadingHighlights = false
        songs = []
        songsTotal = 0
        isLoadingSongs = false
        isLoadingMoreSongs = false
        songsError = nil
        songsHasMore = true
        albums = []
        isLoadingAlbums = false
        isLoadingMoreAlbums = false
        albumsError = nil
        albumsHasMore = true
        isFollowed = nil
        mvs = []
        isLoadingMVs = false
        isLoadingMoreMVs = false
        mvsError = nil
        mvsHasMore = true
        similarArtists = []
    }

    // MARK: - 资料 / 热门 / 相似歌手

    /// 头图 + 简介 + 计数 + 关注状态。这一块失败整页只能显示错误态。
    func loadProfile() async {
        let token = generation
        isLoadingProfile = true
        profileError = nil
        defer { if generation == token { isLoadingProfile = false } }
        do {
            let loaded = try await provider.fetchArtistProfile(id: artistID)
            guard generation == token, !Task.isCancelled else { return }
            profile = loaded
            isFollowed = loaded.isFollowed
        } catch {
            guard generation == token else { return }
            profileError = error.ctUserMessage
        }
    }

    /// 热门歌曲 + 相似歌手。两者都是「锦上添花」，失败静默降级。
    func loadHighlights() async {
        guard !isLoadingHighlights else { return }
        isLoadingHighlights = true
        defer { isLoadingHighlights = false }
        let token = generation
        async let hot = provider.fetchHotArtistSongs(id: artistID)
        async let similar = provider.fetchSimilarArtists(artistID: artistID)
        if let list = try? await hot {
            guard generation == token, !Task.isCancelled else { return }
            hotSongs = list
        }
        if let list = try? await similar {
            guard generation == token, !Task.isCancelled else { return }
            // 相似列表会把自己也带回来（实测第一个就是自己）
            similarArtists = list.filter { $0.id != artistID }.prefix(12).map { $0 }
        }
    }

    // MARK: - 简介

    func loadIntro() async {
        let token = generation
        isLoadingIntro = true
        introError = nil
        defer { if generation == token { isLoadingIntro = false } }
        do {
            let loaded = try await provider.fetchArtistIntro(id: artistID)
            guard generation == token, !Task.isCancelled else { return }
            intro = loaded
        } catch {
            guard generation == token else { return }
            introError = error.ctUserMessage
        }
    }

    // MARK: - 全部歌曲

    var canLoadMoreSongs: Bool { songsHasMore && !songs.isEmpty && !isLoadingMoreSongs }

    func loadSongs() async {
        guard !isLoadingSongs else { return }
        let token = generation
        isLoadingSongs = true
        songsError = nil
        defer { if generation == token { isLoadingSongs = false } }
        do {
            let page = try await provider.fetchArtistSongs(
                id: artistID, offset: 0, limit: songPageSize, order: "hot"
            )
            guard generation == token, !Task.isCancelled else { return }
            songs = page.songs
            songsTotal = page.total
            songsHasMore = page.hasMore
        } catch {
            guard generation == token else { return }
            songsError = error.ctUserMessage
        }
    }

    /// 翻页。**offset 由已加载条数推导**，不另存游标：
    /// 网易云这个接口是 offset 分页，中途被 `invalidateCache` 冲掉也不会错位。
    func loadMoreSongs() async {
        guard canLoadMoreSongs else { return }
        let token = generation
        isLoadingMoreSongs = true
        defer { if generation == token { isLoadingMoreSongs = false } }
        do {
            let page = try await provider.fetchArtistSongs(
                id: artistID, offset: songs.count, limit: songPageSize, order: "hot"
            )
            guard generation == token, !Task.isCancelled else { return }
            // 迟到页可能与已加载的有重叠，按 id 去重（网易云偶尔会插歌）
            let existing = Set(songs.map(\.id))
            songs.append(contentsOf: page.songs.filter { !existing.contains($0.id) })
            songsTotal = max(songsTotal, page.total)
            songsHasMore = page.hasMore
        } catch {
            guard generation == token else { return }
            // 翻页失败不清空已有内容，只提示；`songsHasMore` 保持 true 可重试
            songsError = error.ctUserMessage
        }
    }

    // MARK: - 专辑

    var canLoadMoreAlbums: Bool { albumsHasMore && !albums.isEmpty && !isLoadingMoreAlbums }

    func loadAlbums() async {
        guard !isLoadingAlbums else { return }
        let token = generation
        isLoadingAlbums = true
        albumsError = nil
        defer { if generation == token { isLoadingAlbums = false } }
        do {
            let page = try await provider.fetchArtistAlbums(
                id: artistID, offset: 0, limit: albumPageSize
            )
            guard generation == token, !Task.isCancelled else { return }
            albums = page.albums
            albumsHasMore = page.hasMore
            // followed 只在第一页带回来，不要被后续页的 nil 覆盖
            if let followed = page.isFollowed { isFollowed = followed }
        } catch {
            guard generation == token else { return }
            albumsError = error.ctUserMessage
        }
    }

    func loadMoreAlbums() async {
        guard canLoadMoreAlbums else { return }
        let token = generation
        isLoadingMoreAlbums = true
        defer { if generation == token { isLoadingMoreAlbums = false } }
        do {
            let page = try await provider.fetchArtistAlbums(
                id: artistID, offset: albums.count, limit: albumPageSize
            )
            guard generation == token, !Task.isCancelled else { return }
            let existing = Set(albums.map(\.id))
            albums.append(contentsOf: page.albums.filter { !existing.contains($0.id) })
            albumsHasMore = page.hasMore
        } catch {
            guard generation == token else { return }
            albumsError = error.ctUserMessage
        }
    }

    // MARK: - MV

    var canLoadMoreMVs: Bool { mvsHasMore && !mvs.isEmpty && !isLoadingMoreMVs }

    func loadMVs() async {
        guard !isLoadingMVs else { return }
        let token = generation
        isLoadingMVs = true
        mvsError = nil
        defer { if generation == token { isLoadingMVs = false } }
        do {
            let page = try await provider.fetchArtistMVs(id: artistID, offset: 0, limit: mvPageSize)
            guard generation == token, !Task.isCancelled else { return }
            mvs = page.mvs
            mvsHasMore = page.hasMore
        } catch {
            guard generation == token else { return }
            mvsError = error.ctUserMessage
        }
    }

    func loadMoreMVs() async {
        guard canLoadMoreMVs else { return }
        let token = generation
        isLoadingMoreMVs = true
        defer { if generation == token { isLoadingMoreMVs = false } }
        do {
            let page = try await provider.fetchArtistMVs(id: artistID, offset: mvs.count, limit: mvPageSize)
            guard generation == token, !Task.isCancelled else { return }
            let existing = Set(mvs.map(\.id))
            mvs.append(contentsOf: page.mvs.filter { !existing.contains($0.id) })
            mvsHasMore = page.hasMore
        } catch {
            guard generation == token else { return }
            mvsError = error.ctUserMessage
        }
    }

    // MARK: - 关注

    /// 关注状态变更后回写，避免下次点按钮时初值还是旧的。
    func setFollowed(_ value: Bool) {
        isFollowed = value
    }
}
