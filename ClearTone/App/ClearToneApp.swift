import SwiftUI

@main
struct ClearToneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var player = PlayerController.shared
    @StateObject private var helper = HelperProcessManager.shared
    @StateObject private var appState = AppState()
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(player)
                .environmentObject(helper)
                .environmentObject(appState)
                .environmentObject(settings)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    appDelegate.appState = appState
                    appDelegate.player = player
                    AudioCacheManager.shared.isEnabled = settings.settings.audioCacheEnabled
                    // 演示音频生成放后台：6 个 30 秒 WAV 合成约 530 万次 sin()，
                    // 放在 App.init 会阻塞主线程数秒导致白屏
                    Task.detached(priority: .utility) {
                        await DemoProvider.ensureDemoAudio()
                    }
                    Task { @MainActor in
                        await appState.restoreLoginState()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .commands {
            AppCommands()
        }

        // 迷你播放器窗口
        Window("迷你播放器", id: "mini-player") {
            MiniPlayerView()
                .environmentObject(player)
                .environmentObject(settings)
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    var player: PlayerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动辅助进程
        Task { @MainActor in
            try? await HelperProcessManager.shared.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 默认关窗后继续播放，Cmd+Q 退出
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 先保存最新队列与进度，再停止辅助进程
        player?.persistNow()
        HelperProcessManager.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // 重新打开主窗口
            for window in sender.windows {
                if window.identifier?.rawValue == "main" || window.title.contains("澄音") {
                    window.makeKeyAndOrderFront(nil)
                    return true
                }
            }
            // 没有窗口则新建
            if let window = sender.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

/// 全局应用状态
@MainActor
public class AppState: ObservableObject {
    @Published public private(set) var isDemoMode: Bool = false
    @Published var currentPage: Page = .discover
    @Published var isNowPlayingExpanded: Bool = false
    @Published var showQueue: Bool = false
    @Published public private(set) var account: AccountInfo?
    @Published public private(set) var isLoggedIn: Bool = false
    @Published var selectedPlaylistID: String?
    /// 当前打开的电台 id
    @Published var selectedRadioID: String?
    @Published var searchQuery = ""

    /// 喜欢的歌曲（本地缓存 + 服务端同步）
    @Published public private(set) var likedSongs: [Song] = []
    /// 收藏状态版本号：每次变化自增，驱动依赖视图刷新
    @Published public private(set) var likesVersion: Int = 0

    /// 用户歌单。
    ///
    /// 原先 `SidebarView` 与 `MyMusicView` 各自持有一份并各自读/写同一个
    /// 缓存 key：同一份数据被解码两次、写两次，两处可能显示不同内容
    /// （一方失败回退缓存、一方拿到新数据）。这里作为唯一 owner。
    @Published public private(set) var userPlaylists: [Playlist] = []
    @Published public private(set) var isLoadingUserPlaylists = false
    /// 加载代次：切换账号/演示模式时旧请求不得写入
    private var userPlaylistsToken = UUID()
    /// 会话失效后置位，UI 据此自动弹出登录
    @Published var needsReLogin = false

    /// **全量**喜欢歌曲 id，仅用于判断心形状态。
    ///
    /// 必须与 likedSongs 分开维护：likedSongs 是「前若干首」的详情列表，
    /// 早期两者都由 likedSongs 推导，导致 2808 首收藏里只有前 500 首能正确判断
    /// 收藏状态，其余 2308 首永远显示未收藏。
    private var likedIDs: Set<String> = []
    private var hasLoadedLikes = false
    private let provider = NeteaseProvider.shared
    private var sessionExpiryObserver: NSObjectProtocol?

    /// 登录 / 演示状态组合标识：任一变化都会触发数据重新加载
    public var dataContextKey: String { "\(isLoggedIn)-\(isDemoMode)" }

    init() {
        // 磁盘缓存的读取不在这里做：@StateObject 的初值在首帧前求值，
        // 上千首 likedSongs 的 JSON 解码会造成启动停顿。改由 restoreLoginState()
        // 在 onAppear 后异步填充（那里本来就有一处相同的读取，顺手合并）。
        // 任意请求触发会话失效时，统一清理登录态并提示重新登录
        sessionExpiryObserver = NotificationCenter.default.addObserver(
            forName: .clearToneSessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSessionExpired() }
        }
    }

    private func handleSessionExpired() {
        guard isLoggedIn || account != nil else { return }
        CTLog.security.warning("登录状态已失效，已清除本地会话，请重新登录")
        clearSession(clearLikedCache: true)
        needsReLogin = true
    }

    // MARK: - 演示模式

    func enterDemoMode() {
        isDemoMode = true
    }

    func exitDemoMode() {
        isDemoMode = false
    }

    func setDemoMode(_ enabled: Bool) {
        isDemoMode = enabled
    }

    // MARK: - 登录态

    /// 启动时恢复登录态：有 cookie 时先用缓存立即恢复，再后台校验
    func restoreLoginState() async {
        guard !isLoggedIn else { return }
        // 磁盘缓存统一在这里读一次：原先 init 与此处各读一遍（重复解码上千首 likedSongs）
        if account == nil {
            account = PersistenceStore.shared.loadCachedAccount()
        }
        if likedSongs.isEmpty {
            let cachedSongs = PersistenceStore.shared.loadCachedLikedSongs()
            // 优先用全量 id 缓存；没有（旧版本遗留）才从列表推导
            let cachedIDs = PersistenceStore.shared.loadCachedLikedSongIDs()
            applyLikedSongs(cachedSongs, ids: cachedIDs.isEmpty ? nil : cachedIDs)
        }

        let cookie = (try? KeychainStore.shared.load(for: .neteaseCookie)) ?? nil
        guard let cookie, !cookie.isEmpty else {
            // 无 cookie：清理可能残留的缓存登录态
            clearSession(clearLikedCache: false)
            return
        }

        if account != nil {
            isLoggedIn = true
        }

        do {
            if let info = try await provider.fetchAccountInfo() {
                applyAccount(info)
            } else {
                clearSession(clearLikedCache: true)
                return
            }
        } catch {
            // 网络失败时保留缓存登录态供离线使用；无缓存则视为未登录
            CTLog.security.warning("恢复登录态失败: \(CTLog.sanitize(error.localizedDescription))")
            if account == nil { isLoggedIn = false }
        }

        if isLoggedIn {
            await loadLikedSongs(force: true)
        }
    }

    /// 登录成功（供登录流程调用，会退出演示模式）
    func didLogin(account info: AccountInfo) {
        isDemoMode = false
        applyAccount(info)
        // 避免上一个账号的缓存数据串号
        Task { await provider.clearCache() }
    }

    /// 退出登录：清除服务端会话与本地缓存
    func performLogout() async {
        try? await provider.logout()
        await provider.clearCache()
        clearSession(clearLikedCache: true)
    }

    private func applyAccount(_ info: AccountInfo) {
        account = info
        isLoggedIn = true
        PersistenceStore.shared.saveCachedAccount(info)
    }

    private func clearSession(clearLikedCache: Bool) {
        account = nil
        isLoggedIn = false
        hasLoadedLikes = false
        likedIDs = []
        likedSongs = []
        likesVersion += 1
        PersistenceStore.shared.clearCachedAccount()
        if clearLikedCache {
            PersistenceStore.shared.clearCachedLikedSongs()
            PersistenceStore.shared.clearCachedUserPlaylists()
        }
    }

    // MARK: - 收藏

    func isLiked(_ songID: String) -> Bool { likedIDs.contains(songID) }

    func loadLikedSongs(force: Bool = false) async {
        guard isLoggedIn, !isDemoMode else { return }
        if hasLoadedLikes && !force { return }
        do {
            // 先取全量 id（约 60KB）—— 心形状态靠它判断，必须完整
            let ids = try await provider.fetchLikedSongIDs()
            applyLikedSongs(PersistenceStore.shared.loadCachedLikedSongs(), ids: ids)
            PersistenceStore.shared.saveCachedLikedSongIDs(ids)
            hasLoadedLikes = true

            // 详情列表随后加载，不阻塞心形状态
            let songs = try await provider.fetchLikedSongs()
            guard isLoggedIn, !isDemoMode else { return }
            applyLikedSongs(songs, ids: ids)
            PersistenceStore.shared.saveCachedLikedSongs(songs)
        } catch {
            CTLog.general.error("加载喜欢的歌曲失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    /// 加载用户歌单（侧栏与「我的音乐」共用这一个数据源）。
    ///
    /// 先用本地缓存立即填充避免空白，再拉网络。带代次令牌，
    /// 切换账号/演示模式后旧请求返回会被丢弃，不会串号。
    func loadUserPlaylists() async {
        let token = UUID()
        userPlaylistsToken = token
        guard isLoggedIn, !isDemoMode else {
            userPlaylists = []
            return
        }
        if userPlaylists.isEmpty {
            let cached = PersistenceStore.shared.loadCachedUserPlaylists()
            guard userPlaylistsToken == token, !Task.isCancelled else { return }
            userPlaylists = cached
        }
        isLoadingUserPlaylists = userPlaylists.isEmpty
        do {
            let loaded = try await provider.fetchUserPlaylists()
            guard userPlaylistsToken == token, !Task.isCancelled else { return }
            userPlaylists = loaded
            PersistenceStore.shared.saveCachedUserPlaylists(loaded)
        } catch {
            guard userPlaylistsToken == token else { return }
            // 失败时保留缓存内容，避免侧栏闪空
            CTLog.general.error("加载歌单失败: \(CTLog.sanitize(error.localizedDescription))")
        }
        guard userPlaylistsToken == token else { return }
        isLoadingUserPlaylists = false
    }

    /// 切换收藏状态（乐观更新，失败回滚）。返回切换后的状态。
    ///
    /// 关键：收藏状态只增删**单个 id**，绝不能拿 likedSongs 重建 likedIDs。
    /// 早期版本用 `applyLikedSongs(optimistic)` 顺带重建 likedIDs，
    /// 而 likedSongs 只是一份详情列表，重建会把 likedIDs 压缩成列表的规模 ——
    /// 用户有 2808 首收藏时 likedIDs 只剩几百项，于是排在列表之外的歌
    /// 点心形「看起来没反应」，因为下一次 isLiked 仍然返回 false。
    @discardableResult
    func toggleLike(_ song: Song) async -> Bool {
        guard song.source == .netease, isLoggedIn, !isDemoMode else { return false }
        let wasLiked = likedIDs.contains(song.id)
        let previousIDs = likedIDs
        let previousSongs = likedSongs

        // 乐观更新：状态集合增删单首，列表同步增删该曲
        updateLikedID(song.id, isLiked: !wasLiked)
        var optimistic = likedSongs.filter { $0.id != song.id }
        if !wasLiked { optimistic.insert(song, at: 0) }
        likedSongs = optimistic

        do {
            try await provider.likeSong(id: song.id, like: !wasLiked)
            PersistenceStore.shared.saveCachedLikedSongIDs(Array(likedIDs))
            PersistenceStore.shared.saveCachedLikedSongs(likedSongs)
            return !wasLiked
        } catch {
            CTLog.general.error("收藏操作失败: \(CTLog.sanitize(error.localizedDescription))")
            // 回滚：两处都要还原，否则状态与列表会不一致
            likedIDs = previousIDs
            likedSongs = previousSongs
            likesVersion += 1
            return wasLiked
        }
    }

    /// 应用完整收藏数据：id 集合与详情列表一起更新
    private func applyLikedSongs(_ songs: [Song], ids: [String]? = nil) {
        likedSongs = songs
        // 传入了权威 id 就用它；否则从当前列表推导（仅用于本地缓存这种
        // 「只有列表没有 id」的场景）
        likedIDs = ids.map(Set.init) ?? Set(songs.map(\.id))
        likesVersion += 1
    }

    /// 单独更新收藏状态集合（列表不变），用于增删单首的场景
    private func updateLikedID(_ songID: String, isLiked: Bool) {
        if isLiked {
            likedIDs.insert(songID)
        } else {
            likedIDs.remove(songID)
        }
        likesVersion += 1
    }

    public enum Page: String, CaseIterable {
        case discover = "发现音乐"
        case search = "搜索"
        case radio = "电台"
        case myMusic = "我的音乐"
        case liked = "喜欢的音乐"
        case local = "本地音乐"
        case recent = "最近播放"
        case playlistDetail = "歌单详情"
        case radioDetail = "电台详情"
        case settings = "设置"
    }
}

/// 设置存储
@MainActor
public class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { PersistenceStore.shared.saveSetting(settings, forKey: "appSettings") }
    }

    public init() {
        self.settings = PersistenceStore.shared.loadSetting(forKey: "appSettings", as: AppSettings.self) ?? AppSettings()
    }
}
