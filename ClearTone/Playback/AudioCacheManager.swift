import AVFoundation
import Foundation

/// 音频播放缓存：
/// 把在线播放过的网易云歌曲用系统 afconvert 转成 **96kbps OPUS（CAF 容器）** 落盘，
/// 之后再次播放同一首歌时优先使用缓存，省流量且离线可播。
///
/// 说明：
/// - OPUS 编码由系统 CoreAudio 提供（`afconvert -d opus`），无需额外依赖；
/// - 采用「受约束 VBR」策略（`-s 2`），目标 96kbps，实际平均码率随内容略有浮动，UI 展示实测值；
/// - CAF 容器 AVPlayer 支持完整（时长 / seek 正确），缓存文件仅本机使用。
@MainActor
final class AudioCacheManager: ObservableObject {
    static let shared = AudioCacheManager()

    /// 缓存元数据
    struct CacheMeta: Codable {
        var formatName: String     // 例如 "OPUS"
        var bitrateKbps: Int       // 实测平均码率
        var sizeBytes: Int64
        var cachedAt: Date
    }

    struct CachedAudio {
        let url: URL
        let formatName: String
        let bitrateKbps: Int
    }

    /// 开关由设置页同步（false 时不产生新缓存，已有缓存仍可直接播放）
    var isEnabled = true

    @Published private(set) var cachedSongIDs: Set<String> = []
    @Published private(set) var cachingSongIDs: Set<String> = []

    /// 目标码率（受约束 VBR）
    private let targetBitrate = 96000
    /// 缓存上限，超出后按最久未修改淘汰
    private let maxCacheBytes: Int64 = 1_500_000_000
    private let cacheDirectory: URL
    private var index: [String: CacheMeta] = [:]

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = base.appendingPathComponent("ClearTone/AudioCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        refreshIndex()
    }

    // MARK: - 查询

    func cachedItem(for songID: String) -> CachedAudio? {
        guard let meta = index[songID] else { return nil }
        let url = fileURL(for: songID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return CachedAudio(url: url, formatName: meta.formatName, bitrateKbps: meta.bitrateKbps)
    }

    func meta(for songID: String) -> CacheMeta? { index[songID] }

    var totalCacheBytes: Int64 { index.values.reduce(0) { $0 + $1.sizeBytes } }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalCacheBytes, countStyle: .file)
    }

    // MARK: - 写入

    /// 后台把在线音频转码并缓存；重复调用 / 已缓存 / 试听源都会自动跳过
    func cacheInBackground(songID: String, sourceURL: URL) {
        guard isEnabled, !songID.isEmpty, !sourceURL.isFileURL else { return }
        guard !cachedSongIDs.contains(songID), !cachingSongIDs.contains(songID) else { return }

        cachingSongIDs.insert(songID)
        Task(priority: .utility) {
            do {
                let result = try await Self.downloadAndTranscode(
                    sourceURL: sourceURL,
                    destination: self.fileURL(for: songID),
                    targetBitrate: self.targetBitrate
                )
                self.cachingSongIDs.remove(songID)
                self.index[songID] = CacheMeta(
                    formatName: "OPUS",
                    bitrateKbps: result.bitrateKbps,
                    sizeBytes: result.sizeBytes,
                    cachedAt: Date()
                )
                self.cachedSongIDs.insert(songID)
                self.persistIndex()
                self.trimIfNeeded()
                CTLog.general.info("音频缓存完成: \(songID) OPUS \(result.bitrateKbps)kbps (\(result.sizeBytes) bytes)")
            } catch {
                self.cachingSongIDs.remove(songID)
                CTLog.general.warning("音频缓存失败 [\(songID)]: \(CTLog.sanitize(error.localizedDescription))")
            }
        }
    }

    func clearAll() {
        cachedSongIDs.removeAll()
        cachingSongIDs.removeAll()
        index.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - 私有

    private func fileURL(for songID: String) -> URL {
        cacheDirectory.appendingPathComponent("\(songID).caf")
    }

    private func indexURL() -> URL {
        cacheDirectory.appendingPathComponent("index.json")
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL(), options: [.atomic])
    }

    private func refreshIndex() {
        if let data = try? Data(contentsOf: indexURL()),
           let decoded = try? JSONDecoder().decode([String: CacheMeta].self, from: data) {
            index = decoded
        }
        // 文件被系统清理 / 手动删除时同步剔除索引
        let files = Set(
            ((try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "caf" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
        index = index.filter { files.contains($0.key) }
        cachedSongIDs = Set(index.keys)
    }

    private func trimIfNeeded() {
        guard totalCacheBytes > maxCacheBytes else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: keys) else { return }
        let sorted = files
            .filter { $0.pathExtension.lowercased() == "caf" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l < r
            }
        for file in sorted {
            guard totalCacheBytes > maxCacheBytes else { break }
            let id = file.deletingPathExtension().lastPathComponent
            try? FileManager.default.removeItem(at: file)
            if let meta = index.removeValue(forKey: id) {
                cachedSongIDs.remove(id)
                _ = meta
            }
        }
        persistIndex()
    }

    // MARK: - 下载 + 转码（后台执行）

    private nonisolated static func downloadAndTranscode(
        sourceURL: URL,
        destination: URL,
        targetBitrate: Int
    ) async throws -> (bitrateKbps: Int, sizeBytes: Int64) {
        let (tempFile, response) = try await URLSession.shared.download(from: sourceURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MusicError.unknown("缓存下载失败")
        }
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let sourceDuration = ((try? await AVURLAsset(url: tempFile).load(.duration))?.seconds) ?? 0

        let tempOutput = destination.deletingLastPathComponent()
            .appendingPathComponent("tmp-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tempOutput) }

        try await runAfconvert(input: tempFile, output: tempOutput, targetBitrate: targetBitrate)

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

    /// 调用系统 afconvert：CAF 容器 + OPUS 编码 + 受约束 VBR 96kbps + 48kHz 立体声
    private nonisolated static func runAfconvert(input: URL, output: URL, targetBitrate: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
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
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(throwing: MusicError.unknown("afconvert 启动失败: \(error.localizedDescription)"))
                    return
                }
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: MusicError.unknown("afconvert 转码失败 (\(process.terminationStatus))"))
                }
            }
        }
    }
}
