import Foundation
import AVFoundation
import Combine

@MainActor
final class MobileLocalLibrary: ObservableObject {
    @Published private(set) var songs: [Song]
    private let directory: URL
    init() {
        // 用局部常量，避免闭包在 `songs` 初始化完成前捕获 self
        let dir = PersistenceStore.storageRoot.appendingPathComponent("LocalAudio", isDirectory: true)
        directory = dir
        let stored = PersistenceStore.shared.loadSetting(forKey: "mobileLocalSongs", as: [Song].self) ?? []
        // App 更新后容器路径可能变化，按受控文件名重建 URL；文件已不在的条目
        // 不显示（否则留下永远播不了的死行）。**只过滤、不回写**：`fileExists`
        // 在数据保护未就绪等瞬时情况下也会返回 false，回写会把好条目永久删掉。
        // 与 macOS 的 `LocalProvider.restoreLibrary` 同策略。
        songs = stored.compactMap { song -> Song? in
            guard let name = song.localFileURL?.lastPathComponent else { return nil }
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var rebuilt = song
            rebuilt.localFileURL = url
            return rebuilt
        }
    }
    func importFiles(_ urls: [URL]) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 同一批里出现重复来源路径时只导入一次
        var seen = Set<String>()
        for url in urls {
            guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let id = UUID().uuidString
            let destination = directory.appendingPathComponent(id + "." + url.pathExtension)
            try FileManager.default.copyItem(at: url, to: destination)
            let asset = AVURLAsset(url: destination)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            songs.append(Song(id: "local-" + id, title: url.deletingPathExtension().lastPathComponent,
                              artists: [Artist(id: "local", name: "本地音乐")], duration: duration.isFinite ? duration : 0,
                              source: .local, localFileURL: destination))
            PersistenceStore.shared.saveSetting(songs, forKey: "mobileLocalSongs")
        }
    }
}
