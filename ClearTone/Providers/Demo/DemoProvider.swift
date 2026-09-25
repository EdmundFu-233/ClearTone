import Foundation

/// 演示数据 Provider，用于无账户环境验证所有 UI
public actor DemoProvider: MusicProvider {
    public let identifier = "demo"
    public let displayName = "演示模式"

    /// 全局共享实例：init 里会 mkdir 并构造 20 个 Song，
    /// 若每个 View 各建一个实例，视图每次重建都会重做一遍（视图会因播放进度频繁重建）
    public static let shared = DemoProvider()

    private let demoSongs: [Song]
    private let demoPlaylists: [Playlist]

    public init() {
        // 生成测试音频文件路径
        let audioDir = Self.demoAudioDirectory()
        let songs: [Song] = (1...20).map { i in
            let hasLyrics = i % 3 != 0
            let title: String
            switch i {
            case 1: title = "短音频测试"
            case 2: title = "静音测试音频"
            case 3: title = "低频正弦波 440Hz"
            case 4: title = "中频正弦波 1000Hz"
            case 5: title = "高频正弦波 5000Hz"
            case 6: title = "白噪声"
            case 7: title = "扫频信号"
            case 8: title = "超长歌名测试这是一首非常非常长的歌曲名称用来验证UI截断和换行处理是否正常工作"
            case 9: title = "English Song Title Mixed"
            case 10: title = "🎵 Emoji 歌曲 🎵"
            case 11: title = "多歌手合作曲目"
            case 12: title = "无封面测试曲"
            case 13: title = "无歌词纯音乐"
            case 14: title = "权限不足模拟"
            case 15: title = "VIP 专享模拟"
            case 16: title = "已下架模拟"
            case 17: title = "正常歌曲 A"
            case 18: title = "正常歌曲 B"
            case 19: title = "正常歌曲 C"
            case 20: title = "正常歌曲 D"
            default: title = "演示歌曲 \(i)"
            }

            var artists = [Artist(id: "demo-artist-\(i)", name: "演示歌手 \(i)")]
            if i == 11 {
                artists = [
                    Artist(id: "demo-artist-11a", name: "歌手甲"),
                    Artist(id: "demo-artist-11b", name: "歌手乙"),
                    Artist(id: "demo-artist-11c", name: "歌手丙"),
                ]
            }

            let isPlayable = ![14, 15, 16].contains(i)
            let reason: String?
            switch i {
            case 14: reason = "版权限制"
            case 15: reason = "VIP 专享"
            case 16: reason = "歌曲已下架"
            default: reason = nil
            }

            return Song(
                id: "demo-\(i)",
                title: title,
                artists: artists,
                album: Album(id: "demo-album-\(i)", name: "演示专辑 \(i)"),
                duration: 30, // 与生成的演示音频（30 秒）保持一致，避免进度条与实际音频不符
                coverURL: nil,
                isPlayable: isPlayable,
                unavailableReason: reason,
                qualities: [
                    AudioQuality(level: .standard, bitrate: 128, isActual: false),
                    AudioQuality(level: .exhigh, bitrate: 320, isActual: true),
                ],
                source: .demo
            )
        }
        self.demoSongs = songs

        self.demoPlaylists = [
            Playlist(id: "demo-pl-1", name: "演示歌单 - 全部测试", trackCount: 20, creatorName: "澄音演示", source: .demo),
            Playlist(id: "demo-pl-2", name: "长歌名测试", trackCount: 3, creatorName: "澄音演示", source: .demo),
            Playlist(id: "demo-pl-3", name: "无歌词纯音乐", trackCount: 2, creatorName: "澄音演示", source: .demo),
            Playlist(id: "demo-pl-4", name: "权限与异常状态", trackCount: 3, creatorName: "澄音演示", source: .demo),
            Playlist(id: "demo-pl-5", name: "多语言混合", trackCount: 4, creatorName: "澄音演示", source: .demo),
        ]

        // 确保演示音频目录存在
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    }

    public static func demoAudioDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClearTone/DemoAudio", isDirectory: true)
    }

    /// 演示音频文件名清单
    public static let demoAudioFiles = [
        "tone_440.wav", "tone_1000.wav", "tone_5000.wav", "silence.wav", "sweep.wav", "noise.wav",
    ]

    /// 确保演示音频已就绪，在后台线程执行。
    ///
    /// 原实现在 `App.init` 里同步调用：6 × 132 万样本、约 530 万次 sin()、
    /// 约 32MB 写入全部阻塞主线程，首帧前会白屏数秒。
    public static func ensureDemoAudio() async {
        await withTaskGroup(of: Void.self) { group in
            for file in demoAudioFiles {
                group.addTask {
                    generateDemoAudioIfNeeded(for: file)
                }
            }
        }
    }

    /// 生成单个测试音频文件（已存在且非空则跳过）。
    /// 暴露为 nonisolated 供测试直接调用。
    public nonisolated static func generateDemoAudioIfNeeded(for file: String) {
        let dir = demoAudioDirectory()
        let url = dir.appendingPathComponent(file)
        // 文件存在且有内容就认为已生成：避免每次启动都过一遍完整生成逻辑
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 44 {
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DemoAudioGenerator.generate(type: file, to: url)
    }

    // MARK: - MusicProvider 实现

    public func fetchQRCodeKey() async throws -> String { throw MusicError.unknown("演示模式不支持登录") }
    public func fetchQRCodeImage(key: String) async throws -> URL { throw MusicError.unknown("演示模式不支持登录") }
    public func checkQRCodeStatus(key: String) async throws -> QRLoginStatus { .failed("演示模式") }
    public func logout() async throws {}
    public func fetchAccountInfo() async throws -> AccountInfo? { nil }

    public func search(query: String, type: SearchType, page: Int, limit: Int) async throws -> SearchResult {
        let filtered = demoSongs.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.artistNames.localizedCaseInsensitiveContains(query) ||
            ($0.album?.name.localizedCaseInsensitiveContains(query) ?? false)
        }
        let start = (page - 1) * limit
        let end = min(start + limit, filtered.count)
        let pageSongs = start < end ? Array(filtered[start..<end]) : []

        return SearchResult(
            songs: pageSongs,
            artists: type == .artist ? [Artist(id: "demo-artist-1", name: "演示歌手")] : [],
            albums: type == .album ? [Album(id: "demo-album-1", name: "演示专辑")] : [],
            playlists: type == .playlist ? demoPlaylists.filter { $0.name.localizedCaseInsensitiveContains(query) } : [],
            totalCount: filtered.count,
            hasMore: end < filtered.count
        )
    }

    public func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail {
        guard let playlist = demoPlaylists.first(where: { $0.id == id }) else {
            throw MusicError.unknown("歌单不存在")
        }
        return PlaylistDetail(playlist: playlist, tracks: demoSongs, totalTrackCount: demoSongs.count)
    }

    public func fetchPlaylistTracks(id: String, page: Int, limit: Int) async throws -> [Song] {
        let start = (page - 1) * limit
        let end = min(start + limit, demoSongs.count)
        return start < end ? Array(demoSongs[start..<end]) : []
    }

    public func fetchAlbumDetail(id: String) async throws -> PlaylistDetail {
        let album = Album(id: id, name: "演示专辑")
        let playlist = Playlist(id: id, name: album.name, trackCount: demoSongs.count, source: .demo)
        return PlaylistDetail(playlist: playlist, tracks: demoSongs, totalTrackCount: demoSongs.count)
    }

    public func fetchArtistDetail(id: String) async throws -> ArtistDetail {
        ArtistDetail(artist: Artist(id: id, name: "演示歌手"), hotSongs: demoSongs, albums: [])
    }

    public func fetchPlayableURL(songID: String, quality: AudioQuality.QualityLevel) async throws -> PlayableURL {
        let dir = Self.demoAudioDirectory()
        let fileName: String
        switch songID {
        case "demo-1": fileName = "tone_440.wav"
        case "demo-2": fileName = "silence.wav"
        case "demo-3": fileName = "tone_440.wav"
        case "demo-4": fileName = "tone_1000.wav"
        case "demo-5": fileName = "tone_5000.wav"
        case "demo-6": fileName = "noise.wav"
        case "demo-7": fileName = "sweep.wav"
        default: fileName = "tone_440.wav"
        }
        let url = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MusicError.fileNotFound
        }
        return PlayableURL(url: url, quality: AudioQuality(level: .exhigh, bitrate: 320, isActual: true))
    }

    public func fetchLyrics(songID: String) async throws -> LyricResult {
        if songID == "demo-13" {
            return LyricResult(lines: [], hasWordTiming: false, isPureMusic: true)
        }

        // 生成模拟歌词
        var lines: [LyricLine] = []
        for i in 0..<10 {
            let time = TimeInterval(i * 20)
            lines.append(LyricLine(
                time: time,
                text: "这是第 \(i + 1) 行演示歌词",
                translation: i % 2 == 0 ? "This is demo lyric line \(i + 1)" : nil
            ))
        }
        return LyricResult(lines: lines, hasWordTiming: false, isPureMusic: false)
    }

    public func fetchUserPlaylists() async throws -> [Playlist] { demoPlaylists }
    public func fetchLikedSongs() async throws -> [Song] { Array(demoSongs.prefix(5)) }
    public func likeSong(id: String, like: Bool) async throws {}
    public func fetchRecommendPlaylists() async throws -> [Playlist] { demoPlaylists }
    public func fetchDailyRecommendSongs() async throws -> [Song] { Array(demoSongs.prefix(10)) }
}

