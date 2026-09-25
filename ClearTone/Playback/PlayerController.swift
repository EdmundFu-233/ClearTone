import Foundation
import AVFoundation
import Combine
import MediaPlayer
import AppKit

/// 全局唯一播放控制器，管理 AVPlayer、状态、队列、系统媒体集成
@MainActor
public final class PlayerController: ObservableObject {
    public static let shared = PlayerController()

    // MARK: - Published State
    @Published public private(set) var playbackState: PlaybackState = .idle
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public var volume: Float = 0.8 {
        didSet { player?.volume = volume }
    }
    @Published public var isMuted: Bool = false {
        didSet { player?.isMuted = isMuted }
    }
    @Published public var queue = PlayQueue()
    @Published public private(set) var currentSong: Song?
    /// 最近播放（最新在前，最多 100 首，落盘持久化）
    @Published public private(set) var recentlyPlayed: [Song] = []
    @Published public private(set) var requestedQuality: AudioQuality.QualityLevel = .exhigh
    @Published public private(set) var actualQuality: AudioQuality?
    /// 当前播放是否来自本地音频缓存
    @Published public private(set) var isCurrentFromCache = false
    @Published public private(set) var bufferedTime: TimeInterval = 0

    /// 高频时钟与低频 UI 状态分离：currentTime 更新通过 timer，view 按需订阅
    public let timePublisher = PassthroughSubject<TimeInterval, Never>()

    // MARK: - Private
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var bufferObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?

    private var provider: MusicProvider = NeteaseProvider.shared
    private var localProvider = LocalProvider()
    private var demoProvider = DemoProvider.shared

    private var currentGeneration: UInt = 0
    private var consecutiveFailures: Int = 0
    private let maxConsecutiveFailures = 3
    /// 同一首歌的“重新拉流”次数：首错先刷新播放地址，再次失败才自动下一首
    private var retrySongID: String = ""
    private var sameSongRetries = 0
    private var seekTask: Task<Void, Never>?
    private var isUserSeeking = false
    private var autoAdvanceTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var pendingRestoreTime: TimeInterval?
    private var pendingAutoplay = true
    private var lastProgressSaveAt = Date.distantPast
    private let progressSaveInterval: TimeInterval = 5

    private var isDemoMode = false

    private init() {
        setupRemoteCommands()
        recentlyPlayed = PersistenceStore.shared.loadRecentSongs()
        let restored = loadPersistedState()
        // 设置页的音质是权威值：队列文件里的可能落后（例如先改设置、还没播放过）
        let settings = PersistenceStore.shared.loadSetting(forKey: "appSettings", as: AppSettings.self)
        if let settings {
            requestedQuality = settings.preferredQuality
        }
        // 与设置说明一致：恢复上次播放位置，但不自动出声
        if restored, settings?.resumePlaybackOnLaunch == true {
            beginRestoredPlayback(autoplay: false)
        }
    }

    // MARK: - 公共配置

    public func setDemoMode(_ enabled: Bool) {
        isDemoMode = enabled
    }

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
        // 切歌开始时立即停止旧播放器，避免旧歌曲的时间观察者继续写进新歌曲进度
        cleanupPlayer()

        playbackState = .loading(songID: song.id)
        currentSong = song
        duration = song.duration
        currentTime = restoreTime ?? 0
        bufferedTime = 0
        pendingRestoreTime = restoreTime
        pendingAutoplay = autoplay

