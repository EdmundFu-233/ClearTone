import Foundation
@testable import ClearTone

/// `ArtistProfileSession` 的桩 Provider。
///
/// 刻意做成**可编排**的：每类接口都有对应的「页数组」与「闸门」，
/// 这样才能构造出「请求在途 → 换歌手 → 旧响应回来」这种时序 ——
/// 而那正是这个 session 存在的理由。
final class StubArtistProvider: ArtistProfileProviding, @unchecked Sendable {

    // MARK: - 编排数据

    var profile: ArtistProfile = .fixture()
    var songPages: [ArtistSongPage] = [.empty]
    var albumPages: [ArtistAlbumPage] = [.empty]
    var mvPages: [ArtistMVPage] = [.empty]
    var intro: ArtistIntro = ArtistIntro()
    var hotSongs: [Song] = []
    var similarArtists: [Artist] = []

    var failProfile = false
    var failSongPage = false
    var failNextSongPage = false
    var failHighlights = false

    // MARK: - 闸门

    var songGate: ControlledGate?
    var albumGate: ControlledGate?

    // MARK: - 记录

    private let lock = NSLock()
    private var _songOffsets: [Int] = []
    private var _albumOffsets: [Int] = []
    private var _mvOffsets: [Int] = []

    var requestedSongOffsets: [Int] { lock.withLock { _songOffsets } }
    var requestedAlbumOffsets: [Int] { lock.withLock { _albumOffsets } }
    var requestedMVOffsets: [Int] { lock.withLock { _mvOffsets } }

    private var songPageIndex = 0
    private var albumPageIndex = 0
    private var mvPageIndex = 0

    // MARK: - ArtistProfileProviding

    func fetchArtistProfile(id: String) async throws -> ArtistProfile {
        if failProfile { throw MusicError.notLoggedIn }
        return profile
    }

    func fetchArtistSongs(id: String, offset: Int, limit: Int, order: String) async throws -> ArtistSongPage {
        await songGate?.hold()
        lock.withLock { _songOffsets.append(offset) }
        if failSongPage || failNextSongPage {
            failNextSongPage = false
            throw MusicError.apiError(code: 524, message: "风控")
        }
        let page = songPages[min(songPageIndex, songPages.count - 1)]
        songPageIndex += 1
        return page
    }

    func fetchArtistAlbums(id: String, offset: Int, limit: Int) async throws -> ArtistAlbumPage {
        await albumGate?.hold()
        lock.withLock { _albumOffsets.append(offset) }
        let page = albumPages[min(albumPageIndex, albumPages.count - 1)]
        albumPageIndex += 1
        return page
    }

    func fetchArtistMVs(id: String, offset: Int, limit: Int) async throws -> ArtistMVPage {
        lock.withLock { _mvOffsets.append(offset) }
        let page = mvPages[min(mvPageIndex, mvPages.count - 1)]
        mvPageIndex += 1
        return page
    }

    func fetchArtistIntro(id: String) async throws -> ArtistIntro { intro }

    func fetchHotArtistSongs(id: String) async throws -> [Song] {
        if failHighlights { throw MusicError.invalidResponse }
        return hotSongs
    }

    func fetchSimilarArtists(artistID: String) async throws -> [Artist] {
        if failHighlights { throw MusicError.invalidResponse }
        return similarArtists
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
