#pragma once

#include "Core/Async.h"
#include "Core/Models/ArtistProfileModels.h"
#include "Core/Models/MusicProvider.h"
#include "Core/Models/RadioModels.h"
#include "Core/Networking/HTTPClient.h"
#include "Core/Networking/SessionExpiryGuard.h"

#include <QByteArray>
#include <QDateTime>
#include <QHash>
#include <QJsonValue>
#include <QString>
#include <QStringList>
#include <QUrl>

#include <functional>
#include <memory>
#include <mutex>
#include <optional>

namespace ct {

class NeteaseProvider final : public IMusicProvider, public IArtistProfileProvider {
public:
    static NeteaseProvider& shared();

    NeteaseProvider();

    QString identifier() const override;
    QString displayName() const override;

    std::function<void()> sessionExpired;

    // MARK: - 凭据
    static std::optional<QString> loadLoginCookie();

    // MARK: - 认证
    Task<QString> fetchQRCodeKey(CancellationToken ct = CancellationToken::none()) override;
    Task<QString> fetchQRCodeImage(const QString& key,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QRLoginStatus> checkQRCodeStatus(const QString& key,
        CancellationToken ct = CancellationToken::none()) override;
    Task<void> logout(CancellationToken ct = CancellationToken::none()) override;
    void resetSessionGuard();
    Task<std::optional<AccountInfo>> fetchAccountInfo(
        CancellationToken ct = CancellationToken::none()) override;
    Task<std::optional<AccountInfo>> fetchAccountInfo(const QString& cookie,
        CancellationToken ct = CancellationToken::none());

    // MARK: - 搜索
    Task<SearchResult> search(const QString& query, SearchType type, int page, int limit,
        CancellationToken ct = CancellationToken::none()) override;

    // MARK: - 歌单 / 专辑 / 歌手
    Task<PlaylistDetail> fetchPlaylistDetail(const QString& id,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Song>> fetchPlaylistTracks(const QString& id, int page, int limit,
        CancellationToken ct = CancellationToken::none()) override;
    std::optional<QList<Song>> cachedPlaylistTracks(const QString& id);
    void streamPlaylistTracks(const QString& id, int totalCount, int pageSize, int maxConcurrent,
        CancellationToken ct, std::function<void(Result<QList<Song>>)> onPage,
        std::function<void(Result<Unit>)> onFinished);
    Task<PlaylistDetail> fetchAlbumDetail(const QString& id,
        CancellationToken ct = CancellationToken::none()) override;
    Task<ArtistDetail> fetchArtistDetail(const QString& id,
        CancellationToken ct = CancellationToken::none()) override;

    // MARK: - 播放地址
    Task<PlayableURL> fetchPlayableURL(const QString& songID, QualityLevel quality,
        CancellationToken ct = CancellationToken::none()) override;
    Task<bool> isStreamReachable(
        const QUrl& url, CancellationToken ct = CancellationToken::none());

    // MARK: - 歌词
    Task<LyricResult> fetchLyrics(const QString& songID,
        CancellationToken ct = CancellationToken::none()) override;

    // MARK: - 用户数据
    Task<QList<Playlist>> fetchUserPlaylists(
        CancellationToken ct = CancellationToken::none()) override;
    Task<QStringList> fetchLikedSongIDs(
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Song>> fetchLikedSongs(CancellationToken ct = CancellationToken::none()) override;
    Task<void> likeSong(const QString& id, bool like,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Playlist>> fetchRecommendPlaylists(
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Song>> fetchDailyRecommendSongs(
        CancellationToken ct = CancellationToken::none()) override;

    // MARK: - 电台
    Task<QList<RadioCategory>> fetchRadioCategories(
        CancellationToken ct = CancellationToken::none());
    Task<QList<RadioStation>> fetchRecommendedRadios(
        int limit = 30, CancellationToken ct = CancellationToken::none());
    Task<QList<RadioStation>> fetchHotRadios(const std::optional<QString>& categoryID = std::nullopt,
        int limit = 30, CancellationToken ct = CancellationToken::none());
    Task<QList<RadioProgram>> fetchRadioPrograms(const QString& radioID, int page = 1, int limit = 30,
        CancellationToken ct = CancellationToken::none());

    // MARK: - 歌手资料
    Task<ArtistProfile> fetchArtistProfile(const QString& id,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Song>> fetchHotArtistSongs(const QString& id,
        CancellationToken ct = CancellationToken::none()) override;
    Task<ArtistSongPage> fetchArtistSongs(const QString& id, int offset, int limit,
        const QString& order, CancellationToken ct = CancellationToken::none()) override;
    Task<ArtistAlbumPage> fetchArtistAlbums(const QString& id, int offset, int limit,
        CancellationToken ct = CancellationToken::none()) override;
    Task<ArtistMVPage> fetchArtistMVs(const QString& id, int offset, int limit,
        CancellationToken ct = CancellationToken::none()) override;
    Task<ArtistIntro> fetchArtistIntro(const QString& id,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Artist>> fetchSimilarArtists(const QString& artistID,
        CancellationToken ct = CancellationToken::none()) override;

    // MARK: - 网络请求基础
    Task<QByteArray> request(const QString& path, const QHash<QString, QString>& query = {},
        const std::optional<QString>& cookie = std::nullopt,
        std::optional<int> cacheTtlSeconds = std::nullopt,
        const QString& method = QStringLiteral("GET"), bool noteAuthRejection = true,
        CancellationToken ct = CancellationToken::none());

    static QJsonValue parseJson(const QByteArray& data);

    // MARK: - 缓存维护
    static QString cacheKey(const QString& path, const QHash<QString, QString>& query,
        const std::optional<QString>& cookie);
    static QString pathOfCacheKey(const QString& key);
    void invalidateCache(const QStringList& pathPrefixes);
    void invalidateCache(const QString& pathPrefix);
    void clearCache();

    // MARK: - 模型映射
    static QString likeFailureMessage(const QJsonValue& json);
    static std::optional<Song> mapSong(const QJsonValue& dict);
    static Artist mapArtist(const QJsonValue& dict);
    static Album mapAlbum(const QJsonValue& dict);
    static Playlist mapPlaylist(const QJsonValue& dict);
    static std::optional<RadioStation> mapRadioStation(const QJsonValue& dict);
    static std::optional<ArtistMV> mapArtistMV(const QJsonValue& dict);
    static std::optional<QString> codecName(const std::optional<QString>& encodeType,
        const std::optional<QUrl>& url);

private:
    struct CacheEntry {
        QByteArray data;
        QDateTime expiresAt;
    };
    struct PlaylistTrackEntry {
        QList<Song> songs;
        QDateTime cachedAt;
    };
    struct StreamPlaylistState;

    static QString requireUserID();
    Task<QByteArray> requestImpl(QString path, QHash<QString, QString> query,
        std::optional<QString> cookie, std::optional<int> cacheTtlSeconds, QString method,
        bool noteAuthRejection, CancellationToken ct);
    Task<std::optional<QUrl>> fetchMatchURL(
        const QString& songID, const std::optional<QString>& source, CancellationToken ct);
    static QUrl upgradeToHttps(const QUrl& url);
    static bool isAuthRejectionBody(const QByteArray& data);
    void noteSessionRejection();
    Task<void> confirmSessionWithProbe();
    std::optional<QByteArray> tryGetCachedResponse(const QString& key);
    void cacheResponse(const QByteArray& data, const QString& key, int ttlSeconds, int generation);
    void pruneExpiredCacheLocked();
    void enforceResponseCacheLimitsLocked();
    void storePlaylistTracks(const QList<Song>& songs, const QString& id);
    QList<RadioStation> parseRadioStations(const QByteArray& data);
    static std::optional<RadioProgram> mapRadioProgram(
        const QJsonValue& dict, const std::optional<QString>& stationName);
    static void startNextStreamPage(const std::shared_ptr<StreamPlaylistState>& state);
    static void pumpStream(const std::shared_ptr<StreamPlaylistState>& state);
    static Task<void> runStreamPage(std::shared_ptr<StreamPlaylistState> state, int page,
        Task<QList<Song>> inner);

    HTTPClient m_session;
    HTTPClient m_probeClient;

    std::mutex m_cacheGate;
    QHash<QString, CacheEntry> m_responseCache;
    qint64 m_responseCacheBytes = 0;
    int m_responseCacheGeneration = 0;

    std::mutex m_playlistGate;
    QHash<QString, PlaylistTrackEntry> m_playlistTrackCache;

    std::mutex m_reachGate;
    QHash<QString, QDateTime> m_reachCache;

    SessionExpiryGuard m_sessionGuard;
    std::mutex m_sessionGuardGate;
};

} // namespace ct
