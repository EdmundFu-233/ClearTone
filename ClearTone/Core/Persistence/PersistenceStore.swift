import Foundation

/// 简单 JSON 持久化存储（队列、设置）
public final class PersistenceStore: Sendable {
    public static let shared = PersistenceStore()

    private let queueKey = "cleartone.persisted.queue"
    private let settingsKey = "cleartone.persisted.settings"

    private init() {}

    /// 建目录只做一次：原先是计算属性，每次访问都执行一次 mkdir 系统调用，
    /// 而 saveQueue 每 5 秒就会被调用一次。
    /// 用 let + 一次性求值，也保证单元测试通过环境变量注入的目录能被缓存住。
    private let storageURL: URL = {
        let dir: URL
        // 单元测试可通过环境变量把持久化隔离到临时目录，避免覆盖开发机的真实队列
        let override = getenv("CLEARTONE_TEST_STORAGE_DIR").map { String(cString: $0) }
        if let override, !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("ClearTone", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func saveQueue(_ queue: PersistedQueue) {
        let url = storageURL.appendingPathComponent("queue.json")
        // 原子写：避免崩溃/断电时留下半截 JSON 导致队列丢失
        try? JSONEncoder().encode(queue).write(to: url, options: [.atomic])
    }

    func loadQueue() -> PersistedQueue? {
        let url = storageURL.appendingPathComponent("queue.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedQueue.self, from: data)
    }

    public func clearQueue() {
        try? FileManager.default.removeItem(at: queueFileURL)
        Task { await PersistenceWriter.shared.reset() }
    }

    // MARK: - 后台合并写

    /// 队列与最近播放的后台合并写入器。
    ///
    /// 原先 `saveQueue` 由 @MainActor 上的调用方同步执行：1000 首队列约 400KB JSON，
    /// 每 5 秒一次主线程编码 + 原子写，用户感知为「进度条每 5 秒卡一下」。
    /// 这里把编码与落盘挪到后台串行 actor，并用抖动窗口合并高频写入。
    actor PersistenceWriter {
        static let shared = PersistenceWriter()

        private var pendingQueue: PersistedQueue?
        private var pendingRecent: [Song]?
        private var flushTask: Task<Void, Never>?
        /// 抖动窗口：这段时间内的重复写入会被合并成一次落盘
        private static let debounce: Duration = .milliseconds(800)
        /// 单次待写快照的体积上限，超过则跳过（避免异常大的队列拖垮写入）
        private static let maxBytes = 8 * 1024 * 1024

        func schedule(queue: PersistedQueue) {
            pendingQueue = queue
            scheduleFlush()
        }

        func schedule(recentSongs: [Song]) {
            pendingRecent = recentSongs
            scheduleFlush()
        }

        /// 退出/切歌等需要立即落盘时调用
        func flushNow() async {
            flushTask?.cancel()
            flushTask = nil
            try? await writePending()
        }

        /// 「清空队列」用：丢弃所有待写内容，避免清空后又被旧快照写回来
        func reset() {
            flushTask?.cancel()
            flushTask = nil
            pendingQueue = nil
            pendingRecent = nil
        }

        private func scheduleFlush() {
            guard flushTask == nil else { return }
            flushTask = Task {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
                try? await writePending()
            }
        }

        private func writePending() async throws {
            let queue = pendingQueue
            let recent = pendingRecent
            pendingQueue = nil
            pendingRecent = nil
            flushTask = nil
            guard let queue, let recent else { return }
            try await Task.detached(priority: .utility) {
                try Self.writeSnapshots(queue: queue, recent: recent)
            }.value
        }

        private static func writeSnapshots(queue: PersistedQueue, recent: [Song]) throws {
            let queueData = try JSONEncoder().encode(queue)
            if queueData.count <= maxBytes {
                try queueData.write(to: PersistenceStore.shared.queueFileURL, options: [.atomic])
            }
            // 最近播放与设置同源，仍写 UserDefaults，保持与 loadRecentSongs 的读取路径一致
            if let recentData = try? JSONEncoder().encode(recent), recentData.count <= maxBytes {
                UserDefaults.standard.set(recentData, forKey: PersistenceStore.shared.settingKey(for: "recentSongs"))
            }
        }
    }

    /// 供后台写入器在非隔离上下文中使用（URL 是不可变值，读取本身线程安全）
    fileprivate var queueFileURL: URL {
        storageURL.appendingPathComponent("queue.json")
    }

    fileprivate func settingKey(for key: String) -> String {
        "\(settingsKey).\(key)"
    }

    // MARK: - 设置（UserDefaults）

    public func saveSetting<T: Codable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: "\(settingsKey).\(key)")
        }
    }

