import Foundation
import Combine

/// 「我的音乐」的资料库数据：收藏的专辑 / 歌手 / 电台 + 收藏数量汇总。
///
/// 单独成 store 而不是塞进 `AppState`：
/// `AppState` 已经持有登录态、队列、收藏歌曲这些**全局**状态，
/// 资料库是「某一页的数据」，跟着页面创建销毁更合适。
@MainActor
final class LibraryStore: ObservableObject {

    // MARK: - 输出

    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [Artist] = []
    @Published private(set) var radios: [RadioStation] = []
    @Published private(set) var counts: [String: Int] = [:]

    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// 各分区独立成败：歌手列表挂了不该让专辑列表也消失
    @Published private(set) var failedSections: Set<Section> = []

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case albums, artists, radios
        var id: String { rawValue }
        var title: String {
            switch self {
            case .albums: return "专辑"
            case .artists: return "歌手"
            case .radios: return "电台"
            }
        }
        var systemImage: String {
            switch self {
            case .albums: return "square.stack"
            case .artists: return "person.wave.2"
            case .radios: return "dot.radiowaves.left.and.right"
            }
        }
    }

    private let provider = NeteaseProvider.shared
    private var loadToken = UUID()

    // MARK: - 加载

    func load(isLoggedIn: Bool) async {
        let token = UUID()
        loadToken = token
        errorMessage = nil
        failedSections = []

        guard isLoggedIn else {
            albums = []; artists = []; radios = []; counts = [:]
            isLoading = false
            return
        }

        isLoading = albums.isEmpty && artists.isEmpty && radios.isEmpty

        // 四个请求并发；单个失败只标记该分区，不影响其他分区
        async let a: Void = loadAlbums(token: token)
        async let b: Void = loadArtists(token: token)
        async let c: Void = loadRadios(token: token)
        async let d: Void = loadCounts(token: token)
        _ = await (a, b, c, d)

        guard loadToken == token, !Task.isCancelled else { return }
        isLoading = false
    }

    private func loadAlbums(token: UUID) async {
        do {
            let loaded = try await provider.fetchSubscribedAlbums(limit: 60)
            guard loadToken == token, !Task.isCancelled else { return }
            albums = loaded
        } catch {
            guard loadToken == token else { return }
            CTLog.general.error("加载收藏专辑失败: \(CTLog.sanitize(error.localizedDescription))")
            failedSections.insert(.albums)
        }
    }

    private func loadArtists(token: UUID) async {
        do {
            let loaded = try await provider.fetchSubscribedArtists(limit: 60)
            guard loadToken == token, !Task.isCancelled else { return }
            artists = loaded
        } catch {
            guard loadToken == token else { return }
            CTLog.general.error("加载关注歌手失败: \(CTLog.sanitize(error.localizedDescription))")
            failedSections.insert(.artists)
        }
    }

    private func loadRadios(token: UUID) async {
        do {
            let loaded = try await provider.fetchSubscribedRadios(limit: 60)
            guard loadToken == token, !Task.isCancelled else { return }
            radios = loaded
        } catch {
            guard loadToken == token else { return }
            CTLog.general.error("加载收藏电台失败: \(CTLog.sanitize(error.localizedDescription))")
            failedSections.insert(.radios)
        }
    }

    private func loadCounts(token: UUID) async {
        do {
            let loaded = try await provider.fetchUserCounts()
            guard loadToken == token, !Task.isCancelled else { return }
            counts = loaded
        } catch {
            // 数量汇总是锦上添花，失败不提示
            guard loadToken == token else { return }
            CTLog.general.error("加载收藏统计失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    // MARK: - 取消收藏

    /// 取消收藏专辑/歌手/电台，并同步本地列表。
    /// 乐观更新 + 失败回滚。
    @discardableResult
    func unsubscribe(_ target: SubscribeTarget, name: String) async -> Bool {
        do {
            switch target {
            case .playlist(let id): try await provider.subscribePlaylist(id: id, subscribe: false)
            case .album(let id): try await provider.subscribeAlbum(id: id, subscribe: false)
            case .artist(let id): try await provider.subscribeArtist(id: id, subscribe: false)
            case .radio(let id): try await provider.subscribeRadio(id: id, subscribe: false)
            }
            // 本地立刻移除，避免「取消成功但列表还在」
            switch target {
            case .album: albums.removeAll { $0.id == target.id }
            case .artist: artists.removeAll { $0.id == target.id }
            case .radio: radios.removeAll { $0.id == target.id }
            case .playlist: break  // 由 AppState.userPlaylists 管
            }
            // 计数字典的键是「收藏歌单 / 关注歌手 / 收藏电台」（见 fetchUserCounts），
            // 不是 displayName（「歌单 / 歌手 / 电台」）—— 原先永远匹配不上。
            if let key = target.countKey, let value = counts[key], value > 0 {
                counts[key] = value - 1
            }
            CTLog.general.info("已取消收藏\(target.displayName)：\(name)")
            return true
        } catch {
            CTLog.general.error("取消收藏失败: \(CTLog.sanitize(error.localizedDescription))")
            errorMessage = "取消收藏失败：\(error.ctUserMessage)"
            return false
        }
    }
}
