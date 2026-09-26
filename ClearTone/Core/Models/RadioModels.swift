import Foundation

/// 电台（播客 / DJ 节目）
///
/// 网易云的电台与歌单是两类东西：电台下的「节目」是长音频（常为 1~60 分钟），
/// 节目本身携带一个 `mainSong`，它就是标准歌曲结构，播放时按歌曲走同一条链路
/// （`/song/url/v1` → 本地缓存 → AVPlayer）。所以 `RadioProgram` 只需额外
/// 保存所属电台与节目封面，不必自建播放逻辑。
public struct RadioStation: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var coverURL: URL?
    /// 节目数
    public var programCount: Int
    /// 订阅人数
    public var subscriberCount: Int
    public var creatorName: String?
    public var categoryName: String?
    public var descriptionText: String?
    public var isSubscribed: Bool

    public init(
        id: String,
        name: String,
        coverURL: URL? = nil,
        programCount: Int = 0,
        subscriberCount: Int = 0,
        creatorName: String? = nil,
        categoryName: String? = nil,
        descriptionText: String? = nil,
        isSubscribed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.programCount = programCount
        self.subscriberCount = subscriberCount
        self.creatorName = creatorName
        self.categoryName = categoryName
        self.descriptionText = descriptionText
        self.isSubscribed = isSubscribed
    }
}

/// 电台节目（一期）。`song` 是可直接播放的歌曲对象。
public struct RadioProgram: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var title: String
    public var coverURL: URL?
    /// 时长（秒）
    public var duration: TimeInterval
    public var createTime: Date?
    public var playCount: Int
    public var stationName: String?
    /// 节目主音频，按普通歌曲走播放链路
    public var song: Song?

    public init(
        id: String,
        title: String,
        coverURL: URL? = nil,
        duration: TimeInterval = 0,
        createTime: Date? = nil,
        playCount: Int = 0,
        stationName: String? = nil,
        song: Song? = nil
    ) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.duration = duration
        self.createTime = createTime
        self.playCount = playCount
        self.stationName = stationName
        self.song = song
    }

    /// 播放器需要的是 Song，没有主音频时不可播放
    public var isPlayable: Bool { song?.isPlayable ?? false }
}

/// 电台分类
public struct RadioCategory: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    /// 二级分类名（用于 /dj/hot?cat=）
    public var subCategories: [String]

    public init(id: String, name: String, subCategories: [String] = []) {
        self.id = id
        self.name = name
        self.subCategories = subCategories
    }
}