    public func loadSetting<T: Codable>(forKey key: String, as type: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: "\(settingsKey).\(key)") else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func removeSetting(forKey key: String) {
        UserDefaults.standard.removeObject(forKey: "\(settingsKey).\(key)")
    }

    // MARK: - 离线缓存（账号 / 喜欢的歌曲）

    /// 缓存账户资料，启动时先展示再后台校验，避免登录态闪烁
    public func saveCachedAccount(_ account: AccountInfo) {
        saveSetting(account, forKey: "cachedAccount")
    }

    public func loadCachedAccount() -> AccountInfo? {
        loadSetting(forKey: "cachedAccount", as: AccountInfo.self)
    }

    public func clearCachedAccount() {
        removeSetting(forKey: "cachedAccount")
    }

    /// 缓存喜欢的歌曲，离线也能立即渲染红心状态与列表
    public func saveCachedLikedSongs(_ songs: [Song]) {
        saveSetting(songs, forKey: "cachedLikedSongs")
    }

    public func loadCachedLikedSongs() -> [Song] {
        loadSetting(forKey: "cachedLikedSongs", as: [Song].self) ?? []
    }

    /// 全量收藏 id（约 60KB）。心形状态的判断依据，必须与详情列表分开存：
    /// 详情列表可能因分页/失败而不完整，id 集合不能受它影响。
    public func saveCachedLikedSongIDs(_ ids: [String]) {
        saveSetting(ids, forKey: "cachedLikedSongIDs")
    }

    public func loadCachedLikedSongIDs() -> [String] {
        loadSetting(forKey: "cachedLikedSongIDs", as: [String].self) ?? []
    }

    public func clearCachedLikedSongs() {
        removeSetting(forKey: "cachedLikedSongs")
        removeSetting(forKey: "cachedLikedSongIDs")
    }

    /// 缓存用户歌单，冷启动时侧栏先渲染再后台刷新
    public func saveCachedUserPlaylists(_ playlists: [Playlist]) {
        saveSetting(playlists, forKey: "cachedUserPlaylists")
    }

    public func loadCachedUserPlaylists() -> [Playlist] {
        loadSetting(forKey: "cachedUserPlaylists", as: [Playlist].self) ?? []
    }

    public func clearCachedUserPlaylists() {
        removeSetting(forKey: "cachedUserPlaylists")
    }

    /// 本地音乐库（文件路径列表，启动时重新解析元数据）
    public func saveLocalLibrary(_ paths: [String]) {
        saveSetting(paths, forKey: "localLibrary")
    }

    public func loadLocalLibrary() -> [String] {
        loadSetting(forKey: "localLibrary", as: [String].self) ?? []
    }

    /// 最近播放历史
    public func saveRecentSongs(_ songs: [Song]) {
        saveSetting(songs, forKey: "recentSongs")
    }

    public func loadRecentSongs() -> [Song] {
        loadSetting(forKey: "recentSongs", as: [Song].self) ?? []
    }
}

// MARK: - 设置模型
public struct AppSettings: Codable, Sendable {
    public var themeMode: CTThemeMode = .system
    public var resumePlaybackOnLaunch: Bool = false
    public var closeToMenuBar: Bool = true
    public var performanceMode: PerformanceMode = .auto
    public var spectrumMode: SpectrumMode = .real
    public var lyricOffset: TimeInterval = 0
    public var preferredQuality: AudioQuality.QualityLevel = .exhigh
    public var audioCacheEnabled: Bool = true   // 播放过的歌缓存为 96kbps OPUS
    public var customAPIServer: String = ""  // 开发/高级配置

    public enum PerformanceMode: String, Codable, CaseIterable, Sendable {
        case auto = "自动"
        case saver = "节能"
        case quality = "高质量"
        case static_ = "静态"
    }

    public enum SpectrumMode: String, Codable, CaseIterable, Sendable {
        case real = "真实频谱"
        case ambient = "环境动画"
        case off = "关闭"
    }
}
