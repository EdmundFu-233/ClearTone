import AVFoundation
import Foundation

/// 音频播放缓存：
/// 把在线播放过的网易云歌曲用系统转码器转成 **128kbps OPUS（macOS：CAF 容器）/
/// AAC（iOS：M4A 容器）** 落盘，之后再次播放同一首歌时优先使用缓存，
/// 省流量且离线可播。
///
/// 说明：
/// - 编码由系统 CoreAudio 提供（macOS `afconvert -d opus`、iOS
///   `AVAssetExportPresetAppleM4A`），无需额外依赖；
/// - 采用「受约束 VBR」策略（macOS `-s 2`），目标 128kbps，实际平均码率随内容略有浮动，UI 展示实测值；
/// - 扩展名由 `cacheFileExtension` 统一决定，容器 AVPlayer 支持完整（时长 / seek 正确），缓存文件仅本机使用；
/// - 单条记录最多活 7 天（`AudioCacheRetentionPolicy`），到期后重新拉流。
@MainActor
final class AudioCacheManager: ObservableObject {
    static let shared = AudioCacheManager()

    /// 缓存元数据
    struct CacheMeta: Codable {
        var formatName: String     // 例如 "OPUS"
        var bitrateKbps: Int       // 实测平均码率
        var sizeBytes: Int64
        var cachedAt: Date
        /// 最后一次被播放命中的时间。用于真正的 LRU 淘汰 ——
        /// 原实现只用 mtime（写入时设定），导致最常听的歌反而最早被淘汰。
        var lastAccessedAt: Date?
    }

    struct CachedAudio {
        let url: URL
        let formatName: String
        let bitrateKbps: Int
    }

    /// 转码中的临时文件前缀。进程被杀时 defer 不会执行，残留文件靠这里识别并清扫。
    nonisolated private static let tempPrefix = "tmp-"

    /// 开关由设置页同步（false 时不产生新缓存，已有缓存仍可直接播放）
    var isEnabled = true

    @Published private(set) var cachedSongIDs: Set<String> = []
    @Published private(set) var cachingSongIDs: Set<String> = []

    /// 目标码率（受约束 VBR），单位 bit/s。`static` 是因为下载/转码跑在
    /// 后台任务里，读不到 MainActor 隔离的实例属性。
    nonisolated static let defaultTargetBitrate = 128_000
    nonisolated private static var cacheFormatName: String {
        #if os(iOS)
        "AAC"
        #else
        "OPUS"
        #endif
    }
    /// 缓存上限，超出后按最久未播放淘汰
    private let maxCacheBytes: Int64 = 1_500_000_000
    /// 缓存文件扩展名 —— **唯一**的格式来源，与转码器实际写出的容器一一对应：
    /// macOS 走 `afconvert -f caff -d opus`（CAF），iOS 走
    /// `AVAssetExportPresetAppleM4A`（M4A）。AVPlayer 靠扩展名判定容器，
    /// 写错会直接播不出来。
    nonisolated static var cacheFileExtension: String {
        #if os(iOS)
        "m4a"
        #else
        "caf"
        #endif
    }

    /// 是否是「正式缓存文件」：扩展名等于**当前平台**的 `cacheFileExtension`，
    /// 且不是转码残留的 `tmp-` 临时文件。
    ///
    /// 扫描/淘汰两处都必须走这里。原先两处各写死 `.caf`，
    /// 而 iOS 实际写的是 `.m4a` —— 结果是 iOS 上 `refreshIndex`
    /// 每次启动都筛出 0 个文件、把整个索引当「已被系统清理」删光，
    /// `trimIfNeeded` 也找不到任何可淘汰项，容量上限形同虚设。
    nonisolated static func isCacheFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == cacheFileExtension.lowercased()
            && !url.lastPathComponent.hasPrefix(tempPrefix)
    }

