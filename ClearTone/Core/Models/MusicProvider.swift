import Foundation

/// 统一的音乐数据提供方协议，隔离上游差异（真实网易云 / 本地）
public protocol MusicProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }

    // MARK: - 认证
    func fetchQRCodeKey() async throws -> String
    func fetchQRCodeImage(key: String) async throws -> URL
    func checkQRCodeStatus(key: String) async throws -> QRLoginStatus
    func logout() async throws
    func fetchAccountInfo() async throws -> AccountInfo?

    // MARK: - 内容
    func search(query: String, type: SearchType, page: Int, limit: Int) async throws -> SearchResult
    func fetchPlaylistDetail(id: String) async throws -> PlaylistDetail
    func fetchPlaylistTracks(id: String, page: Int, limit: Int) async throws -> [Song]
    func fetchAlbumDetail(id: String) async throws -> PlaylistDetail
    func fetchArtistDetail(id: String) async throws -> ArtistDetail
    func fetchPlayableURL(songID: String, quality: AudioQuality.QualityLevel) async throws -> PlayableURL
    func fetchLyrics(songID: String) async throws -> LyricResult
    func fetchUserPlaylists() async throws -> [Playlist]
    func fetchLikedSongs() async throws -> [Song]
    func likeSong(id: String, like: Bool) async throws
    func fetchRecommendPlaylists() async throws -> [Playlist]
    func fetchDailyRecommendSongs() async throws -> [Song]

    // MARK: - 账号生命周期

    /// 全量收藏 id。心形状态靠它判断，必须完整 —— 详情列表可能只装得下一小部分。
    ///
    /// 默认从详情列表推导，够用但慢；有批量接口的实现（网易云 `/likelist`）应覆盖。
    func fetchLikedSongIDs() async throws -> [String]
}

public extension MusicProvider {
    func fetchLikedSongIDs() async throws -> [String] {
        try await fetchLikedSongs().map(\.id)
    }
}

public enum QRLoginStatus: Sendable {
    case waitingScan
    case scannedWaitingConfirm
    case success(cookie: String)
    case expired
    case failed(String)
}

public struct AccountInfo: Sendable, Codable {
    public var userID: String
    public var nickname: String
    public var avatarURL: URL?
    public var isVIP: Bool
    public init(userID: String, nickname: String, avatarURL: URL? = nil, isVIP: Bool = false) {
        self.userID = userID; self.nickname = nickname; self.avatarURL = avatarURL; self.isVIP = isVIP
    }
}

public enum SearchType: String, Sendable, CaseIterable {
    case song = "单曲"
    case artist = "歌手"
    case album = "专辑"
    case playlist = "歌单"
}

public struct SearchResult: Sendable {
    public var songs: [Song]
    public var artists: [Artist]
    public var albums: [Album]
    public var playlists: [Playlist]
    public var totalCount: Int
    public var hasMore: Bool

    public init(songs: [Song] = [], artists: [Artist] = [], albums: [Album] = [], playlists: [Playlist] = [], totalCount: Int = 0, hasMore: Bool = false) {
        self.songs = songs; self.artists = artists; self.albums = albums; self.playlists = playlists; self.totalCount = totalCount; self.hasMore = hasMore
    }

    /// 四种结果全空才算「没搜到」。
    ///
    /// 早期只判断 songs 是否为空，于是「搜专辑有结果、但当前类型是单曲」
    /// 会被判成无结果而显示空白页。
    public var isEmpty: Bool {
        songs.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
    }
}

public struct PlaylistDetail: Sendable {
    public var playlist: Playlist
    public var tracks: [Song]
    public var totalTrackCount: Int
    /// 专辑的艺人 id。歌单没有这个概念，所以是 optional。
    ///
    /// 之前专辑页那个歌手名是个 `Button(artist) { }` —— 有焦点、能点、什么都不做，
    /// 因为当时只往 `Playlist.creatorName` 里塞了名字，id 根本没地方放。
    public var artistID: String?
    public init(playlist: Playlist, tracks: [Song], totalTrackCount: Int, artistID: String? = nil) {
        self.playlist = playlist; self.tracks = tracks; self.totalTrackCount = totalTrackCount
        self.artistID = artistID
    }
}

public struct ArtistDetail: Sendable {
    public var artist: Artist
    public var hotSongs: [Song]
    public var albums: [Album]
    public init(artist: Artist, hotSongs: [Song], albums: [Album]) {
        self.artist = artist; self.hotSongs = hotSongs; self.albums = albums
    }
}

public struct LyricResult: Sendable {
    public var lines: [LyricLine]
    public var hasWordTiming: Bool
    public var isPureMusic: Bool
    public init(lines: [LyricLine], hasWordTiming: Bool, isPureMusic: Bool) {
        self.lines = lines; self.hasWordTiming = hasWordTiming; self.isPureMusic = isPureMusic
    }
}
