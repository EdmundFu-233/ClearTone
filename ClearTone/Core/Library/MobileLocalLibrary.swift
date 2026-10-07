import Foundation
import AVFoundation
import Combine

@MainActor
final class MobileLocalLibrary: ObservableObject {
    @Published private(set) var songs: [Song]
    private let directory: URL
    init() {
        directory = PersistenceStore.storageRoot.appendingPathComponent("LocalAudio", isDirectory: true)
        songs = PersistenceStore.shared.loadSetting(forKey: "mobileLocalSongs", as: [Song].self) ?? []
        // App 更新后容器路径可能变化，按受控文件名重建 URL。
        songs = songs.map { song in
            var rebuilt = song
            if let name = song.localFileURL?.lastPathComponent { rebuilt.localFileURL = directory.appendingPathComponent(name) }
            return rebuilt
        }
    }
    func importFiles(_ urls: [URL]) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in urls {
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