private let cacheDirectory: URL
    private var index: [String: CacheMeta] = [:]

    /// 「清除缓存」代数。在途的缓存任务完成后要校验它，
    /// 否则清除之后任务又把条目写回来（幽灵条目复活）。
    private var clearGeneration = 0
    /// 播放中的缓存歌曲，淘汰时跳过，避免正在读的文件被删
    private var currentCachedSongID: String?
    /// 访问时间更新的最小间隔，避免每次播放都写 index.json
    private let accessTouchInterval: TimeInterval = 60
    /// 索引落盘的合并窗口
    private var indexDirty = false
    private var indexFlushTask: Task<Void, Never>?

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = base.appendingPathComponent("ClearTone/AudioCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        refreshIndex()
    }

    // MARK: - 查询

    func cachedItem(for songID: String) -> CachedAudio? {
        guard let meta = index[songID] else { return nil }
        // 过期条目一律当作没缓存：宁可直接重新拉流，也不要放一个
        // 可能已被系统清理、或内容早已过期的文件。
        guard !AudioCacheRetentionPolicy.isExpired(cachedAt: meta.cachedAt) else { return nil }
        let url = fileURL(for: songID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        touchAccess(songID: songID)
        return CachedAudio(url: url, formatName: meta.formatName, bitrateKbps: meta.bitrateKbps)
    }

    /// 索引里的条目元信息。**过期条目返回 nil** ——
    ///
    /// `PlayerController.playingSourceInfo` 用它决定要不要显示「缓存中」，
    /// 它读的是索引而不是 `cachedItem`。只给读路径加过期判断的话，
    /// 播放栏会在条目已过期、实际走的是在线流时仍然显示「OPUS 缓存」。
    func meta(for songID: String) -> CacheMeta? {
        guard let meta = index[songID],
              !AudioCacheRetentionPolicy.isExpired(cachedAt: meta.cachedAt) else { return nil }
        return meta
    }

    var totalCacheBytes: Int64 { index.values.reduce(0) { $0 + $1.sizeBytes } }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalCacheBytes, countStyle: .file)
    }

    /// 标记正在播放的缓存曲目，淘汰时保护它
    func setCurrentCachedSong(_ songID: String?) {
        currentCachedSongID = songID
    }

    // MARK: - 写入

    /// 后台把在线音频转码并缓存；重复调用 / 已缓存 / 试听源都会自动跳过
    func cacheInBackground(songID: String, sourceURL: URL) {
        guard isEnabled, !songID.isEmpty, !sourceURL.isFileURL else { return }
        guard !cachedSongIDs.contains(songID), !cachingSongIDs.contains(songID) else { return }
        guard hasSufficientDiskSpace() else {
            CTLog.general.warning("磁盘空间不足，跳过缓存: \(songID)")
            return
        }

        cachingSongIDs.insert(songID)
        pendingCaches.append(PendingCache(
            songID: songID, sourceURL: sourceURL, generation: clearGeneration
        ))
        pumpCacheQueue()
    }

    /// 等待中的缓存任务。
    ///
    /// 之前每首歌各自 `Task(priority: .utility)`：连续切 30 首歌就会同时跑
    /// 30 个下载 + 30 个 afconvert 进程，既抢播放的连接与 CPU，也可能把盘写满。
    /// 串行化之后一次只处理一首。
    private struct PendingCache {
        let songID: String
        let sourceURL: URL
        let generation: Int
    }

    private var pendingCaches: [PendingCache] = []
    private var isRunningCache = false

    private func pumpCacheQueue() {
        guard !isRunningCache, !pendingCaches.isEmpty else { return }
        isRunningCache = true
        let job = pendingCaches.removeFirst()
        let destination = fileURL(for: job.songID)

        Task(priority: .utility) { [weak self] in
            // 无论成功失败都要清状态并推进队列，否则「缓存中」永久亮着、队列不再前进
            defer { Task { @MainActor in self?.finishCacheJob(job.songID) } }

            let result: (bitrateKbps: Int, sizeBytes: Int64)
            do {
                result = try await Self.downloadAndTranscode(
                    sourceURL: job.sourceURL,
                    destination: destination,
                    targetBitrate: Self.defaultTargetBitrate
                )
            } catch {
                CTLog.general.warning("音频缓存失败 [\(job.songID)]: \(CTLog.sanitize(error.localizedDescription))")
                return
            }

            await MainActor.run {
                guard let self else { return }
                // 清除缓存发生在转码期间：把刚写的文件删掉，不要让条目复活
                guard job.generation == self.clearGeneration else {
                    try? FileManager.default.removeItem(at: destination)
                    CTLog.general.info("丢弃已过期的缓存结果: \(job.songID)")
                    return
                }
                self.index[job.songID] = CacheMeta(
                    formatName: Self.cacheFormatName,
                    bitrateKbps: result.bitrateKbps,
                    sizeBytes: result.sizeBytes,
                    cachedAt: Date(),
                    lastAccessedAt: Date()
                )
                self.cachedSongIDs.insert(job.songID)
                self.persistIndexSoon()
                // 超龄条目先清，再按容量淘汰 ——
                // 不然一个 7 天前的老条目会占着容量名额被 LRU 反复「保护」
                self.purgeExpired()
                self.trimIfNeeded()
                CTLog.general.info("音频缓存完成: \(job.songID) \(Self.cacheFormatName) \(result.bitrateKbps)kbps (\(result.sizeBytes) bytes)")
            }
        }
    }

    /// 一首缓存任务结束（成功 / 失败 / 被丢弃）：清状态并推进队列
    private func finishCacheJob(_ songID: String) {
        cachingSongIDs.remove(songID)
        isRunningCache = false
        pumpCacheQueue()
    }

    func clearAll() {
        clearGeneration += 1
        // 排队中的任务一并作废：它们本来也会被 clearGeneration 拦下，
        // 但留着会让「缓存中」一直亮着
        pendingCaches.removeAll()
        cachedSongIDs.removeAll()
        cachingSongIDs.removeAll()
        index.removeAll()
        persistIndex()
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - 私有

    private func fileURL(for songID: String) -> URL {
        cacheDirectory.appendingPathComponent("\(songID).\(Self.cacheFileExtension)")
    }

    private func indexURL() -> URL {
        cacheDirectory.appendingPathComponent("index.json")
    }

    private func persistIndex() {
        indexFlushTask?.cancel()
        indexFlushTask = nil
        indexDirty = false
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL(), options: [.atomic])
    }

    /// 合并写：转码完成可能连续触发多次，避免每次都全量序列化索引
    private func persistIndexSoon() {
        guard !indexDirty else { return }
        indexDirty = true
        indexFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.persistIndex()
        }
    }

    private func refreshIndex() {
        if let data = try? Data(contentsOf: indexURL()),
           let decoded = try? JSONDecoder().decode([String: CacheMeta].self, from: data) {
            index = decoded
        }
        // 一次列目录，把元数据取齐，避免后续又逐个 stat
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let listing = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: keys
        )) ?? []

        // 清扫上次进程被杀留下的临时文件：它们扩展名与正式缓存相同，
        // 原实现会把 tmp-<UUID> 当成正式索引项计入容量
        for file in listing where file.lastPathComponent.hasPrefix(Self.tempPrefix) {
            try? FileManager.default.removeItem(at: file)
        }

        let realFiles = listing.filter { Self.isCacheFile($0) }
        var present = Set<String>()
        for file in realFiles {
            let id = file.deletingPathExtension().lastPathComponent
            present.insert(id)
            // 索引缺条目但文件在（上次写索引前被杀）：补回来，避免白白重新下载
            if index[id] == nil,
               let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                index[id] = CacheMeta(
                    // 码率只能按目标值猜：孤儿条目没有实测值可读。
                    // 与 `defaultTargetBitrate` 保持一致（128kbps）。
                    formatName: Self.cacheFormatName, bitrateKbps: Self.defaultTargetBitrate / 1000,
                    sizeBytes: Int64(size),
                    cachedAt: Date(), lastAccessedAt: nil
                )
            }
        }
        // 文件被系统清理 / 手动删除时同步剔除索引
        index = index.filter { present.contains($0.key) }
        cachedSongIDs = Set(index.keys)
        if indexDirty || index.isEmpty == false { persistIndex() }
        // 启动时顺手清掉超过保留期的条目。不在这里做的话，
        // 7 天规则只会等到「某首歌转码成功」才触发一次 ——
        // 一个长期不听的 App 可能永远不转码，过期文件就一直堆在盘上。
        purgeExpired()
    }

    /// 清扫超过 `AudioCacheRetentionPolicy.maxAge`（7 天）的条目。
    ///
    /// 与 `trimIfNeeded` 的分工：那个按**容量**淘汰最久未播放的，
    /// 这个按**时间**清掉超龄的。两者都跳过正在播放的文件。
    @discardableResult
    private func purgeExpired() -> Int {
        let expired = AudioCacheRetentionPolicy.expiredIDs(
            cachedAtByID: index.mapValues(\.cachedAt)
        )
        guard !expired.isEmpty else { return 0 }
        for songID in expired {
            // 正在播的先留着：文件删了 AVPlayer 会立刻中断
            guard songID != currentCachedSongID else { continue }
            try? FileManager.default.removeItem(at: fileURL(for: songID))
            if index.removeValue(forKey: songID) != nil {
                cachedSongIDs.remove(songID)
            }
        }
        persistIndex()
        CTLog.general.info("音频缓存过期清理: \(expired.count) 条超过 \(Int(AudioCacheRetentionPolicy.maxAge / 86400)) 天")
        return expired.count
    }

    private func touchAccess(songID: String) {
        guard var meta = index[songID] else { return }
        let now = Date()
        let last = meta.lastAccessedAt ?? meta.cachedAt
        guard now.timeIntervalSince(last) >= accessTouchInterval else { return }
        meta.lastAccessedAt = now
        index[songID] = meta
        persistIndexSoon()
    }

    private func trimIfNeeded() {
        guard totalCacheBytes > maxCacheBytes else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys) else { return }

        // 先把元数据取出来再排序。原先在比较器里逐次 stat()，
        // 500 个文件时比较器被调用约 4500 次 = 4500 次系统调用，且发生在主线程。
        let entries: [(id: String, url: URL, meta: CacheMeta)] = files.compactMap { file in
            guard Self.isCacheFile(file) else { return nil }
            let id = file.deletingPathExtension().lastPathComponent
            guard let meta = index[id] else { return nil }
            return (id, file, meta)
        }
        // 真正的 LRU：优先淘汰最久未播放的
        let sorted = entries.sorted {
            ($0.meta.lastAccessedAt ?? $0.meta.cachedAt) < ($1.meta.lastAccessedAt ?? $1.meta.cachedAt)
        }

        for entry in sorted {
            // 注意：这里不能再减去一个独立的 freed 累计量 —— totalCacheBytes 是
            // 按 index 实时重算的，removeValue 之后它已经变小了，再减一次会重复扣减，
            // 导致提前 break、缓存仍超上限。
            guard totalCacheBytes > maxCacheBytes else { break }
            // 正在播放的文件不能删：APFS 上已开 fd 可继续读，但预缓冲窗口会失败
            guard entry.id != currentCachedSongID else { continue }
            try? FileManager.default.removeItem(at: entry.url)
            if index.removeValue(forKey: entry.id) != nil {
                cachedSongIDs.remove(entry.id)
            }
        }
        persistIndex()
    }

    /// 缓存入口的磁盘空间预检（afconvert 对 ENOSPC 只会非 0 退出，错误信息不好读）
    private func hasSufficientDiskSpace() -> Bool {
        let need: Int64 = 64 * 1024 * 1024   // 约 8 分钟无损
        let values = try? cacheDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return available > need
    }

    // MARK: - 下载 + 转码（后台执行）

    private nonisolated static func downloadAndTranscode(
        sourceURL: URL,
        destination: URL,
        targetBitrate: Int
    ) async throws -> (bitrateKbps: Int, sizeBytes: Int64) {
        let (tempFile, response) = try await downloadSession.download(from: sourceURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MusicError.unknown("缓存下载失败")
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let sourceDuration = ((try? await AVURLAsset(url: tempFile).load(.duration))?.seconds) ?? 0

        let tempOutput = destination.deletingLastPathComponent()
            .appendingPathComponent("\(Self.tempPrefix)\(UUID().uuidString).\(Self.cacheFileExtension)")
        defer { try? FileManager.default.removeItem(at: tempOutput) }

        #if os(iOS)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: tempFile), presetName: AVAssetExportPresetAppleM4A) else {
            throw MusicError.unknown("无法建立音频缓存")
        }
        export.outputURL = tempOutput
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else { throw export.error ?? MusicError.unknown("音频缓存失败") }
        #else
        try await runAfconvert(input: tempFile, output: tempOutput, targetBitrate: targetBitrate)
        #endif

        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempOutput)
        } else {
            try FileManager.default.moveItem(at: tempOutput, to: destination)
        }

        let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let actualKbps = sourceDuration > 0
            ? Int((Double(size) * 8 / sourceDuration / 1000).rounded())
            : targetBitrate / 1000
        return (actualKbps, size)
    }

    /// 下载用专用 session：URLSession.shared 没有资源超时，下载卡死会让「缓存中」永久卡住
    private nonisolated static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 2   // 不要和播放流抢连接池
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

