import Foundation

/// 简单 JSON 持久化存储（队列、设置）
public final class PersistenceStore: Sendable {
    public static let shared = PersistenceStore()

    private let queueKey = "cleartone.persisted.queue"
    private let settingsKey = "cleartone.persisted.settings"

    private init() {}

    private var storageURL: URL {
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
    }

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
        try? FileManager.default.removeItem(at: storageURL.appendingPathComponent("queue.json"))
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

    public func clearCachedLikedSongs() {
        removeSetting(forKey: "cachedLikedSongs")
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
