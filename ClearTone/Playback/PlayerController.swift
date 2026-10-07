import Foundation
import AVFoundation
import Combine
import MediaPlayer
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 封面图类型别名。保留这个名字而不是直接写 NSImage：
/// MediaPlayer 的 artwork 回调与 CoverLoader 都用它，语义比具体类型清楚。
#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif

/// 全局唯一播放控制器，管理 AVPlayer、状态、队列、系统媒体集成
@MainActor
public final class PlayerController: ObservableObject {
    public static let shared = PlayerController()

    // MARK: - Published State
    @Published public private(set) var playbackState: PlaybackState = .idle
    @Published public private(set) var duration: TimeInterval = 0
    @Published public var volume: Float = PlaybackVolumePolicy.defaultVolume {
        didSet { applyVolumeToPlayer() }
    }
    @Published public var isMuted: Bool = false {
        didSet { applyVolumeToPlayer() }
    }
    @Published public var queue = PlayQueue()
    @Published public private(set) var currentSong: Song?
    /// 最近播放（最新在前，最多 100 首，落盘持久化）
    @Published public private(set) var recentlyPlayed: [Song] = []
    /// 用户设定的全局音质偏好，可能是 `.unknown`（= 跟随账号自动）。
    /// 播放请求用的是下面那个**已解析**的 `requestedQuality`。
    @Published public private(set) var preferredQuality: AudioQuality.QualityLevel = SongQualityPolicy.autoLevel
    /// 实际用于请求的全局音质。偏好为「自动」时按 VIP 解析成具体档位。
    @Published public private(set) var requestedQuality: AudioQuality.QualityLevel = SongQualityPolicy.autoLevel
    /// 当前账号是不是 VIP。只影响「自动」档位的解析，**不改用户显式选择**。
    @Published public private(set) var isAccountVIP = false
    @Published public private(set) var actualQuality: AudioQuality?
    /// 当前播放是否来自本地音频缓存
    @Published public private(set) var isCurrentFromCache = false
    /// 单曲音质覆盖（最新在前）。有覆盖的歌一定走网易源，不用本地缓存。
    @Published public private(set) var songQualityOverrides: [SongQualityOverride] = []

    // MARK: - 倍速播放

    /// 当前播放速率。
    ///
    /// 用 `AVPlayer.defaultRate` 而不是每次 `play()` 后改 `rate`：前者会被
    /// `play()` 采纳，一次设置对后续所有 resume/seek 完成路径都生效 ——
    /// 否则每条「恢复播放」的分支都得记得补一句，漏一条就会退回 1.0x。
    @Published public private(set) var playbackRate: Float = 1.0

    /// 可选档位。与网易云/QQ 音乐一致按「常用整数倍」给，而不是连续滑杆 ——
    /// 连续调速在流媒体上会一直触发重新缓冲。
    public static let availableRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// 倍速展示文案，如「1.5×」。
    ///
    /// 刻意不用 `%.2g`：`%.2g` 是**两位有效数字**，1.25 会显示成「1.2×」、
    /// 1.75 会显示成「1.8×」—— 播放的是 1.25x，界面却说 1.2x。
    /// 档位都是 0.25 的整数倍，两位小数去掉多余的 0 就够。
    public static func rateLabel(_ rate: Float) -> String {
        guard abs(rate - 1.0) > 0.01 else { return "1×" }
        var text = String(format: "%.2f", (rate * 100).rounded() / 100)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }

    /// 把持久化的倍速吸附到可选档位。
    ///
    /// 旧队列文件里可能存过 `availableRates` 之外的任意浮点数（界面只给固定档位，
    /// 但更早的版本对写入值没有夹取）。这里必须判断**传入值**是否合法 ——
    /// 原先写的是 `availableRates.contains(playbackRate)`，而 `playbackRate`
    /// 在 `init` 阶段恒为 1.0（一定在档位里），于是 else 分支永远是死代码：
    /// 手改过的 `"playbackRate": 99` 会被原样采纳并再次落盘。
    static func resolveRestoredPlaybackRate(_ value: Float) -> Float {
        if availableRates.contains(value) { return value }
        return availableRates.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1.0
    }

    /// 切换倍速。1.0 视为「正常」，UI 上不显示倍率。
    public func setPlaybackRate(_ rate: Float) {
        let clamped = min(max(rate, 0.25), 3.0)
        guard clamped != playbackRate else { return }
        playbackRate = clamped
        applyRateToPlayer()
        // 写进队列快照：重启后不该把用户的倍速偏好丢掉
        persistState(structureChanged: false)
        updateNowPlayingInfo()
    }

    /// 是否处于非正常倍速（播放栏据此显示倍率徽标）
    public var isRateAdjusted: Bool { abs(playbackRate - 1.0) > 0.01 }

    /// 当前倍速的展示文案；正常速度时为空串。
    public var playbackRateLabel: String {
        isRateAdjusted ? Self.rateLabel(playbackRate) : ""
    }

    /// 把速率落到播放器上。`defaultRate` 对之后的 `play()` 生效；
    /// 已在播放时也要立刻改 `rate`，否则要等到下一次 resume。
    private func applyRateToPlayer() {
        guard let player else { return }
        player.defaultRate = playbackRate
        if playbackState.isPlaying || playbackState.isBuffering {
            player.rate = playbackRate
        }
    }

    // MARK: - 睡眠定时器

    /// 到点后自动暂停。`nil` 表示未设置。
    @Published public private(set) var sleepTimerEndDate: Date?
    private var sleepTimerTask: Task<Void, Never>?

    /// 睡眠定时器剩余秒数（0 表示未设置）。供 UI 每秒刷新倒计时。
    @Published public private(set) var sleepTimerRemaining: TimeInterval = 0

    /// 设置睡眠定时器。`minutes` <= 0 视为取消。
    public func setSleepTimer(minutes: Double) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        guard minutes > 0 else {
            sleepTimerEndDate = nil
            sleepTimerRemaining = 0
            return
        }
        let end = Date().addingTimeInterval(minutes * 60)
        sleepTimerEndDate = end
        sleepTimerRemaining = minutes * 60

        sleepTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                let remaining = end.timeIntervalSinceNow
                guard remaining > 0 else { break }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.sleepTimerRemaining = max(0, remaining)
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.sleepTimerEndDate = nil
                self.sleepTimerRemaining = 0
                // 只暂停，不清队列、不停止 —— 用户醒来后按播放即可继续
                self.pause()
            }
        }
    }

    public func cancelSleepTimer() {
        setSleepTimer(minutes: 0)
    }

    /// 「此刻在放什么」的可读描述：主信息是实际码率/格式，缓存状态只作次要信息。
    ///
    /// 视图（播放栏 / 全屏播放页 / 迷你播放器窗口）统一从这里取，
    /// 文案规则只在一处（`PlayingSourceFormatter`）定义。
    /// 不是 @Published：与 `actualQuality` / `isCurrentFromCache` 同生命周期，
    /// 它们变化时本属性随之变化，读它的视图本来就会重算。
    public var playingSourceInfo: PlayingSourceInfo? {
        let song = currentSong
        let meta = song.flatMap { AudioCacheManager.shared.meta(for: $0.id) }
        return PlayingSourceFormatter.describe(
            actualQuality: actualQuality,
            requestedLevel: requestedQuality,
            isFromCache: isCurrentFromCache,
            cacheFormat: meta?.formatName,
            cacheBitrateKbps: meta?.bitrateKbps,
            isCaching: song.map { AudioCacheManager.shared.cachingSongIDs.contains($0.id) } ?? false
        )
    }

    /// 播放进度。
    ///
    /// 刻意**不是** @Published：SwiftUI 对 ObservableObject 只订阅合并后的 objectWillChange，
    /// 没有属性级追踪 —— 任何 @Published 变化都会让所有 @EnvironmentObject 持有者
    /// 的整个 body 重算（PlayerBar / NowPlaying / QueuePanel / MiniPlayer / 侧栏…）。
    /// 高频进度若走 @Published，2Hz 就能把整棵视图树重算一遍。
    /// 视图侧用 `PlaybackTimeObserver` 订阅 `timePublisher` 驱动局部 @State。
    public private(set) var currentTime: TimeInterval = 0

    /// 已缓冲位置。同样不是 @Published：网络抖动时它可达数十 Hz，
    /// 而唯一用途是一个 tooltip，之前的每次更新都是纯浪费的重绘。
    public private(set) var bufferedTime: TimeInterval = 0

    /// 高频时钟：currentTime 每次变化都从这里发出，视图按需订阅。
    /// 播放中 2Hz，拖动时可达 60Hz+，但只影响订阅者，不牵动整棵树。
    public let timePublisher = PassthroughSubject<TimeInterval, Never>()

    // MARK: - Private
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var bufferObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    /// 缓冲中：playbackStalled 通知 + timeControlStatus KVO，两者都在
    /// `detachCurrentItem` 中对称移除
    private var stallObserver: NSObjectProtocol?
    private var timeControlObserver: NSKeyValueObservation?

    private var provider: MusicProvider = NeteaseProvider.shared

    private var currentGeneration: UInt = 0
    private var consecutiveFailures: Int = 0
    private let maxConsecutiveFailures = 3
    /// 同一首歌的“重新拉流”次数：首错先刷新播放地址，再次失败才自动下一首
    private var retrySongID: String = ""
    private var sameSongRetries = 0
    private var seekTask: Task<Void, Never>?
    /// 单调递增的 seek 令牌。已提交给 AVFoundation 的 seek 无法撤销，
    /// 只能靠它让过期回调自行放弃写回。
    private var seekToken: UInt64 = 0
    /// 封面下载任务，切歌时取消，避免旧封面白跑一遍网络
    private var artworkTask: Task<Void, Never>?
    /// 缓冲位置的节流发布时间
    private var lastBufferPublishAt = Date.distantPast
    /// 记录一个 target，deinit 时统一回收
    private func keepRemoteTarget(_ command: MPRemoteCommand, _ token: Any) {
        remoteCommandBox.add(command: command, token: token)
    }
    private var isUserSeeking = false
    private var autoAdvanceTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// 拉流是否正在进行（URL 请求已发出、结果还没回来）。
    /// 不能用「播放器上没有 item」来代替：自动失败切换走到队列末尾时会把状态置成
    /// .idle 且同样没有 item，那时若当成「还在准备」，resume() 就只会翻意图、
    /// 把状态改成 .loading —— 而没有任何请求在跑，界面会永远转圈。
    private var isLoadInFlight = false
    private var pendingRestoreTime: TimeInterval?
    private var pendingAutoplay = true
    private var lastProgressSaveAt = Date.distantPast
    private let progressSaveInterval: TimeInterval = 5

    /// 单曲音质覆盖的持久化 key 与容量上限
    private static let songQualityOverridesKey = "songQualityOverrides"
    private static let maxSongQualityOverrides = 200

    private init() {
        setupRemoteCommands()
        #if os(iOS)
        setupAudioSessionNotifications()
        #endif
        recentlyPlayed = PersistenceStore.shared.loadRecentSongs()
        songQualityOverrides = loadSongQualityOverrides()
        let restored = loadPersistedState()
        // 设置页的音质是权威值：队列文件里的可能落后（例如先改设置、还没播放过）。
        //
        // 语义上要分清两件事：`loadPersistedState` 往 `requestedQuality` 里塞的
        // 是**已解析**的档位（无偏好含义），而 `AppSettings.preferredQuality`
        // 是**偏好**（可能是「自动」）。所以权威值取自设置，且要重新解析一次；
        // 队列里那个值在下面被直接覆盖，不作为偏好的来源 ——
        // 拿它当偏好会把「上次因为是 VIP 才解析成无损」冻成永久显式选择。
        let settings = PersistenceStore.shared.loadSetting(forKey: "appSettings", as: AppSettings.self)
        preferredQuality = settings?.preferredQuality ?? SongQualityPolicy.autoLevel
        requestedQuality = SongQualityPolicy.effectiveGlobalLevel(
            preference: preferredQuality, isVIP: isAccountVIP
        )
        // 与设置说明一致：恢复上次播放位置，但不自动出声
        if restored, settings?.resumePlaybackOnLaunch == true {
            beginRestoredPlayback(autoplay: false)
        }
    }

    /// (所属 command, target token) 的容器。
    /// Swift 6 下 `deinit` 是 nonisolated 的，不能直接访问 PlayerController 的隔离存储，
    /// 所以放进一个独立的不可变快照盒子里。
    private let remoteCommandBox = RemoteCommandBox()

    deinit {
        // 单例下 init 只跑一次，但重建实例时若不摘掉 target，
        // 同一个按键会触发 N 次（音量跳变、连播 N 首）。
        // removeTarget 定义在 MPRemoteCommand 上，所以要连同所属 command 一起保存。
        remoteCommandBox.removeAllTargets()
    }

    // MARK: - 公共配置

    public func setProvider(_ provider: MusicProvider) {
        self.provider = provider
    }

    // MARK: - 播放控制

    public func play(songs: [Song], startAt index: Int = 0) {
        guard !songs.isEmpty else {
            // 空列表：停止当前播放并清空队列，避免“旧歌继续响 + 队列为空”的状态不一致
            clearQueue()
            return
        }
        queue.replace(with: songs, startAt: index)
        playCurrent()
    }

    public func playCurrent() {
        guard let item = queue.currentItem else { return }
        play(song: item.song)
    }

    public func play(song: Song) {
        // 用户显式发起 / 自然播完：重置失败与重试计数
        consecutiveFailures = 0
        sameSongRetries = 0
        retrySongID = song.id
        recordHistory(song)
        beginPlay(song, restoreTime: nil, autoplay: true)
    }

    private func recordHistory(_ song: Song) {
        var history = recentlyPlayed.filter { $0.id != song.id }
        history.insert(song, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        recentlyPlayed = history
        // 编码 + 落盘挪到后台：100 首 Song 的 JSON 编码在主线程是可见的尖峰，
        // 且切歌瞬间会与 persistState 叠加
        Task { await PersistenceStore.PersistenceWriter.shared.schedule(recentSongs: history) }
    }

    /// 启动一次播放。自动失败重试路径直接调用本方法（不重置失败计数）。
    private func beginPlay(_ song: Song, restoreTime: TimeInterval?, autoplay: Bool) {
        #if os(iOS)
        // 只有真要出声时才抢占音频会话。
        // `autoplay == false` 的那一路（重启恢复成暂停、暂停中切音质）只是
        // 把 item 挂上去等用户点播放 —— 这时 `setActive(true)` 会把别的 App
        // 的声音掐掉，而我们自己一个音都没出。等到 `resume()` 再激活也不迟。
        if autoplay {
            do { try activateAudioSession() } catch {
                playbackState = .failed(songID: song.id, reason: error.ctUserMessage)
                return
            }
        }
        #endif
        currentGeneration += 1
        let generation = currentGeneration
        cancelAutoAdvance()
        loadTask?.cancel()
        loadTask = nil
        // 同曲重拉（音质切换/失败重试）保留重试计数，换曲则清零
        if retrySongID != song.id {
            retrySongID = song.id
            sameSongRetries = 0
        }
        seekTask?.cancel()
        seekTask = nil
        isUserSeeking = false
        actualQuality = nil
        isCurrentFromCache = false
        // 切歌一开始就停掉旧播放器：解除 item + 暂停，旧歌曲的时间观察者
        // 随 detachCurrentItem 一起摘掉，A 的时钟不会继续写进 B 的进度。
        // 只 detach 不 teardownPlayer —— AVPlayer 实例必须跨曲复用（见
        // detachCurrentItem 的说明）：每次换歌重建会重新协商解码器与输出路由，
        // 切歌处会出现中断、延迟与 CPU 尖峰。startPlayback 会在需要时新建实例。
        detachCurrentItem()

        // 「不自动出声」的一路（重启恢复、暂停中切音质）状态直接给 .paused：
        // 拉流窗口里用户看到的必须是「▶ 播放」而不是「⏸ 暂停」——
        // 播放按钮的图标由 isPlayIntentActive 决定，.loading 恒为 true，
        // 若这里给 .loading，按钮会显示成暂停、点下去却是「开始播放」，
        // 语义正好反过来（见 togglePlayPause 的 .loading 分支）。
        playbackState = autoplay ? .loading(songID: song.id) : .paused(songID: song.id)
        currentSong = song
        duration = song.duration
        currentTime = restoreTime ?? 0
        bufferedTime = 0
        pendingRestoreTime = restoreTime
        pendingAutoplay = autoplay

        persistState(structureChanged: true)
        isLoadInFlight = true
        loadTask = Task { await loadAndPlay(song: song, generation: generation) }
    }

    private func loadAndPlay(song: Song, generation: UInt) async {
        do {
            let playable: PlayableURL
            switch song.source {
            case .local:
                guard let url = song.localFileURL, FileManager.default.fileExists(atPath: url.path) else {
                    throw MusicError.fileNotFound
                }
                playable = PlayableURL(url: url, quality: AudioQuality(level: .unknown, isActual: true))
            case .netease:
                // 单曲音质覆盖优先于全局设置；有覆盖就一定走网易源（跳过本地缓存），
                // 否则默认吃缓存（128kbps OPUS，秒开）
                let override = qualityOverride(for: song.id)
                let level = SongQualityPolicy.effectiveLevel(override: override, global: requestedQuality)
                if SongQualityPolicy.useLocalCache(hasOverride: override != nil),
                   let cached = AudioCacheManager.shared.cachedItem(for: song.id) {
                    // 登记「正在播放的缓存曲目」：`AudioCacheManager.trimIfNeeded`
                    // 会跳过它，否则可能删掉 AVPlayer 正在读的文件。
                    // 原先 `setCurrentCachedSong` 全工程零调用方，那条保护形同虚设。
                    AudioCacheManager.shared.setCurrentCachedSong(song.id)
                    playable = PlayableURL(
                        url: cached.url,
                        // 缓存文件的编码就是缓存管线的输出格式（OPUS CAF）
                        quality: AudioQuality(level: .unknown, bitrate: cached.bitrateKbps,
                                              isActual: true, codec: cached.formatName),
                        isCached: true
                    )
                } else {
                    var remote = try await provider.fetchPlayableURL(songID: song.id, quality: level)
                    // 无损（FLAC）接口常把 br 报成 0，用 size×8/时长 反算真实平均码率，
                    // 否则播放栏只能显示「无损」而看不出实际拿到了多少
                    if remote.quality.bitrate == nil {
                        remote.quality.bitrate = SongQualityPolicy.derivedBitrateKbps(
                            sizeBytes: remote.sizeBytes, duration: song.duration
                        )
                    }
                    playable = remote
                    // 完整歌曲才缓存；被点名要某个音质的歌不写（128k OPUS 对它是降级）
                    if SongQualityPolicy.shouldWriteCache(hasOverride: override != nil, isPreview: remote.isPreview) {
                        AudioCacheManager.shared.cacheInBackground(songID: song.id, sourceURL: remote.url)
                    }
                }
            }

            // 已切换歌曲或播放已停止：在途 URL 响应作废，不得再改状态/重建播放器
            guard generation == currentGeneration, playbackState.songID == song.id else { return }

            // 拉流结束。item 刚接上、还没 readyToPlay，状态仍是 .loading，
            // 那段时间由 `playbackState.isLoading` 继续表示「还在准备」
            isLoadInFlight = false
            actualQuality = playable.quality
            isCurrentFromCache = playable.isCached
            CTLog.playback.info("播放源: \(playable.isCached ? "缓存" : "在线", privacy: .public) id=\(song.id, privacy: .public) 质量=\(playable.quality.level.rawValue, privacy: .public)")
            try startPlayback(url: playable.url, song: song, generation: generation)
        } catch {
            // 只有仍属于当前代次的那次拉流才配改动这个标志
            if generation == currentGeneration { isLoadInFlight = false }
            guard generation == currentGeneration else { return }
            handlePlayError(error, for: song)
        }
    }

    private func applyVolumeToPlayer() {
        let output = PlaybackVolumePolicy.output(volume: volume, isMuted: isMuted)
        player?.volume = output.volume
        player?.isMuted = output.isMuted
    }

    private func startPlayback(url: URL, song: Song, generation: UInt) throws {
        // 只解绑当前 item，播放器实例复用（切歌延迟与 CPU 峰值都更低）
        detachCurrentItem()

        // 顺序至关重要：**先确保播放器存在，再挂齐所有观察者，最后才把 item 交进去。**
        // 反过来（先 replaceCurrentItem 再挂 KVO）会丢事件：复用一个已热起来的
        // AVPlayer 时，replaceCurrentItem 会立刻开始加载，本地文件或热连接下
        // item 可能在 KVO 挂上之前就变成 .readyToPlay，于是 readyToPlay 回调
        // 永远不会送达，startAudio 不执行、player.play() 从不调用 —— 表现就是没声音。
        if player == nil {
            player = AVPlayer()
        }
        applyVolumeToPlayer()

        let item = AVPlayerItem(url: url)
        // 倍速时保持音调。不设的话 1.5x 会变成「花栗鼠」，
        // 而这是变速播放最容易被用户当成 bug 的一环。
        // .timeDomain 是变调算法里最快的一种，流媒体上延迟最小；
        // .spectral 音质更好但 CPU 开销大，远程流上容易掉帧。
        item.audioTimePitchAlgorithm = .timeDomain
        playerItem = item

        // 状态监听
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self, generation == self.currentGeneration else { return }
                self.handleItemStatus(item, song: song, generation: generation)
            }
        }

        // 缓冲监听。loadedTimeRanges 在网络抖动时可达数十 Hz，
        // 这里做 1 秒节流：唯一消费方是一个 tooltip，不需要那么精确。
        bufferObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self, generation == self.currentGeneration else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastBufferPublishAt) >= 1 else { return }
                self.lastBufferPublishAt = now
                if let range = item.loadedTimeRanges.first?.timeRangeValue {
                    self.bufferedTime = range.start.seconds + range.duration.seconds
                }
            }
        }

        // 播放结束
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, generation == self.currentGeneration else { return }
                self.playbackState = .ended(songID: song.id)
                self.handleTrackEnded()
            }
        }

        // 播放失败
        errorObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            let nsError = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { @MainActor in
                guard let self = self, generation == self.currentGeneration else { return }
                self.handlePlayError(nsError ?? MusicError.unknown("播放中断"), for: song)
            }
        }

        // 缓冲中检测。原先 PlaybackState.buffering 是纯死设计（声明后零赋值），
        // 网络抖动时界面没有任何缓冲提示。
        // playbackStalled 覆盖「已经开始播放又卡住」，timeControlStatus 覆盖「首次缓冲」。
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, generation == self.currentGeneration else { return }
                // 只在「用户意图是播放」时提示，暂停状态下卡顿无需打扰
                guard self.pendingAutoplay, let songID = self.playbackState.songID else { return }
                self.playbackState = .buffering(songID: songID)
            }
        }
        timeControlObserver = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self = self, generation == self.currentGeneration else { return }
                switch player.timeControlStatus {
                case .waitingToPlayAtSpecifiedRate:
                    guard self.pendingAutoplay, let songID = self.playbackState.songID else { return }
                    self.playbackState = .buffering(songID: songID)
                case .playing:
                    // 缓冲结束：恢复为 playing（endOfMedia 由 endedObserver 负责）
                    if self.playbackState.isBuffering, let songID = self.playbackState.songID {
                        self.playbackState = .playing(songID: songID)
                        self.updateNowPlayingPlaybackState()
                    }
                default:
                    break
                }
            }
        }

        // 时间监听
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                // 校验代次：旧歌曲的时钟不得写入新歌曲或已停止的播放器
                guard let self = self, generation == self.currentGeneration,
                      !self.isUserSeeking, self.currentSong != nil else { return }
                let seconds = time.seconds
                // 时长异常的流会给 NaN/Inf。NaN 灌进 currentTime 之后，
                // 每一份持久化快照都会编码失败（整份被 try? 吞掉），
                // 表现是「设置和队列从此再也存不上」。
                guard seconds.isFinite else { return }
                self.currentTime = seconds
                self.timePublisher.send(seconds)
                // 不在这里调 updateNowPlayingElapsedTime()：写 nowPlayingInfo 字典会触发
                // COW + 序列化 + 到 mediaremote 的 XPC，2Hz 持续唤醒。系统会根据
                // PlaybackRate 自行外推，只在 seek 完成后同步一次即可。
                self.persistProgressThrottled()
            }
        }

        // 观察者全部挂好，现在才把 item 交给播放器开始加载
        player?.replaceCurrentItem(with: item)

        // 兜底：挂观察者的瞬间 item 可能已经是 ready（极快的本地文件 / 热连接）。
        // KVO 不会补发历史值，所以这里同步检查一次，避免漏掉 readyToPlay。
        if item.status == .readyToPlay {
            handleItemStatus(item, song: song, generation: generation)
        }
    }

    /// 处理播放项状态变化。抽成方法以便 KVO 回调与同步兜底检查共用同一条路径。
    private func handleItemStatus(_ item: AVPlayerItem, song: Song, generation: UInt) {
        switch item.status {
        case .readyToPlay:
            // 只校验 item 身份与歌单身份，**不校验状态枚举**。原先要求状态为 .loading，
            // 而用户在加载窗口内点暂停时 pause() 已把状态改成 .paused，
            // 于是这个分支不进入：恢复进度的 seek 被静默丢弃（之后从头开始播），
            // 且 updateNowPlayingInfo 不会被调用，系统媒体控制（锁屏/控制中心/耳机）
            // 继续显示上一首的标题与封面。
            guard playerItem === item, playbackState.songID == song.id else { return }
            // 真正进入播放，连续失败计数清零
            consecutiveFailures = 0
            // 注意：这里**不要**再挂 MTAudioProcessingTap。
            // 曾在 readyToPlay 里给本地文件挂频谱 tap，导致播放卡在
            // waitingToPlayAtSpecifiedRate（界面显示「缓冲中」）。原因有二：
            // 1) 纯 Swift 无法安全实现该 tap —— MTAudioProcessingTapStorage 这个 C 结构体
            //    在 SDK 头文件里不存在，GetStorage 返回的是 void** 而非 handler 指针，
            //    之前那版把它当 handler 指针解引用，在音频实时线程上读野指针；
            // 2) 即便类型正确，在 KVO 回调里创建 tap 会触发音频管线重新协商格式，
            //    对 48kHz OPUS/CAF 这类缓存文件尤其不稳。
            // 频谱的 FFT 数学部分（SpectrumProcessor）已修好并有测试，
            // 但在拿到可靠的挂载方式之前，宁可不做也不能牺牲播放。
            startAudio(generation: generation, songID: song.id)
        case .failed:
            handlePlayError(item.error ?? MusicError.unknown("播放失败"), for: song)
        default:
            break
        }
    }

    /// 可播放后按恢复意图启动音频（含恢复进度 seek）
    private func startAudio(generation: UInt, songID: String) {
        guard let player = player else { return }

        // 用 AVPlayerItem 的实际时长校正 duration：只信 API 元数据时，
        // 本地文件或某些 CDN 转码流会出现「拖到 99% 就结束 / 提前结束」
        if let item = playerItem {
            let actual = item.duration.seconds
            if actual.isFinite, actual > 1, abs(actual - self.duration) > 0.5 {
                CTLog.playback.info("时长校正: \(Int(self.duration))s → \(Int(actual))s")
                self.duration = actual
            }
        }

        if let restoreTime = pendingRestoreTime, restoreTime > 1, duration > 0, restoreTime < duration {
            let target = min(restoreTime, max(duration - 0.5, 0))
            isUserSeeking = true
            let cmTime = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                Task { @MainActor in
                    // 迟到的旧代次回调不得碰新代次的标志位与状态
                    // （切歌/停止时 beginPlay/stopPlayback 自己已复位 isUserSeeking）。
                    guard generation == self.currentGeneration else { return }
                    self.isUserSeeking = false
                    // `finished == false` 不一定是「item 坏了」：用户的 seek 会顶掉这次
                    // 恢复 seek（`commitSeek` 不改 playbackState）。若在这里直接 return，
                    // 状态会永久停在 `.loading`、一声不响，用户只能再点一次播放才脱困。
                    // 所以只要还在「准备中」就把播放意图落定。
                    if self.playbackState.isLoading {
                        // 采用 seek 期间用户最新的播放意图（pause/resume 会同步 pendingAutoplay）
                        if self.pendingAutoplay {
                            self.player?.defaultRate = self.playbackRate
                            self.player?.play()
                            self.playbackState = .playing(songID: songID)
                        } else {
                            self.playbackState = .paused(songID: songID)
                        }
                    }
                    // 只有确实 seek 到位才写回恢复进度；被打断时保留用户拖到的新位置
                    if finished {
                        self.currentTime = restoreTime
                    }
                    self.updateNowPlayingInfo()
                }
            }
        } else {
            if pendingAutoplay {
                player.defaultRate = playbackRate
                player.play()
            }
            playbackState = pendingAutoplay
                ? .playing(songID: songID)
                : .paused(songID: songID)
            updateNowPlayingInfo()
        }
    }

    public func pause() {
        // 同步恢复期间的播放意图：若 seek 尚未完成，完成回调不得再自动出声
        pendingAutoplay = false
        // 失败后排队等待自动切歌的任务必须一并取消：用户按下暂停就是对
        // 「换一首继续放」说了不，否则 1.5 秒后它会照样 beginPlay(autoplay: true)。
        cancelAutoAdvance()
        player?.pause()
        // 失败态的 songID 也非 nil：不能把「播放源坏了、需要重建」的锁存态
        // 抹成 .paused。系统媒体中心的 pauseCommand、耳机线控、iOS 中断与
        // 拔耳机（routeChange）都会直连 pause()，一旦降级成 .paused，
        // 之后的 resume() 就跳过了重建分支，在同一个坏 item 上 play() ——
        // 界面显示「播放中」却永远静音。
        if case .failed = playbackState {
            updateNowPlayingPlaybackState()
            return
        }
        if let songID = playbackState.songID {
            playbackState = .paused(songID: songID)
        }
        if currentSong != nil {
            persistState(structureChanged: false)
        }
        updateNowPlayingPlaybackState()
    }

    public func resume() {
        #if os(iOS)
        do {
            try activateAudioSession()
        } catch {
            // 会话激活失败是**暂时性**的：中断还没结束、别的 App 正占着会话、
            // 或者耳机刚拔掉。早先这里把 playbackState 打成 .failed ——
            // 一旦 latch，界面就停在错误态，队列、进度、重试按钮全都跟着废，
            // 而真正该做的只是过一会儿再试一次。
            // 现在保持原状态：用户再点播放就会重新激活。
            CTLog.playback.error("恢复播放时音频会话激活失败: \(CTLog.sanitize(error.localizedDescription))")
            return
        }
        #endif
        // 失败态被**直连**调用时必须重建播放源。
        //
        // `togglePlayPause` 有自己的 .failed 分支，但系统媒体中心的
        // `playCommand`（耳机线控 / 锁屏 / 控制中心）与 iOS 中断结束后的
        // 恢复都直接调 `resume()`，绕过了那个 switch。此时 player 上挂的还是
        // status == .failed 的 item —— play() 永远是 0 速率、一声不响，
        // 而函数末尾会无条件把状态改写成 .playing，于是界面显示「播放中」、
        // 实际静音，用户按几次都没反应，只能重新点歌行才脱困。
        if case .failed = playbackState {
            retryAfterFailure()
            return
        }
        // 播放源还在准备中（URL 在途，或 item 已挂上但还没 readyToPlay）：
        // 只把意图翻成播放，**不重新拉流** —— 走 beginPlay 会递增代次、取消正在途的
        // 请求并从头再来一遍（用户会听到重新加载，进度也可能被重置）。
        // 真正出声由 startAudio 在 ready 之后按最新意图决定。
        if isPreparingPlayback {
            pendingAutoplay = true
            if let songID = playbackState.songID {
                // 现在确实有一场播放在进行（只是还没准备好）：显示「加载中 + 暂停图标」，
                // 等 startAudio 落到 .playing；按钮语义与图标这才一致
                playbackState = .loading(songID: songID)
            }
            updateNowPlayingPlaybackState()
            return
        }
        if player == nil {
            // 播放器尚未建立（如重启后从持久化恢复）：重建播放并按用户意图恢复进度
            beginRestoredPlayback(autoplay: true)
            return
        }
        // 播完的曲目（顺序播放最后一首结束 / 手动 stop 后仍在队列）：从头重放
        if let song = currentSong, duration > 0, currentTime >= max(duration - 0.5, 0) {
            beginPlay(song, restoreTime: nil, autoplay: true)
            return
        }
        pendingAutoplay = true
        // defaultRate 必须在 play() 之前设好：play() 会把它当作起始速率
        player?.defaultRate = playbackRate
        player?.play()
        if let songID = playbackState.songID {
            playbackState = .playing(songID: songID)
        }
        updateNowPlayingPlaybackState()
    }

    /// 当前是否处于「有歌要播、但播放源还没准备好」的窗口。
    ///
    /// 两种来源：URL 还在途（`isLoadInFlight`），或 item 已挂上但还没 readyToPlay
    /// （状态仍是 .loading）。**刻意不看「播放器上有没有 item」** ——
    /// 播放失败且队列已空时状态是 .idle、item 也空，但那时并没有请求在跑，
    /// 当成「还在准备」会让 resume() 翻完意图就返回，界面永远转圈。
    private var isPreparingPlayback: Bool {
        guard currentSong != nil else { return false }
        return isLoadInFlight || playbackState.isLoading
    }

    /// 从持久化状态重建播放（重启后调用），恢复保存的进度
    private func beginRestoredPlayback(autoplay: Bool) {
        guard let song = currentSong, player == nil else { return }
        beginPlay(song, restoreTime: currentTime > 0 ? currentTime : nil, autoplay: autoplay)
    }

    /// 重启后按需重建播放：恢复保存进度，默认不自动出声
    public func resumeFromPersistence() {
        beginRestoredPlayback(autoplay: false)
    }

    public func togglePlayPause() {
        switch playbackState {
        case .playing, .buffering: pause()
        case .loading:
            // 加载中按钮显示的是「⏸ 暂停」（loading 也算 play intent），点它必须真的有反应。
            // 原先这里是 `break`：图标摆着暂停、点下去毫无动静。
            // 按当前意图决定往哪边翻，ready 之后由 startAudio 采纳最新意图。
            if pendingAutoplay { pause() } else { resume() }
        case .paused, .idle, .ended: resume()
        case .failed: retryAfterFailure()
        }
    }

    /// 失败态下重新尝试当前歌曲：清掉失败计数并重建播放源。
    ///
    /// `togglePlayPause` 与 `resume()` 共用这一段 —— 后者被系统媒体中心的
    /// `playCommand`、耳机线控与 iOS 中断恢复直接调用，不经过上面的 switch。
    /// 两处各写一份的话，下一次改重试策略就会漏掉其中一条路径。
    private func retryAfterFailure() {
        consecutiveFailures = 0
        sameSongRetries = 0
        if let song = currentSong {
            beginPlay(song, restoreTime: nil, autoplay: true)
        } else {
            playCurrent()
        }
    }

    public func next() {
        guard let item = queue.next() else { return }
        play(song: item.song)
    }

    public func previous() {
        // 只有「播放器上确实挂着 item」时才应用“超过 3 秒回到开头”，
        // 否则重启后恢复的暂停态按上一首处理；
        // 换歌加载窗口内（实例复用、item 已摘除）currentTime 还是上一首的，
        // 此时必须按上一首处理，不能被 seek(0) 吃掉。
        if player?.currentItem != nil, currentTime > 3 {
            seek(to: 0)
            return
        }
        guard let item = queue.previous() else { return }
        play(song: item.song)
    }

    /// 拖动过程中的预览：只更新 UI 时间，不提交 seek。
    ///
    /// 原实现在 Slider 的每帧（60~120Hz）都提交一次零容差精确 seek。
    /// `.zero` 容差意味着不能用关键帧近似，必须从邻近关键帧重新解码；
    /// 而 `Task.cancel()` 撤不回已提交给 AVFoundation 的 seek，
    /// 于是拖动过程中会累积 N 个已执行请求 —— 音频断续、耗电飙升，
    /// 最终 currentTime 取决于哪个 completion 最后返回。
    public func previewSeek(to time: TimeInterval) {
        // NaN/±Inf 不得进入状态：进度条的区间上界取自 `max(duration, 1)`，
        // 而 Swift 的 `max(NaN, 1)` 返回 NaN —— 拖出来的就是 NaN。
        // 它一旦写进 currentTime，持久化快照会整份编码失败。
        guard time.isFinite else { return }
        isUserSeeking = true
        currentTime = time
        timePublisher.send(time)
    }

    /// 拖动结束：提交一次精确 seek
    public func commitSeek(to time: TimeInterval) {
        guard time.isFinite else { return }
        isUserSeeking = true
        currentTime = time
        timePublisher.send(time)
        // 单调递增的令牌替代 Task.cancel()：已提交的 seek 无法撤销，
        // 只能让旧回调自己发现"我不是最新的"而放弃写回
        seekToken &+= 1
        let token = seekToken
        let generation = currentGeneration
        seekTask?.cancel()
        seekTask = Task { [weak self] in
            guard let self else { return }
            // 必须在**提交 seek 之前**就放弃：`Task.cancel()` 撤不回已交给
            // AVFoundation 的 seek。换歌（beginPlay 会 cancel seekTask 但会递增
            // generation）后旧任务若还执行，会把新歌 seek 到旧歌的位置。
            guard !Task.isCancelled, token == self.seekToken,
                  generation == self.currentGeneration else { return }
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            await self.player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            // 只有最新一次 seek 才允许改状态
            guard token == self.seekToken, !Task.isCancelled else { return }
            self.isUserSeeking = false
            self.updateNowPlayingElapsedTime()
            if self.currentSong != nil {
                self.persistState(structureChanged: false)
            }
        }
    }

    /// 保留旧接口：内部按"预览 + 立即提交"处理，供键盘/菜单等一次性跳转使用
    public func seek(to time: TimeInterval) {
        commitSeek(to: time)
    }

    public func setPlayMode(_ mode: PlayMode) {
        queue.mode = mode
        persistState(structureChanged: true)
    }

    /// 顺序播放 → 列表循环 → 单曲循环 → 随机，按播放栏按钮的同一顺序轮转
    public func cyclePlayMode() {
        let next: PlayMode
        switch queue.mode {
        case .sequential: next = .loopAll
        case .loopAll: next = .loopOne
        case .loopOne: next = .shuffle
        case .shuffle: next = .sequential
        }
        setPlayMode(next)
    }

    /// 相对当前进度跳转。菜单/键盘的 ±15 秒。
    public func seek(by seconds: TimeInterval) {
        let target = min(max(0, currentTime + seconds), duration > 0 ? duration : .greatestFiniteMagnitude)
        commitSeek(to: target)
    }

    // MARK: - 队列操作

    public func appendToQueue(_ song: Song) {
        queue.append(song)
        persistState(structureChanged: true)
    }

    public func insertNext(_ song: Song) {
        queue.insertNext(song)
        persistState(structureChanged: true)
    }

    public func removeFromQueue(itemID: UUID) {
        let wasCurrent = currentSong != nil && queue.currentItem?.id == itemID
        // 删的是「正在播放且已是最后一首」：后面没有可接的歌，应当停止。
        // `PlayQueue.remove` 在删掉末项后会把 currentIndex 回夹到 `count - 1`，
        // 于是 `queue.currentItem` 变成**上一首**，照原逻辑会倒着播回去。
        let removedLastCurrent = wasCurrent && queue.currentIndex == queue.items.count - 1
        guard queue.remove(itemID: itemID) else { return }
        persistState(structureChanged: true)
        // 删除的是正在播放的条目：立即同步到新的当前歌曲，避免结束回调再推进一次导致跳歌
        guard wasCurrent else { return }
        if removedLastCurrent {
            stopPlayback()
        } else if let next = queue.currentItem {
            play(song: next.song)
        } else {
            stopPlayback()
        }
    }

    public func clearQueue() {
        queue.clear()
        stopPlayback()
    }

    /// 批量追加到队列末尾。
    ///
    /// 逐首调用 `appendToQueue` 会为每首歌各触发一次持久化写入：
    /// 1000 首的歌单点「添加到队列」就是 1000 次 JSON 编码 + 落盘。
    /// 批量接口只写一次。
    public func appendToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        queue.append(contentsOf: songs)
        persistState(structureChanged: true)
    }

    /// 批量插到当前歌曲之后（保持传入顺序）。
    ///
    /// `PlayQueue.insertNext` 每首固定插在 `currentIndex + 1`，所以正序遍历
    /// 会把整批插成倒序（`[1,2,3]` → 当前,3,2,1）。倒序插入才能得到 1,2,3。
    public func insertNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        for song in songs.reversed() {
            queue.insertNext(song)
        }
        persistState(structureChanged: true)
    }

    public func moveQueueItems(fromOffsets: IndexSet, toOffset: Int) {
        queue.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persistState(structureChanged: true)
    }

    public func jumpTo(itemID: UUID) {
        if queue.jumpTo(itemID: itemID), let item = queue.currentItem {
            play(song: item.song)
        }
    }

    // MARK: - 音质

    /// 统一音质入口：设置页修改后同步到播放器，并让之后的播放请求使用新音质
    public func setRequestedQuality(_ level: AudioQuality.QualityLevel) {
        let resolved = SongQualityPolicy.effectiveGlobalLevel(preference: level, isVIP: isAccountVIP)
        guard preferredQuality != level || requestedQuality != resolved else { return }
        preferredQuality = level
        requestedQuality = resolved
        persistState(structureChanged: true)
        // 当前歌曲按新音质重新拉流，保留进度与播放状态。
        // 有单曲覆盖时不受影响：那一首要的就是它自己指定的音质。
        if let song = currentSong, playbackState.songID == song.id, qualityOverride(for: song.id) == nil {
            reloadCurrentSongForQualityChange()
        }
    }

    /// 账号 VIP 状态落定后调用。
    ///
    /// 只在偏好为「自动」时才可能改变实际档位；用户显式选过的音质一律不动。
    /// 但如果档位真的变了（比如登录后从「极高」变成「无损」），
    /// 正在播的歌要按新音质重拉 —— 否则用户看到设置已生效、耳朵里还是旧码率。
    public func setAccountIsVIP(_ value: Bool) {
        guard value != isAccountVIP else { return }
        isAccountVIP = value
        applyResolvedGlobalQuality()
    }

    /// 按当前偏好 + VIP 重新解析全局档位，必要时让当前歌曲重拉流。
    private func applyResolvedGlobalQuality() {
        let resolved = SongQualityPolicy.effectiveGlobalLevel(
            preference: preferredQuality, isVIP: isAccountVIP
        )
        guard resolved != requestedQuality else { return }
        requestedQuality = resolved
        if let song = currentSong, playbackState.songID == song.id, qualityOverride(for: song.id) == nil {
            reloadCurrentSongForQualityChange()
        }
    }

    // MARK: 单曲音质覆盖

    /// 为某一首歌单独指定音质。
    ///
    /// - Parameter level: nil = 取消覆盖，回到全局设置
    public func setQualityOverride(_ level: AudioQuality.QualityLevel?, for songID: String) {
        let normalized = level == .unknown ? nil : level
        if normalized == qualityOverride(for: songID) { return }
        if let normalized = normalized {
            songQualityOverrides.removeAll { $0.songID == songID }
            songQualityOverrides.insert(SongQualityOverride(songID: songID, level: normalized), at: 0)
            // 覆盖表只增不减会让它随听歌量无限膨胀；只保留最近改动的这些
            if songQualityOverrides.count > Self.maxSongQualityOverrides {
                songQualityOverrides.removeLast(songQualityOverrides.count - Self.maxSongQualityOverrides)
            }
        } else {
            songQualityOverrides.removeAll { $0.songID == songID }
        }
        saveSongQualityOverrides()
        // 当前这首立刻按新音质重拉（保留进度与播放状态）
        if let song = currentSong, song.id == songID {
            reloadCurrentSongForQualityChange()
        }
    }

    public func qualityOverride(for songID: String) -> AudioQuality.QualityLevel? {
        songQualityOverrides.first { $0.songID == songID }?.level
    }

    /// 这首歌实际会用到的音质
    public func effectiveQuality(for songID: String) -> AudioQuality.QualityLevel {
        SongQualityPolicy.effectiveLevel(override: qualityOverride(for: songID), global: requestedQuality)
    }

    /// 当前播放是否走了单曲音质覆盖（= 正在用网易源而不是本地缓存）
    public var currentSongUsesOverride: Bool {
        guard let song = currentSong else { return false }
        return qualityOverride(for: song.id) != nil
    }

    /// 换音质后重拉当前这首：进度与播放状态都保住
    private func reloadCurrentSongForQualityChange() {
        guard let song = currentSong else { return }
        let time = currentTime
        let autoplay = playbackState.isPlaying || playbackState.isBuffering || pendingAutoplay
        beginPlay(song, restoreTime: time > 0 ? time : nil, autoplay: autoplay)
    }

    private func loadSongQualityOverrides() -> [SongQualityOverride] {
        PersistenceStore.shared.loadSetting(forKey: Self.songQualityOverridesKey, as: [SongQualityOverride].self) ?? []
    }

    private func saveSongQualityOverrides() {
        // UserDefaults 同步写：这是一次性的用户点击，不是高频路径
        PersistenceStore.shared.saveSetting(songQualityOverrides, forKey: Self.songQualityOverridesKey)
    }

    // MARK: - 结束处理

    private func handleTrackEnded() {
        consecutiveFailures = 0
        if let nextItem = queue.handleEnded() {
            play(song: nextItem.song)
        } else {
            playbackState = .idle
            updateNowPlayingPlaybackState()
        }
    }

    private func handlePlayError(_ error: Error, for song: Song) {
        // 同一次失败可能同时触发 KVO .failed 与 FailedToPlayToEndTime，忽略重复回调
        if case .failed(let failedID, _) = playbackState, failedID == song.id { return }

        // 失败原因会显示在播放栏上，必须走脱敏出口
        let message = error.ctUserMessage
        playbackState = .failed(songID: song.id, reason: message)
        CTLog.playback.error("播放失败 [\(song.title)]: \(message)")

        consecutiveFailures += 1
        if consecutiveFailures >= maxConsecutiveFailures {
            CTLog.playback.warning("连续失败 \(self.consecutiveFailures) 次，停止自动切换")
            return
        }

        // 延迟处理；带 generation 校验，用户在此期间切歌则本任务作废
        let generation = currentGeneration
        autoAdvanceTask?.cancel()
        autoAdvanceTask = Task {
            // 同一首歌先重新拉一次流（播放地址可能已过期或 CDN 瞬断），保留进度
            let refreshURL = song.id == self.currentSong?.id && self.sameSongRetries < 1
            if refreshURL {
                self.sameSongRetries += 1
                try? await Task.sleep(for: .seconds(0.8))
                guard generation == self.currentGeneration else { return }
                let resumeTime = self.currentTime > 3 ? self.currentTime : nil
                self.beginPlay(song, restoreTime: resumeTime, autoplay: true)
                return
            }

            try? await Task.sleep(for: .seconds(1.5))
            guard generation == self.currentGeneration else { return }
            guard self.consecutiveFailures < self.maxConsecutiveFailures else { return }
            guard let item = self.queue.next() else {
                self.playbackState = .idle
                self.updateNowPlayingPlaybackState()
                return
            }
            // 自动重试路径不重置连续失败计数
            self.beginPlay(item.song, restoreTime: nil, autoplay: true)
        }
    }

    private func cancelAutoAdvance() {
        autoAdvanceTask?.cancel()
        autoAdvanceTask = nil
    }

    // MARK: - 持久化

    private func makeSnapshot() -> PersistedQueue {
        let output = PlaybackVolumePolicy.output(volume: volume, isMuted: isMuted)
        return PersistedQueue(
            items: queue.items,
            currentIndex: queue.currentIndex,
            mode: queue.mode,
            currentTime: currentTime,
            volume: output.volume,
            isMuted: output.isMuted,
            requestedQuality: requestedQuality,
            playbackRate: playbackRate
        )
    }

    /// 落盘走后台合并写：主线程只取不可变快照，编码与写文件都在后台 actor。
    /// `structureChanged` 标注这次调用是否因队列结构变化（增删/重排/换歌/换模式/换音质）
    /// 而来，进度更新与暂停不算结构变化 —— 便于将来进一步做差异化落盘。
    private func persistState(structureChanged: Bool = false) {
        lastProgressSaveAt = Date()
        let snapshot = makeSnapshot()
        Task { await PersistenceStore.PersistenceWriter.shared.schedule(queue: snapshot) }
    }

    /// 播放进度节流保存（时间观察者高频调用，间隔内至多落盘一次）
    private func persistProgressThrottled() {
        let now = Date()
        guard now.timeIntervalSince(lastProgressSaveAt) >= progressSaveInterval else { return }
        persistState(structureChanged: false)
    }

    /// 立即保存最新状态（退出、显式边界）
    public func persistNow() async {
        await PersistenceStore.PersistenceWriter.shared.persistAndFlush(
            queue: makeSnapshot(), recentSongs: recentlyPlayed
        )
    }

    private func loadPersistedState() -> Bool {
        guard let data = PersistenceStore.shared.loadQueue() else { return false }
        queue.items = data.items
        // 上下限都要夹：items 为空时 count-1 == -1，原先只夹上限会得到 -2 之类的非法下标
        queue.currentIndex = data.items.isEmpty
            ? -1
            : max(0, min(data.currentIndex, data.items.count - 1))
        queue.mode = data.mode
        let output = PlaybackVolumePolicy.output(volume: data.volume, isMuted: data.isMuted)
        volume = output.volume
        isMuted = output.isMuted
        requestedQuality = data.requestedQuality
        // 倍速此前只写不读：`makeSnapshot` 每次都存、`PersistedQueue` 还专门给了
        // `= 1.0` 默认值兼容旧文件，可 `loadPersistedState` 从来没读过它，
        // 于是「重启后保留倍速」这个承诺（写进代码注释的）根本没实现。
        // 夹到可选档位内：旧文件里存过任意浮点数的话不该带进来。
        playbackRate = Self.resolveRestoredPlaybackRate(data.playbackRate)
        currentSong = queue.currentItem?.song
        duration = currentSong?.duration ?? 0
        currentTime = data.currentTime

        // 恢复位置但不自动出声；实际重建播放器发生在用户点击播放（或启动时自动恢复）
        if let song = currentSong {
            playbackState = .paused(songID: song.id)
        }
        return currentSong != nil
    }

    /// 换歌时解绑当前 item：移除观察者与通知，但**保留 AVPlayer 实例**。
    ///
    /// 原先 `cleanupPlayer()` 每次都 `player = nil` 再 `AVPlayer(playerItem:)` 新建。
    /// AVPlayer 持有音频会话、解码管线与输出路由，反复构造/销毁会在曲目切换处
    /// 产生额外中断与延迟尖峰、CPU 峰值更高（每次重新协商解码器），
    /// 也让「无缝切歌」无法实现。
    private func detachCurrentItem() {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        statusObserver?.invalidate()
        bufferObserver?.invalidate()
        statusObserver = nil
        bufferObserver = nil
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let errorObserver = errorObserver {
            NotificationCenter.default.removeObserver(errorObserver)
        }
        endObserver = nil
        errorObserver = nil
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
        }
        stallObserver = nil
        timeControlObserver?.invalidate()
        timeControlObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
    }

    /// 彻底销毁播放器（退出播放、App 停止等边界）
    private func teardownPlayer() {
        detachCurrentItem()
        player = nil
    }

    /// 停止播放并回到空闲态（清空队列等边界）
    private func stopPlayback() {
        // 递增代次使所有在途请求/回调作废（generation 校验失败，不再写状态、不再重建播放器）
        currentGeneration += 1
        cancelAutoAdvance()
        loadTask?.cancel()
        loadTask = nil
        isLoadInFlight = false
        seekTask?.cancel()
        isUserSeeking = false
        // 停止播放是彻底边界：销毁播放器实例，避免空转的解码器与音频会话
        teardownPlayer()
        currentSong = nil
        duration = 0
        currentTime = 0
        bufferedTime = 0
        pendingRestoreTime = nil
        actualQuality = nil
        isCurrentFromCache = false
        // 复位缓存保护：换歌/停止后上一首的缓存文件不再被占用
        AudioCacheManager.shared.setCurrentCachedSong(nil)
        retrySongID = ""
        sameSongRetries = 0
        playbackState = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateNowPlayingPlaybackState()
        persistState(structureChanged: true)
    }

    #if os(iOS)
    private var interruptionShouldResume = false
    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func setupAudioSessionNotifications() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.interruptionShouldResume = self.playbackState.isPlayIntentActive
                    self.pause()
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    if self.interruptionShouldResume && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self.resume() }
                    self.interruptionShouldResume = false
                }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        }
    }
    #endif

    // MARK: - 系统媒体控制

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // (command, token) 必须成对保存：removeTarget 定义在 MPRemoteCommand 上。
        // 否则将来若重建实例（或测试反复访问），同一按键会触发 N 次
        keepRemoteTarget(center.playCommand, center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        })
        keepRemoteTarget(center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        })
        keepRemoteTarget(center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        })
        keepRemoteTarget(center.nextTrackCommand, center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        })
        keepRemoteTarget(center.previousTrackCommand, center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        })
        keepRemoteTarget(center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.commitSeek(to: event.positionTime) }
            return .success
        })
    }

    /// 封面回调必须 nonisolated：MediaPlayer 在内部队列（*/accessQueue）同步调用它，
    /// 若在 @MainActor 上下文中构造闭包会继承隔离性，触发 dispatch_assert_queue 崩溃（SIGTRAP）
    private nonisolated static func makeArtworkRequestHandler(
        image: PlatformImage
    ) -> (CGSize) -> PlatformImage {
        { _ in image }
    }

    private func updateNowPlayingInfo() {
        guard let song = currentSong else { return }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artistNames,
            MPMediaItemPropertyAlbumTitle: song.album?.name ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playbackState.isPlaying ? Double(playbackRate) : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

          guard let coverURL = song.coverURL else { return }
          // 异步封面：仅在歌曲未变时写入，避免快速切歌时旧封面/旧信息覆盖新歌曲。
          // 复用 CoverLoader（已有 NSCache + 磁盘缓存 + 在途去重），
          // 原先走 URLSession.shared 是主线程解码 + 无缓存 + 无取消，
          // 快速切歌 10 次会有 10 个并发下载都跑完。
          let songID = song.id
          let generation = currentGeneration
          artworkTask?.cancel()
          artworkTask = Task { [weak self] in
              guard let image = await CoverLoader.shared.load(url: coverURL, pointSize: 600),
                    !Task.isCancelled else { return }
              guard let self,
                    self.currentSong?.id == songID,
                    generation == self.currentGeneration else { return }
              let handler = Self.makeArtworkRequestHandler(image: image)
              let artwork = MPMediaItemArtwork(boundsSize: image.size, requestHandler: handler)
              MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
          }
      }

    private func updateNowPlayingElapsedTime() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
    }

    private func updateNowPlayingPlaybackState() {
        let rate: Double = playbackState.isPlaying ? Double(playbackRate) : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = rate
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = playbackState.isPlaying ? .playing : .paused
        #endif
    }
}

// MARK: - 持久化数据结构
struct PersistedQueue: Codable {
    var items: [QueueItem]
    var currentIndex: Int
    var mode: PlayMode
    var currentTime: TimeInterval
    var volume: Float
    var isMuted: Bool
    var requestedQuality: AudioQuality.QualityLevel
    /// 倍速。带默认值是为了兼容旧版本写下的 queue.json（缺字段时按 1.0 读）
    var playbackRate: Float = 1.0
}

/// MPRemoteCommand target 的持有者。
///
/// 单独抽出来是因为 Swift 6 下 `deinit` 是 nonisolated 的，无法直接访问
/// `@MainActor` 隔离的存储属性；这个盒子是不可变的快照 + 内部加锁的注册表。
private final class RemoteCommandBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(MPRemoteCommand, Any)] = []

    func add(command: MPRemoteCommand, token: Any) {
        lock.lock()
        storage.append((command, token))
        lock.unlock()
    }

    func removeAllTargets() {
        lock.lock()
        let snapshot = storage
        storage.removeAll()
        lock.unlock()
        for (command, token) in snapshot { command.removeTarget(token) }
    }
}
