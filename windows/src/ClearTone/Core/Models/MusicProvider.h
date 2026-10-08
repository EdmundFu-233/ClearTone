#pragma once

#include "Core/Async.h"
#include "Core/Models/MusicModels.h"

namespace ct {

struct QRLoginStatus {
    enum class Kind {
        WaitingScan,
        ScannedWaitingConfirm,
        Success,
        Expired,
        Failed,
    };

    Kind kind = Kind::WaitingScan;
    QString cookie;
    QString reason;

    static QRLoginStatus waitingScan() { return {Kind::WaitingScan, {}, {}}; }
    static QRLoginStatus scannedWaitingConfirm() { return {Kind::ScannedWaitingConfirm, {}, {}}; }
    static QRLoginStatus success(QString cookie) { return {Kind::Success, std::move(cookie), {}}; }
    static QRLoginStatus expired() { return {Kind::Expired, {}, {}}; }
    static QRLoginStatus failed(QString reason) { return {Kind::Failed, {}, std::move(reason)}; }
};

struct AccountInfo {
    QString userID;
    QString nickname;
    std::optional<QString> avatarURL;
    bool isVIP = false;

    bool operator==(const AccountInfo&) const = default;
};

enum class SearchType {
    Song,
    Artist,
    Album,
    Playlist,
};

namespace searchType {
QString displayName(SearchType type);
QList<SearchType> all();
} // namespace searchType

struct SearchResult {
    QList<Song> songs;
    QList<Artist> artists;
    QList<Album> albums;
    QList<Playlist> playlists;
    int totalCount = 0;
    bool hasMore = false;

    bool isEmpty() const
    {
        return songs.isEmpty() && artists.isEmpty() && albums.isEmpty() && playlists.isEmpty();
    }
};

struct PlaylistDetail {
    Playlist playlist;
    QList<Song> tracks;
    int totalTrackCount = 0;
    std::optional<QString> artistID;
};

struct ArtistDetail {
    Artist artist;
    QList<Song> hotSongs;
    QList<Album> albums;
};

struct LyricResult {
    QList<LyricLine> lines;
    bool hasWordTiming = false;
    bool isPureMusic = false;
};

class IMusicProvider {
public:
    virtual ~IMusicProvider() = default;

    virtual QString identifier() const = 0;
    virtual QString displayName() const = 0;

    virtual Task<QString> fetchQRCodeKey(CancellationToken ct) = 0;
    virtual Task<QString> fetchQRCodeImage(const QString& key, CancellationToken ct) = 0;
    virtual Task<QRLoginStatus> checkQRCodeStatus(const QString& key, CancellationToken ct) = 0;
    virtual Task<void> logout(CancellationToken ct) = 0;
    virtual Task<std::optional<AccountInfo>> fetchAccountInfo(CancellationToken ct) = 0;

    virtual Task<SearchResult> search(
        const QString& query, SearchType type, int page, int limit, CancellationToken ct) = 0;
    virtual Task<PlaylistDetail> fetchPlaylistDetail(const QString& id, CancellationToken ct) = 0;
    virtual Task<QList<Song>> fetchPlaylistTracks(
        const QString& id, int page, int limit, CancellationToken ct) = 0;
    virtual Task<PlaylistDetail> fetchAlbumDetail(const QString& id, CancellationToken ct) = 0;
    virtual Task<ArtistDetail> fetchArtistDetail(const QString& id, CancellationToken ct) = 0;
    virtual Task<PlayableURL> fetchPlayableURL(
        const QString& songID, QualityLevel quality, CancellationToken ct) = 0;
    virtual Task<LyricResult> fetchLyrics(const QString& songID, CancellationToken ct) = 0;
    virtual Task<QList<Playlist>> fetchUserPlaylists(CancellationToken ct) = 0;
    virtual Task<QList<Song>> fetchLikedSongs(CancellationToken ct) = 0;
    virtual Task<void> likeSong(const QString& id, bool like, CancellationToken ct) = 0;
    virtual Task<QList<Playlist>> fetchRecommendPlaylists(CancellationToken ct) = 0;
    virtual Task<QList<Song>> fetchDailyRecommendSongs(CancellationToken ct) = 0;
    virtual Task<QStringList> fetchLikedSongIDs(CancellationToken ct) = 0;
};

} // namespace ct
