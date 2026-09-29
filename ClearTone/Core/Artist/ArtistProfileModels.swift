import Foundation

/// 歌手资料页的数据模型。
///
/// ## 为什么不都塞进 `MusicProvider.ArtistDetail`
///
/// 歌手页有五块可独立加载、互不依赖的内容（简介 / 热门 / 全部歌曲 / 专辑 / MV），
/// 每块都有自己的分页与失败降级。合成一个大结构体意味着「专辑挂了 → 整页白屏」，
/// 所以这里把它们拆成独立的轻量结果类型，由 `ArtistProfileSession` 各自管理。
///
/// 所有字段的来源都对着 `HelperRuntime/api/module/artist_*.js` 与实测响应核过：
/// - `ArtistProfile` ← `/api/artist/head/info/get`（eapi）
/// - `ArtistIntro`   ← `/api/artist/introduction`（weapi）
/// - `ArtistSongPage`← `/api/v1/artist/songs`（eapi）
/// - `ArtistAlbumPage`← `/api/artist/albums/{id}`（weapi）
/// - `ArtistMV`      ← `/api/artist/mvs`（weapi）

/// `/api/artist/head/info/get` 的 `data.artist`。
///
/// 注意这个接口**不返回 `picUrl`**，图片字段叫 `cover` / `avatar`。
public struct ArtistProfile: Sendable, Equatable {
    public var artist: Artist
    /// `briefDesc`：一句话简介（实测周杰伦 665 字，是完整简介而非一句话）
    public var briefDescription: String?
    public var albumCount: Int
    public var songCount: Int
    public var mvCount: Int
    public var videoCount: Int
    /// `data.identify`：身份标签（`{"identifyTag": [...]}`）
    public var identifyTags: [String]
    /// 服务端返回的 `followed`。仅登录态下有值；nil = 未知。
    public var isFollowed: Bool?

    public init(
        artist: Artist,
        briefDescription: String? = nil,
        albumCount: Int = 0,
        songCount: Int = 0,
        mvCount: Int = 0,
        videoCount: Int = 0,
        identifyTags: [String] = [],
        isFollowed: Bool? = nil
    ) {
        self.artist = artist
        self.briefDescription = briefDescription
        self.albumCount = albumCount
        self.songCount = songCount
        self.mvCount = mvCount
        self.videoCount = videoCount
        self.identifyTags = identifyTags
        self.isFollowed = isFollowed
    }
}

/// 歌手介绍的一段。`/api/artist/introduction` 返回 `[{ ti, txt }]`，
/// `ti` 是段标题（实测「主要成就」），`txt` 是正文。
public struct ArtistIntroSection: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var title: String
    public var body: String

    public init(id: UUID = UUID(), title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

/// 歌手资料页需要的那几个接口。
///
/// ## 为什么不直接依赖 `NeteaseProvider`
///
/// `NeteaseProvider` 是个 `actor`，没法在测试里替身；而
/// `ArtistProfileSession` 的全部价值就是**分页与代次隔离**这些异步边界行为，
/// 恰恰是最需要测的部分。所以这里抽一个只含这五个方法的窄协议，
/// 测试用桩实现，生产用 `NeteaseProvider`（它本来就有这些方法，直接conform）。
///
/// 也不加进 `MusicProvider`：那是播放闭环的最小面，
/// 本地 Provider 没有网易云歌手资料，加了只能加一堆 `throw .unsupported`。
public protocol ArtistProfileProviding: Sendable {
    func fetchArtistProfile(id: String) async throws -> ArtistProfile
    func fetchArtistSongs(id: String, offset: Int, limit: Int, order: String) async throws -> ArtistSongPage
    func fetchArtistAlbums(id: String, offset: Int, limit: Int) async throws -> ArtistAlbumPage
    func fetchArtistMVs(id: String, offset: Int, limit: Int) async throws -> ArtistMVPage
    func fetchArtistIntro(id: String) async throws -> ArtistIntro
    func fetchHotArtistSongs(id: String) async throws -> [Song]
    func fetchSimilarArtists(artistID: String) async throws -> [Artist]
}

public struct ArtistIntro: Sendable, Equatable {
    public var briefDescription: String?
    public var sections: [ArtistIntroSection]

    public init(briefDescription: String? = nil, sections: [ArtistIntroSection] = []) {
        self.briefDescription = briefDescription
        self.sections = sections
    }

    public var isEmpty: Bool { sections.isEmpty && (briefDescription?.isEmpty ?? true) }
}

/// `/api/v1/artist/songs` 的一页。
///
/// `more` 与 `total` 是两个独立信号：`more` 决定还能不能继续翻，
/// `total` 用来显示「第 N 首 / 共 566 首」。实测 `total` 会大于已加载的 `songs.count`。
public struct ArtistSongPage: Sendable, Equatable {
    public var songs: [Song]
    public var total: Int
    public var hasMore: Bool

    public init(songs: [Song], total: Int, hasMore: Bool) {
        self.songs = songs
        self.total = total
        self.hasMore = hasMore
    }

    public static let empty = ArtistSongPage(songs: [], total: 0, hasMore: false)
}

/// `/api/artist/albums/{id}` 的一页。
public struct ArtistAlbumPage: Sendable, Equatable {
    public var albums: [Album]
    /// 服务端在响应的 `artist` 里回带了 `followed` —— 关注按钮的初始状态从这里取，
    /// 不用再单独打一次接口。
    public var isFollowed: Bool?
    public var hasMore: Bool

    public init(albums: [Album], isFollowed: Bool? = nil, hasMore: Bool = false) {
        self.albums = albums
        self.isFollowed = isFollowed
        self.hasMore = hasMore
    }

    public static let empty = ArtistAlbumPage(albums: [], hasMore: false)
}

/// 歌手 MV。`/api/artist/mvs` 的元素结构与歌曲差别很大：
/// 没有 `ar`/`al`，歌手名是扁平的 `artistName`，封面是 `imgurl16v9`。
public struct ArtistMV: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var artistName: String?
    public var coverURL: URL?
    public var duration: TimeInterval
    public var playCount: Int
    public var publishDate: Date?

    public init(
        id: String,
        name: String,
        artistName: String? = nil,
        coverURL: URL? = nil,
        duration: TimeInterval = 0,
        playCount: Int = 0,
        publishDate: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.artistName = artistName
        self.coverURL = coverURL
        self.duration = duration
        self.playCount = playCount
        self.publishDate = publishDate
    }
}

public struct ArtistMVPage: Sendable, Equatable {
    public var mvs: [ArtistMV]
    public var hasMore: Bool

    public init(mvs: [ArtistMV], hasMore: Bool = false) {
        self.mvs = mvs
        self.hasMore = hasMore
    }

    public static let empty = ArtistMVPage(mvs: [], hasMore: false)
}