/// 演示音频生成器（使用 Accelerate 生成 WAV）
public enum DemoAudioGenerator {
    public static func generate(type: String, to url: URL) {
        let sampleRate: Double = 44100
        let duration: Double = 30 // 30 秒
        let frameCount = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: frameCount)

        let twoPi: Double = 2 * .pi
        switch type {
        case "tone_440.wav":
            let freq: Double = 440
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                samples[i] = Float(sin(twoPi * freq * t) * 0.5)
            }
        case "tone_1000.wav":
            let freq: Double = 1000
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                samples[i] = Float(sin(twoPi * freq * t) * 0.5)
            }
        case "tone_5000.wav":
            let freq: Double = 5000
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                samples[i] = Float(sin(twoPi * freq * t) * 0.3)
            }
        case "silence.wav":
            break
        case "sweep.wav":
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                let freq = 20 + (20000 - 20) * t / duration
                samples[i] = Float(sin(twoPi * freq * t) * 0.4)
            }
        case "noise.wav":
            for i in 0..<frameCount { samples[i] = Float.random(in: -0.3...0.3) }
        default:
            let freq: Double = 440
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                samples[i] = Float(sin(twoPi * freq * t) * 0.5)
            }
        }

        writeWAV(samples: samples, sampleRate: sampleRate, to: url)
    }

    private static func writeWAV(samples: [Float], sampleRate: Double, to url: URL) {
        let dataSize = samples.count * 2
        // WAV 头固定 44 字节；RIFF 字段按约定存「文件大小 - 8」= 36 + dataSize
        let headerSize = 44
        let fileSize = headerSize + dataSize
        let riffSize = fileSize - 8

        // 一次性分配：原先逐样本 append 会产生上百万次 Data 扩容拷贝。
        // 头部与样本区都在同一个 withUnsafeMutableBytes 里写完，避免在块外操作裸指针。
        var data = Data(count: fileSize)
        data.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!

            func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
                var v = value.littleEndian
                withUnsafeBytes(of: &v) { src in
                    UnsafeMutableRawPointer(base + offset)
                        .copyMemory(from: src.baseAddress!, byteCount: MemoryLayout<T>.size)
                }
            }
            func putBytes(_ bytes: [UInt8], at offset: Int) {
                let dst = UnsafeMutableRawPointer(base + offset).assumingMemoryBound(to: UInt8.self)
                for (i, b) in bytes.enumerated() { dst[i] = b }
            }
            putBytes([0x52, 0x49, 0x46, 0x46], at: 0)      // "RIFF"
            put(UInt32(riffSize), at: 4)
            putBytes([0x57, 0x41, 0x56, 0x45], at: 8)      // "WAVE"
            putBytes([0x66, 0x6D, 0x74, 0x20], at: 12)     // "fmt "
            put(UInt32(16), at: 16)
            put(UInt16(1), at: 20)                         // PCM
            put(UInt16(1), at: 22)                         // mono
            put(UInt32(sampleRate), at: 24)
            put(UInt32(sampleRate * 2), at: 28)            // byte rate
            put(UInt16(2), at: 32)                         // block align
            put(UInt16(16), at: 34)                        // bits
            putBytes([0x64, 0x61, 0x74, 0x61], at: 36)     // "data"
            put(UInt32(dataSize), at: 40)

            // 样本区批量转换写入，替代逐样本 append（偏移 44 对 Int16 是对齐的）
            let dst = UnsafeMutableRawPointer(base + 44).assumingMemoryBound(to: Int16.self)
            for (i, sample) in samples.enumerated() {
                dst[i] = Int16(max(-1, min(1, sample)) * 32767)
            }
        }

        try? data.write(to: url)
    }
}
