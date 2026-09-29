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
    /// 头像。原来整个类型只有 id + name，于是歌手页只能画一个写死的
    /// `person.fill` 圆盘，相似歌手卡片也永远是灰的。
    ///
    /// 四个来源字段（`/artist/detail` 给 `cover`/`avatar`，
    /// `/simi/artist` 与 `/artist/album` 给 `picUrl`/`img1v1Url`）都要认。
    public var avatarURL: URL?
    /// 别名（`["Jay Chou","周董"]`）。取第一个非空值用于副标题。
    public var alias: [String]

    public init(id: String, name: String, avatarURL: URL? = nil, alias: [String] = []) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.alias = alias
    }

    /// 有别名时显示 `周杰伦 · Jay Chou`
    public var displayNameWithAlias: String {
        guard let first = alias.first(where: { !$0.isEmpty && $0 != name }) else { return name }
        return "\(name) · \(first)"
    }
}

public struct Album: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var coverURL: URL?
    public init(id: String, name: String, coverURL: URL? = nil) { self.id = id; self.name = name; self.coverURL = coverURL }
}

public enum SongSource: String, Codable, Sendable {
    case netease, local

    /// 演示模式已移除，但旧版本往 `queue.json` 里写过 `"source": "demo"`。
    ///
    /// 严格 enum（编译器合成的 `init(from:)`）碰到未知 rawValue 会抛错，
    /// 而 `PersistedQueue` 是整份解码的 —— 一首歌解不出来，**整条队列都没了**。
    /// 代价远大于收益，所以这里降级成 `.netease`：那条演示歌曲随后会被
    /// `PersistenceStore.loadQueue` 按 id 命名空间过滤掉。
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SongSource(rawValue: raw) ?? .netease
    }
}

public struct AudioQuality: Hashable, Codable, Sendable {
    public var level: QualityLevel
    public var bitrate: Int?     // kbps
    public var sampleRate: Int?  // Hz
    public var bitDepth: Int?
    public var isActual: Bool    // true = 实际返回, false = 请求音质
    /// 实际编码（"MP3" / "AAC" / "FLAC" / "OPUS"…）。缓存与在线流都要显示它，
    /// 光有码率看不出是 AAC 256k 还是 FLAC 1050k
    public var codec: String?

    public enum QualityLevel: String, Codable, Sendable, CaseIterable {
        case standard = "标准"
        case higher = "较高"
        case exhigh = "极高"
        case lossless = "无损"
        case hires = "Hi-Res"
        case unknown = "未知"
    }

    public init(level: QualityLevel, bitrate: Int? = nil, sampleRate: Int? = nil, bitDepth: Int? = nil, isActual: Bool = false, codec: String? = nil) {
        self.level = level; self.bitrate = bitrate; self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.isActual = isActual; self.codec = codec
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
    /// 文件字节数。无损流（FLAC）接口常把 br 报成 0，靠它反算真实码率
    public var sizeBytes: Int?
    public init(url: URL, quality: AudioQuality, expiresAt: Date? = nil, isPreview: Bool = false, isCached: Bool = false, sizeBytes: Int? = nil) {
        self.url = url; self.quality = quality; self.expiresAt = expiresAt; self.isPreview = isPreview; self.isCached = isCached; self.sizeBytes = sizeBytes
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