#if os(macOS)
    /// afconvert 超时。超过后强杀，避免 waitUntilExit 永久阻塞导致
    /// continuation 永不 resume、「缓存中」永久显示、utility 线程泄漏。
    private nonisolated static let afconvertTimeout: Duration = .seconds(180)

    /// 调用系统 afconvert：CAF 容器 + OPUS 编码 + 受约束 VBR 128kbps + 48kHz 立体声
    private nonisolated static func runAfconvert(input: URL, output: URL, targetBitrate: Int) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", "caff",
            "-d", "opus",
            "-s", "2", // 受约束 VBR
            "-b", "\(targetBitrate)",
            "-c", "2",
            "-r", "48000",
            input.path,
            output.path,
        ]

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // 一次性恢复守卫：watchdog 与正常路径可能同时到达，CheckedContinuation 只能 resume 一次
                let resumed = ResumeGuard()

                process.terminationHandler = { proc in
                    guard resumed.claim() else { return }
                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: MusicError.unknown("afconvert 转码失败 (\(proc.terminationStatus))"))
                    }
                }

                do {
                    try process.run()
                } catch {
                    if resumed.claim() {
                        continuation.resume(throwing: MusicError.unknown("afconvert 启动失败: \(error.localizedDescription)"))
                    }
                    return
                }

                // watchdog：超时强杀
                Task.detached(priority: .utility) {
                    try? await Task.sleep(for: Self.afconvertTimeout)
                    guard process.isRunning else { return }
                    CTLog.general.warning("afconvert 超时(\(Int(Self.afconvertTimeout.components.seconds))s)，强制终止")
                    process.terminate()
                    // 给 SIGTERM 一点时间，不行就 SIGKILL
                    try? await Task.sleep(for: .seconds(3))
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
    #endif
}

/// 保证 continuation 只被恢复一次（多次 resume 会 crash）
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    /// @return true 表示本次调用赢得了恢复权
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

