import Foundation
import AVFoundation
import CryptoKit

/// 本地音乐 Provider：导入文件/文件夹、读取元数据、播放
/// 导入结果落盘持久化，重启后恢复（非沙箱环境直接存路径）
public actor LocalProvider: MusicProvider {
    public static let shared = LocalProvider()

    public let identifier = "local"
    public let displayName = "本地音乐"

    private var importedSongs: [Song] = []
    private let supportedExtensions = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "alac"]

    public init() {}

    // MARK: - 导入

    public func importFiles(_ urls: [URL]) async throws -> [Song] {
        var songs: [Song] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue } // 跳过不支持的文件，不打断整批导入
            guard !contains(url) else { continue } // 去重
            if let song = await parseMetadata(url: url) {
                songs.append(song)
            }
        }
        importedSongs.append(contentsOf: songs)
        persistLibrary()
        return songs
    }

    public func scanDirectory(_ url: URL) async throws -> [Song] {
        var songs: [Song] = []
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            try Task.checkCancellation()
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            guard !contains(fileURL) else { continue }
            if let song = await parseMetadata(url: fileURL) {
                songs.append(song)
            }
        }
        importedSongs.append(contentsOf: songs)
        persistLibrary()
        return songs
    }

    /// 当前曲库（视图刷新用）
    public func allSongs() -> [Song] { importedSongs }

    /// 启动时从磁盘恢复曲库
    public func restoreLibrary() async -> [Song] {
        guard importedSongs.isEmpty else { return importedSongs }
        let paths = PersistenceStore.shared.loadLocalLibrary()
        var songs: [Song] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue } // 文件已删除则跳过
            if let song = await parseMetadata(url: url) { songs.append(song) }
        }
        importedSongs = songs
        return songs
    }

    private func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return importedSongs.contains { $0.localFileURL?.standardizedFileURL.path == path }
    }

    private func persistLibrary() {
        PersistenceStore.shared.saveLocalLibrary(importedSongs.compactMap { $0.localFileURL?.path })
    }

    /// 稳定的曲目 ID：基于规范化路径的 SHA-256（String.hash 每次进程启动都不同）
    private static func stableID(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func parseMetadata(url: URL) async -> Song? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        // 时长读不出来时 `CMTimeGetSeconds` 给的是 NaN / ±Infinity。
        // NaN 一旦进了 `Song.duration`，队列快照的 JSON 编码会**整份**失败
        // （详见 `PersistenceStore.makeJSONEncoder`），此后每次落盘都被吞掉。
        // iOS 侧 `MobileLocalLibrary` 一直是这么兜的，这里对齐它。
        let rawDuration = CMTimeGetSeconds(duration)
        let durationSeconds = rawDuration.isFinite ? rawDuration : 0

        var title = url.deletingPathExtension().lastPathComponent
        var artistName = "未知艺术家"
        var albumName = "未知专辑"
        var coverURL: URL?
        let fileID = Self.stableID(for: url)

        // 读取元数据
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                guard let key = item.commonKey?.rawValue else { continue }
                if let value = try? await item.load(.value) {
                    switch key {
                    case "title": if let s = value as? String { title = s }
                    case "artist": if let s = value as? String { artistName = s }
                    case "albumName": if let s = value as? String { albumName = s }
                    case "artwork":
                        if let data = value as? Data {
                            // 封面按稳定 ID 命名：重复解析不会产生新文件
                            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                                .appendingPathComponent("ClearTone/LocalCovers", isDirectory: true)
                            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                            let coverFile = cacheDir.appendingPathComponent("\(fileID).jpg")
                            if !FileManager.default.fileExists(atPath: coverFile.path) {
                                try? data.write(to: coverFile)
                            }
                            coverURL = coverFile
                        }
                    default: break
                    }
                }
            }
        }

        return Song(
            id: "local-\(fileID)",
            title: title,
            artists: [Artist(id: "local-artist-\(artistName)", name: artistName)],
            album: Album(id: "local-album-\(albumName)", name: albumName, coverURL: coverURL),
            duration: durationSeconds,
            coverURL: coverURL,
            isPlayable: true,
            source: .local,
            localFileURL: url
        )
    }

    // MARK: - MusicProvider（本地不支持的操作返回空或错误）

    public func fetchQRCodeKey() async throws -> String { throw MusicError.unknown("本地音乐不支持登录") }
    public func fetchQRCodeImage(key: String) async throws -> URL { throw MusicError.unknown("本地音乐不支持登录") }
    public func checkQRCodeStatus(key: String) async throws -> QRLoginStatus { .failed("本地音乐") }
    public func logout() async throws {}
    public func fetchAccountInfo() async throws -> AccountInfo? { nil }

    public func search(query: String, type: SearchType, page: Int, limit: Int) async throws -> SearchResult {
        let filtered = importedSongs.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.artistNames.localizedCaseInsensitiveContains(query)
        }
        let start = (page - 1) * limit
        let end = min(start + limit, filtered.count)
        return SearchResult(songs: start < end ? Array(filtered[start..<end]) : [], totalCount: filtered.count, hasMore: end < filtered.count)
    }

    public func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail { throw MusicError.unknown("本地音乐不支持歌单") }
    public func fetchPlaylistTracks(id: String, page: Int, limit: Int) async throws -> [Song] { [] }
    public func fetchAlbumDetail(id: String) async throws -> PlaylistDetail { throw MusicError.unknown("本地音乐不支持专辑") }
    public func fetchArtistDetail(id: String) async throws -> ArtistDetail { throw MusicError.unknown("本地音乐不支持歌手") }

    public func fetchPlayableURL(songID: String, quality: AudioQuality.QualityLevel) async throws -> PlayableURL {
        guard let song = importedSongs.first(where: { $0.id == songID }),
              let url = song.localFileURL else {
            throw MusicError.fileNotFound
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MusicError.fileNotFound
        }
        return PlayableURL(url: url, quality: AudioQuality(level: .unknown, isActual: true))
    }

    public func fetchLyrics(songID: String) async throws -> LyricResult {
        LyricResult(lines: [], hasWordTiming: false, isPureMusic: true)
    }

    public func fetchUserPlaylists() async throws -> [Playlist] { [] }
    public func fetchLikedSongs() async throws -> [Song] { [] }
    public func likeSong(id: String, like: Bool) async throws {}
    public func fetchRecommendPlaylists() async throws -> [Playlist] { [] }
    public func fetchDailyRecommendSongs() async throws -> [Song] { [] }
}
