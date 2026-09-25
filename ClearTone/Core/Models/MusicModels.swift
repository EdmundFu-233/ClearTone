import Foundation

/// 大整数 ID 使用字符串，避免浮点精度丢失
public struct Song: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var title: String
    public var artists: [Artist]
    public var album: Album?
    public var duration: TimeInterval  // seconds
    public var coverURL: URL?
    public var isPlayable: Bool
    public var unavailableReason: String?
    public var qualities: [AudioQuality]  // 请求音质 -> 实际返回音质
    public var source: SongSource
    public var localFileURL: URL?  // 本地文件播放地址

    public init(id: String, title: String, artists: [Artist], album: Album? = nil,
                duration: TimeInterval = 0, coverURL: URL? = nil, isPlayable: Bool = true,
                unavailableReason: String? = nil, qualities: [AudioQuality] = [], source: SongSource,
                localFileURL: URL? = nil) {
        self.id = id; self.title = title; self.artists = artists; self.album = album
        self.duration = duration; self.coverURL = coverURL; self.isPlayable = isPlayable
        self.unavailableReason = unavailableReason; self.qualities = qualities; self.source = source
        self.localFileURL = localFileURL
    }

    public var artistNames: String { artists.map(\.name).joined(separator: " / ") }
}

public struct Artist: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct Album: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var coverURL: URL?
    public init(id: String, name: String, coverURL: URL? = nil) { self.id = id; self.name = name; self.coverURL = coverURL }
}

public enum SongSource: String, Codable, Sendable {
    case netease, local, demo
}

public struct AudioQuality: Hashable, Codable, Sendable {
    public var level: QualityLevel
    public var bitrate: Int?     // kbps
    public var sampleRate: Int?  // Hz
    public var bitDepth: Int?
    public var isActual: Bool    // true = 实际返回, false = 请求音质

    public enum QualityLevel: String, Codable, Sendable, CaseIterable {
        case standard = "标准"
        case higher = "较高"
        case exhigh = "极高"
        case lossless = "无损"
        case hires = "Hi-Res"
        case unknown = "未知"
    }

    public init(level: QualityLevel, bitrate: Int? = nil, sampleRate: Int? = nil, bitDepth: Int? = nil, isActual: Bool = false) {
        self.level = level; self.bitrate = bitrate; self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.isActual = isActual
    }
}

public struct Playlist: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var coverURL: URL?
    public var trackCount: Int
    public var creatorName: String?
    public var descriptionText: String?
    public var isSubscribed: Bool
    public var source: SongSource

    public init(id: String, name: String, coverURL: URL? = nil, trackCount: Int = 0,
                creatorName: String? = nil, descriptionText: String? = nil, isSubscribed: Bool = false, source: SongSource) {
        self.id = id; self.name = name; self.coverURL = coverURL; self.trackCount = trackCount
        self.creatorName = creatorName; self.descriptionText = descriptionText; self.isSubscribed = isSubscribed; self.source = source
    }
}

public struct PlayableURL: Sendable {
    public var url: URL
    public var quality: AudioQuality
    public var expiresAt: Date?
    /// 是否为 30 秒试听流（试听源不进入音频缓存）
    public var isPreview: Bool
    /// 是否来自本地音频缓存
    public var isCached: Bool
    public init(url: URL, quality: AudioQuality, expiresAt: Date? = nil, isPreview: Bool = false, isCached: Bool = false) {
        self.url = url; self.quality = quality; self.expiresAt = expiresAt
        self.isPreview = isPreview; self.isCached = isCached
    }
}

/// 歌词行（支持普通 LRC 与逐字 YRC）
public struct LyricLine: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var time: TimeInterval       // 行开始时间（秒）
    public var text: String
    public var translation: String?
    public var romanization: String?
    public var words: [LyricWord]?      // 逐字时间，无则 nil

    public init(id: UUID = UUID(), time: TimeInterval, text: String, translation: String? = nil,
                romanization: String? = nil, words: [LyricWord]? = nil) {
        self.id = id; self.time = time; self.text = text; self.translation = translation
        self.romanization = romanization; self.words = words
    }
}

public struct LyricWord: Hashable, Sendable {
    public var time: TimeInterval
    public var duration: TimeInterval
    public var text: String
    public init(time: TimeInterval, duration: TimeInterval, text: String) { self.time = time; self.duration = duration; self.text = text }
}
