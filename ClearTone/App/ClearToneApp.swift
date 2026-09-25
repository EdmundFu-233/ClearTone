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
    @Published var searchQuery = ""

    /// 喜欢的歌曲（本地缓存 + 服务端同步）
    @Published public private(set) var likedSongs: [Song] = []
    /// 收藏状态版本号：每次变化自增，驱动依赖视图刷新
    @Published public private(set) var likesVersion: Int = 0
    /// 会话失效后置位，UI 据此自动弹出登录
    @Published var needsReLogin = false

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
            applyLikedSongs(PersistenceStore.shared.loadCachedLikedSongs())
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
            let songs = try await provider.fetchLikedSongs()
            hasLoadedLikes = true
            applyLikedSongs(songs)
            PersistenceStore.shared.saveCachedLikedSongs(songs)
        } catch {
            CTLog.general.error("加载喜欢的歌曲失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    /// 切换收藏状态（乐观更新，失败回滚）。返回切换后的状态。
    @discardableResult
    func toggleLike(_ song: Song) async -> Bool {
        guard song.source == .netease, isLoggedIn, !isDemoMode else { return false }
        let wasLiked = likedIDs.contains(song.id)
        let previous = likedSongs

        var optimistic = likedSongs.filter { $0.id != song.id }
        if !wasLiked { optimistic.insert(song, at: 0) }
        applyLikedSongs(optimistic)

        do {
            try await provider.likeSong(id: song.id, like: !wasLiked)
            PersistenceStore.shared.saveCachedLikedSongs(likedSongs)
            return !wasLiked
        } catch {
            CTLog.general.error("收藏操作失败: \(CTLog.sanitize(error.localizedDescription))")
            applyLikedSongs(previous)
            return wasLiked
        }
    }

    private func applyLikedSongs(_ songs: [Song]) {
        likedSongs = songs
        likedIDs = Set(songs.map(\.id))
        likesVersion += 1
    }

    public enum Page: String, CaseIterable {
        case discover = "发现音乐"
        case search = "搜索"
        case myMusic = "我的音乐"
        case liked = "喜欢的音乐"
        case local = "本地音乐"
        case recent = "最近播放"
        case playlistDetail = "歌单详情"
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