        persistState(structureChanged: true)
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
            case .demo:
                playable = try await demoProvider.fetchPlayableURL(songID: song.id, quality: requestedQuality)
            case .netease:
                if let cached = AudioCacheManager.shared.cachedItem(for: song.id) {
                    // 优先播放本地缓存（96kbps OPUS）
                    playable = PlayableURL(
                        url: cached.url,
                        quality: AudioQuality(level: .unknown, bitrate: cached.bitrateKbps, isActual: true),
                        isCached: true
                    )
                } else {
                    let remote = try await provider.fetchPlayableURL(songID: song.id, quality: requestedQuality)
                    playable = remote
                    // 完整歌曲才缓存（试听流不缓存）
                    if !remote.isPreview {
                        AudioCacheManager.shared.cacheInBackground(songID: song.id, sourceURL: remote.url)
                    }
                }
            }

            // 已切换歌曲或播放已停止：在途 URL 响应作废，不得再改状态/重建播放器
            guard generation == currentGeneration, playbackState.songID == song.id else { return }

            actualQuality = playable.quality
            isCurrentFromCache = playable.isCached
            CTLog.playback.info("播放源: \(playable.isCached ? "缓存" : "在线", privacy: .public) id=\(song.id, privacy: .public) 质量=\(playable.quality.level.rawValue, privacy: .public)")
            try startPlayback(url: playable.url, song: song, generation: generation)
        } catch {
            guard generation == currentGeneration else { return }
            handlePlayError(error, for: song)
        }
    }

    private func startPlayback(url: URL, song: Song, generation: UInt) throws {
        cleanupPlayer()

        let item = AVPlayerItem(url: url)
        playerItem = item
        player = AVPlayer(playerItem: item)
        player?.volume = volume
        player?.isMuted = isMuted

        // 状态监听
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self, generation == self.currentGeneration else { return }
                switch item.status {
                case .readyToPlay:
                    if case .loading = self.playbackState {
                        // 真正进入播放，连续失败计数清零
                        self.consecutiveFailures = 0
                        self.startAudio(generation: generation, songID: song.id)
                    }
                case .failed:
                    self.handlePlayError(item.error ?? MusicError.unknown("播放失败"), for: song)
                default:
                    break
                }
            }
        }

        // 缓冲监听
        bufferObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self, generation == self.currentGeneration else { return }
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

        // 时间监听
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                // 校验代次：旧歌曲的时钟不得写入新歌曲或已停止的播放器
                guard let self = self, generation == self.currentGeneration,
                      !self.isUserSeeking, self.currentSong != nil else { return }
                self.currentTime = time.seconds
                self.timePublisher.send(time.seconds)
                self.updateNowPlayingElapsedTime()
                self.persistProgressThrottled()
            }
        }
    }

    /// 可播放后按恢复意图启动音频（含恢复进度 seek）
    private func startAudio(generation: UInt, songID: String) {
        guard let player = player else { return }
        if let restoreTime = pendingRestoreTime, restoreTime > 1, duration > 0, restoreTime < duration {
            let target = min(restoreTime, max(duration - 0.5, 0))
            isUserSeeking = true
            let cmTime = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                Task { @MainActor in
                    // 无条件清除 seek 标记：切歌后迟到的回调不得让标志位卡死（会冻结进度与持久化）
                    self.isUserSeeking = false
                    guard generation == self.currentGeneration else { return }
                    // seek 被中断（item 被替换/出错）时不改播放状态，交给状态监听器接管
                    guard finished else { return }
                    // 采用 seek 期间用户最新的播放意图（pause/resume 会同步 pendingAutoplay）
                    if self.pendingAutoplay {
                        self.player?.play()
                        self.playbackState = .playing(songID: songID)
                    } else {
                        self.playbackState = .paused(songID: songID)
                    }
                    self.currentTime = restoreTime
                    self.updateNowPlayingInfo()
                }
            }
        } else {
            if pendingAutoplay { player.play() }
            playbackState = pendingAutoplay
                ? .playing(songID: songID)
                : .paused(songID: songID)
            updateNowPlayingInfo()
        }
    }

    public func pause() {
        // 同步恢复期间的播放意图：若 seek 尚未完成，完成回调不得再自动出声
        pendingAutoplay = false
        player?.pause()
        if let songID = playbackState.songID {
            playbackState = .paused(songID: songID)
        }
        if currentSong != nil {
            persistState(structureChanged: false)
        }
        updateNowPlayingPlaybackState()
    }

    public func resume() {
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
        player?.play()
        if let songID = playbackState.songID {
            playbackState = .playing(songID: songID)
        }
        updateNowPlayingPlaybackState()
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
        case .playing: pause()
        case .paused, .idle, .ended: resume()
        case .failed:
            // 失败态下点播放：重新尝试当前歌曲（重置失败计数与重试次数）
            consecutiveFailures = 0
            sameSongRetries = 0
            if let song = currentSong {
                beginPlay(song, restoreTime: nil, autoplay: true)
            } else {
                playCurrent()
            }
        default: break
        }
    }

    public func next() {
        guard let item = queue.next() else { return }
        play(song: item.song)
    }

    public func previous() {
        // 只有存在真实播放器时才应用“超过 3 秒回到开头”，
        // 否则重启后恢复的暂停态按上一首处理
        if player != nil, currentTime > 3 {
            seek(to: 0)
            return
        }
        guard let item = queue.previous() else { return }
        play(song: item.song)
    }

    public func seek(to time: TimeInterval) {
        seekTask?.cancel()
        isUserSeeking = true
        currentTime = time

        seekTask = Task {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            await player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            isUserSeeking = false
            updateNowPlayingElapsedTime()
            if currentSong != nil {
                persistState(structureChanged: false)
            }
        }
    }

    public func setPlayMode(_ mode: PlayMode) {
        queue.mode = mode
        persistState(structureChanged: true)
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
        guard queue.remove(itemID: itemID) else { return }
        persistState(structureChanged: true)
        // 删除的是正在播放的条目：立即同步到新的当前歌曲，避免结束回调再推进一次导致跳歌
        guard wasCurrent else { return }
        if let next = queue.currentItem {
            play(song: next.song)
        } else {
            stopPlayback()
        }
    }

    public func clearQueue() {
        queue.clear()
        stopPlayback()
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
        guard requestedQuality != level else { return }
        requestedQuality = level
        persistState(structureChanged: true)
        // 当前歌曲按新音质重新拉流，保留进度与播放状态
        if let song = currentSong, playbackState.songID == song.id {
            let time = currentTime
            let autoplay = playbackState.isPlaying
            beginPlay(song, restoreTime: time > 0 ? time : nil, autoplay: autoplay)
        }
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

        let message = error.localizedDescription
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
        PersistedQueue(
            items: queue.items,
            currentIndex: queue.currentIndex,
            mode: queue.mode,
            currentTime: currentTime,
            volume: volume,
            isMuted: isMuted,
            requestedQuality: requestedQuality
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
    public func persistNow() {
        persistState(structureChanged: true)
        Task { await PersistenceStore.PersistenceWriter.shared.flushNow() }
    }

    private func loadPersistedState() -> Bool {
        guard let data = PersistenceStore.shared.loadQueue() else { return false }
        queue.items = data.items
        // 上下限都要夹：items 为空时 count-1 == -1，原先只夹上限会得到 -2 之类的非法下标
        queue.currentIndex = data.items.isEmpty
            ? -1
            : max(0, min(data.currentIndex, data.items.count - 1))
        queue.mode = data.mode
        volume = data.volume
        isMuted = data.isMuted
        requestedQuality = data.requestedQuality
        currentSong = queue.currentItem?.song
        duration = currentSong?.duration ?? 0
        currentTime = data.currentTime

        // 恢复位置但不自动出声；实际重建播放器发生在用户点击播放（或启动时自动恢复）
        if let song = currentSong {
            playbackState = .paused(songID: song.id)
        }
        return currentSong != nil
    }

    private func cleanupPlayer() {
        if let observer = timeObserver, let player = player {
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
        player?.pause()
        player = nil
        playerItem = nil
    }

    /// 停止播放并回到空闲态（清空队列等边界）
    private func stopPlayback() {
        // 递增代次使所有在途请求/回调作废（generation 校验失败，不再写状态、不再重建播放器）
        currentGeneration += 1
        cancelAutoAdvance()
        loadTask?.cancel()
        loadTask = nil
        seekTask?.cancel()
        isUserSeeking = false
        cleanupPlayer()
        currentSong = nil
        duration = 0
        currentTime = 0
        bufferedTime = 0
        pendingRestoreTime = nil
        actualQuality = nil
        isCurrentFromCache = false
        retrySongID = ""
        sameSongRetries = 0
        playbackState = .idle
        updateNowPlayingPlaybackState()
        persistState(structureChanged: true)
    }

    // MARK: - 系统媒体控制

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    /// 封面回调必须 nonisolated：MediaPlayer 在内部队列（*/accessQueue）同步调用它，
    /// 若在 @MainActor 上下文中构造闭包会继承隔离性，触发 dispatch_assert_queue 崩溃（SIGTRAP）
    private nonisolated static func makeArtworkRequestHandler(image: NSImage) -> (CGSize) -> NSImage {
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
            MPNowPlayingInfoPropertyPlaybackRate: playbackState.isPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard let coverURL = song.coverURL else { return }
        // 异步封面：仅在歌曲未变时写入，避免快速切歌时旧封面/旧信息覆盖新歌曲
        let songID = song.id
        let generation = currentGeneration
        Task {
            guard let data = try? await URLSession.shared.data(from: coverURL).0,
                  let image = NSImage(data: data) else { return }
            guard self.currentSong?.id == songID, generation == self.currentGeneration else { return }
            let handler = Self.makeArtworkRequestHandler(image: image)
            let artwork = MPMediaItemArtwork(boundsSize: image.size, requestHandler: handler)
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
        }
    }

    private func updateNowPlayingElapsedTime() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
    }

    private func updateNowPlayingPlaybackState() {
        let rate: Double = playbackState.isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().playbackState = playbackState.isPlaying ? .playing : .paused
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
}
