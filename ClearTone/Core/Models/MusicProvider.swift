import Foundation

/// 统一的音乐数据提供方协议，隔离上游差异（真实网易云 / 本地 / 演示）
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
}

public struct PlaylistDetail: Sendable {
    public var playlist: Playlist
    public var tracks: [Song]
    public var totalTrackCount: Int
    public init(playlist: Playlist, tracks: [Song], totalTrackCount: Int) {
        self.playlist = playlist; self.tracks = tracks; self.totalTrackCount = totalTrackCount
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
