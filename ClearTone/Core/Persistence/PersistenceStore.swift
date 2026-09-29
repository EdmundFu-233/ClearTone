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
    /// 持久化根目录。`DemoAudioGenerator` 的测试音频目录也挂在它下面，
    /// 这样 `CLEARTONE_TEST_STORAGE_DIR` 一个开关就能把两者一起隔离。
    nonisolated public static let storageRoot: URL = {
        let override = getenv("CLEARTONE_TEST_STORAGE_DIR").map { String(cString: $0) }
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClearTone", isDirectory: true)
    }()

    private let storageURL: URL = {
        let dir = PersistenceStore.storageRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        purgeOrphanedDemoAudio(in: dir)
        return dir
    }()

    /// 删掉演示模式留下的 `DemoAudio/`（约 16MB 的合成 WAV）。
    ///
    /// 演示模式移除后生产代码再也不生成或读取它，但老安装的目录会一直留在磁盘上。
    /// 挂在 `storageURL` 的初始化里：那是全 App 第一个碰到持久化根目录的地方，
    /// 且只求值一次 —— 不会每次 `saveQueue` 都去 stat 一遍。
    ///
    /// 无条件删是安全的：`DemoAudioGenerator` 是按需重建的（测试里
    /// `ensureFiles()` 会重新合成），删掉只会在下次用到时重新生成。
    private static func purgeOrphanedDemoAudio(in root: URL) {
        let dir = root.appendingPathComponent("DemoAudio", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
            CTLog.general.info("已清理演示模式遗留的音频目录")
        } catch {
            // 删不掉（权限/文件占用）不是致命问题，下个版本再试
            CTLog.general.error("清理演示音频目录失败: \(CTLog.sanitize(error.localizedDescription))")
        }
    }

    func saveQueue(_ queue: PersistedQueue) {
        let url = storageURL.appendingPathComponent("queue.json")
        // 原子写：避免崩溃/断电时留下半截 JSON 导致队列丢失
        try? JSONEncoder().encode(queue).write(to: url, options: [.atomic])
    }

    func loadQueue() -> PersistedQueue? {
        let url = storageURL.appendingPathComponent("queue.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard var queue = try? JSONDecoder().decode(PersistedQueue.self, from: data) else { return nil }
        queue.items = queue.items.filter { Self.isNotLegacyDemoSong($0.song) }
        // items 为空也要照常返回：调用方靠它恢复音量/播放模式/音质。
        return queue
    }

    /// 迁移：演示模式已移除，它留下的歌曲 id 固定是 `demo-1`…`demo-20`。
    ///
    /// `SongSource` 的容错解码把它们降级成了 `.netease`，留着只会变成永远播不了的行
    /// （还会拿不存在的 id 去打网易云接口）。队列、liked 缓存、最近播放三处都要过这一道。
    private static func isNotLegacyDemoSong(_ song: Song) -> Bool {
        !song.id.hasPrefix("demo-")
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

        /// 排入快照并**在同一 actor 上立刻落盘**。
        ///
        /// 退出时不能用「先 `schedule` 再另起一个 Task `flushNow`」：
        /// 两个 Task 在 actor 上的先后没有保证，`flushNow` 完全可能先跑而刷了个空；
        /// 而且 `applicationWillTerminate` 返回后进程立刻结束，那两个 Task
        /// 根本没机会执行。合成一个原子方法才既有序又等得到。
        func persistAndFlush(queue: PersistedQueue?, recentSongs: [Song]?) async {
            flushTask?.cancel()
            flushTask = nil
            if let queue { pendingQueue = queue }
            if let recentSongs { pendingRecent = recentSongs }
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
            // 两条链路各自独立触发：队列编辑/播放进度只 schedule(queue:)，
            // 切歌才同时 schedule(recent:)。所以必须**分别**判空、分别写。
            //
            // 原来的 `guard let queue, let recent else { return }` 是合取守卫，
            // 而上面两行已经先把 pending 清空了 —— 于是「只改了队列」这一轮
            // 的快照被永久丢弃（不是延后重试）。后果是：切歌之后的所有队列变更
            // （清空、加歌、拖动排序、播放模式、音量、音质、播放进度）
            // 一律不落盘，⌘Q 退出时也一样。
            if let queue {
                try await Task.detached(priority: .utility) {
                    try Self.writeQueueSnapshot(queue)
                }.value
            }
            if let recent {
                try await Task.detached(priority: .utility) {
                    try Self.writeRecentSnapshot(recent)
                }.value
            }
        }

        private static func writeQueueSnapshot(_ queue: PersistedQueue) throws {
            let data = try JSONEncoder().encode(queue)
            guard data.count <= maxBytes else { return }
            try data.write(to: PersistenceStore.shared.queueFileURL, options: [.atomic])
        }

        /// 最近播放与设置同源，仍写 UserDefaults，保持与 `loadRecentSongs` 的读取路径一致
        private static func writeRecentSnapshot(_ recent: [Song]) throws {
            guard let data = try? JSONEncoder().encode(recent), data.count <= maxBytes else { return }
            UserDefaults.standard.set(
                data, forKey: PersistenceStore.shared.settingKey(for: "recentSongs")
            )
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
        (loadSetting(forKey: "cachedLikedSongs", as: [Song].self) ?? [])
            .filter { Self.isNotLegacyDemoSong($0) }
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
        (loadSetting(forKey: "recentSongs", as: [Song].self) ?? [])
            .filter { Self.isNotLegacyDemoSong($0) }
    }
}

// MARK: - 设置模型
public struct AppSettings: Codable, Sendable {
    public var themeMode: CTThemeMode = .system
    public var resumePlaybackOnLaunch: Bool = false
    /// 点「关闭」时对应用做什么。
    public enum CloseBehavior: String, Codable, CaseIterable, Sendable {
        /// 关窗后继续在后台播放（菜单栏不出现图标）
        case keepPlaying = "继续后台播放"
        /// 关窗后缩到菜单栏
        case minimizeToMenuBar = "缩到菜单栏"
        /// 关窗即退出应用
        case quit = "退出应用"

        public var displayName: String { rawValue }

        var help: String {
            switch self {
            case .keepPlaying:
                return "关闭窗口但继续在后台播放，菜单栏不出现图标（可用 ⌘⇧M 打开迷你播放器）"
            case .minimizeToMenuBar:
                return "关闭窗口并在菜单栏显示图标，从那里控制播放"
            case .quit:
                return "关闭窗口即完全退出（等同 ⌘Q）"
            }
        }
    }

    /// 关窗行为。默认 `.keepPlaying` —— 与 `applicationShouldTerminateAfterLastWindowClosed`
    /// 原来的返回值一致，不改变既有用户的习惯。
    public var closeBehavior: CloseBehavior = .keepPlaying

    /// 菜单栏是否**常驻**（与 `closeBehavior` 正交）。
    ///
    /// 打开后只要应用在运行就显示菜单栏图标，不管窗口开不开；
    /// 关掉时图标只在 `.minimizeToMenuBar` 且没有可见窗口时出现。
    /// 判定规则集中在 `MenuBarVisibilityPolicy`，不在视图里散落。
    public var menuBarAlwaysVisible: Bool = false

    /// 迷你播放器是否置顶
    public var miniPlayerAlwaysOnTop: Bool = true
    public var performanceMode: PerformanceMode = .auto
    /// 默认 `.ambient`。
    ///
    /// 原先默认 `.real`（真实频谱），但**没有任何代码产生过频谱数据** ——
    /// MTAudioProcessingTap 那条路已被删除（会让缓存的 OPUS 播放卡在缓冲中），
    /// spectrum 数组恒为全零。于是「真实频谱」这个选项选中后
    /// 与「环境动画」渲染完全一样：spec §13 明令禁止的「假频谱」。
    /// 现在真实频谱已从选项里移除，不再对用户承诺做不到的事。
    public var spectrumMode: SpectrumMode = .ambient
    public var lyricOffset: TimeInterval = 0
    /// 默认音质。**默认是「自动」而不是某一档** ——
    /// 自动的具体档位由账号是否 VIP 决定（见 `SongQualityPolicy.defaultLevel`）。
    ///
    /// 原来这里是 `.exhigh` 写死，于是「没设置过」和「用户主动选了极高」
    /// 是同一个值，无法在 VIP 出现时调整默认值而不覆盖用户的选择。
    /// `.unknown` 承担「自动」这个第三态（它本来就不出现在音质菜单里）。
    public var preferredQuality: AudioQuality.QualityLevel = SongQualityPolicy.autoLevel
    public var audioCacheEnabled: Bool = true   // 播放过的歌缓存为 128kbps OPUS
    // 原先有 `customAPIServer`：设置页里是个可编辑的 TextField，
    // 但**没有任何代码读取它** —— 辅助进程地址由 HelperProcessManager 每次
    // 启动随机生成（回环 + 随机端口 + 一次性令牌），无法从外部指定。
    // 作为「可编辑但无效果」的控件违反 spec §8/§13，已连同设置页一起移除。

    public enum PerformanceMode: String, Codable, CaseIterable, Sendable {
        case auto = "自动"
        case saver = "节能"
        case quality = "高质量"
        case static_ = "静态"
    }

    /// 背景呈现方式。
    ///
    /// **没有 `real`（真实频谱）选项** —— 曾经有，但它拿不到真实采样：
    /// `MTAudioProcessingTapStorage` 不在 SDK 头文件里，
    /// `MTAudioProcessingTapGetStorage` 返回的是 `void**` 而不是回调指针，
    /// 没法安全地把处理器交给实时线程；强行挂 tap 会与 AVPlayer 重新协商
    /// 音频格式，导致 48kHz OPUS/CAF 缓存直接播不出来
    /// （见 `docs/architecture.md` 与 `docs/optimization-plan.md` P1-21）。
    ///
    /// 真要实现，路径是 `AVAssetReader` 对**已缓存的本地文件**做离线分析 ——
    /// 那只能覆盖缓存过的歌，远程流无从下手，所以也不适合作为通用选项。
    public enum SpectrumMode: String, Codable, CaseIterable, Sendable {
        case ambient = "环境动画"
        case off = "关闭"

        /// 容错解码：未知值一律落到 `.ambient`。
        ///
        /// 老用户存下过 `"真实频谱"`（`real` 已被移除），这个枚举必须自己能扛住。
        /// 更大的防线在 `AppSettings.init(from:)` —— 逐字段兜底，
        /// 一个枚举不认识不会连累主题、音质、缓存开关。
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = SpectrumMode(rawValue: raw) ?? .ambient
        }
    }

    /// 全部字段取默认值。
    ///
    /// 必须显式写：一旦自定义了 `init(from:)`，编译器就不再合成
    /// 那个「每个参数都有默认值」的成员初始化器，`AppSettings()` 会报
    /// missing argument for parameter 'from'。
    public init() {}

    /// 字段级容错解码。
    ///
    /// 编译器合成的 `init(from:)` 是**整体成败**的：任何一个键的值不认识
    /// （老版本写下的旧枚举、手改过的偏好文件、写到一半的 JSON），
    /// 整个 `decode` 抛错，`loadSetting` 兜底成 `AppSettings()` ——
    /// 用户的音质、歌词偏移、缓存开关全被悄悄重置，而界面上看不出发生过任何事。
    ///
    /// 这里改成逐字段 `decodeIfPresent` + 各自兜底：坏一个字段只丢那一个字段。
    /// 顺带的好处是新增字段不必再担心老数据缺键。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        themeMode = value(.themeMode, CTThemeMode.system)
        resumePlaybackOnLaunch = value(.resumePlaybackOnLaunch, false)
        closeBehavior = value(.closeBehavior, CloseBehavior.keepPlaying)
        menuBarAlwaysVisible = value(.menuBarAlwaysVisible, false)
        miniPlayerAlwaysOnTop = value(.miniPlayerAlwaysOnTop, true)
        performanceMode = value(.performanceMode, PerformanceMode.auto)
        spectrumMode = value(.spectrumMode, SpectrumMode.ambient)
        lyricOffset = value(.lyricOffset, 0)
        // 缺键 = 从没设置过 = 自动。老用户存下的 `.exhigh` 是**显式值**，
        // 保持不变 —— 不擅自把别人的选择改掉，要改自己在设置页点一下。
        preferredQuality = value(.preferredQuality, SongQualityPolicy.autoLevel)
        audioCacheEnabled = value(.audioCacheEnabled, true)
    }
}
