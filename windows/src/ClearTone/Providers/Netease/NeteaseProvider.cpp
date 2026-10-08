#include "Providers/Netease/NeteaseProvider.h"

#include "Core/ClearToneConstants.h"
#include "Core/Logging/CTLog.h"
#include "Core/Models/JsonHelpers.h"
#include "Core/Networking/HelperProcessManager.h"
#include "Core/Security/CredentialStore.h"
#include "Core/Security/NeteaseCookieNormalizer.h"
#include "Providers/Netease/LRCParser.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QUuid>

#include <algorithm>
#include <cmath>
#include <map>

namespace ct {

namespace {

constexpr int responseCacheEntryLimit = 128;
constexpr qint64 responseCacheByteLimit = 32LL * 1024 * 1024;
constexpr int playlistTrackCacheTtlSeconds = 600;
constexpr int playlistTrackCacheLimit = 8;
constexpr int reachCacheTtlSeconds = 180;
constexpr int detailBatchSize = 500;
constexpr int requestTimeoutMs = 20000;
constexpr int probeTimeoutMs = 4000;

struct RequestJoinState {
    int remaining = 0;
    QList<std::optional<QByteArray>> values;
    QList<std::optional<MusicException>> errors;
    Callback<QList<QByteArray>> callback;
};

Task<void> collectJoinedResponse(
    std::shared_ptr<RequestJoinState> state, int index, Task<QByteArray> inner)
{
    try {
        state->values[index] = co_await inner;
    } catch (const MusicException& error) {
        state->errors[index] = error;
    } catch (const std::exception& error) {
        state->errors[index] = MusicException::unknown(QString::fromUtf8(error.what()));
    } catch (...) {
        state->errors[index] = MusicException::unknown(QStringLiteral("未知错误"));
    }
    state->remaining -= 1;
    if (state->remaining > 0) co_return;
    for (const std::optional<MusicException>& error : state->errors) {
        if (error) {
            state->callback(Result<QList<QByteArray>>::failure(*error));
            co_return;
        }
    }
    QList<QByteArray> output;
    for (std::optional<QByteArray>& value : state->values) output.append(std::move(*value));
    state->callback(Result<QList<QByteArray>>::success(std::move(output)));
    co_return;
}

Awaitable<QList<QByteArray>> whenAllRequests(QList<std::function<Task<QByteArray>()>> factories)
{
    return Awaitable<QList<QByteArray>>{
        [factories = std::move(factories)](Callback<QList<QByteArray>> callback) {
            if (factories.isEmpty()) {
                callback(Result<QList<QByteArray>>::success(QList<QByteArray>{}));
                return;
            }
            auto state = std::make_shared<RequestJoinState>();
            state->remaining = static_cast<int>(factories.size());
            state->values.resize(factories.size());
            state->errors.resize(factories.size());
            state->callback = std::move(callback);
            for (int index = 0; index < factories.size(); ++index) {
                detach(collectJoinedResponse(state, index, factories[index]()));
            }
        }};
}

} // namespace

struct NeteaseProvider::StreamPlaylistState {
    NeteaseProvider* provider = nullptr;
    QString id;
    int pageCount = 1;
    int pageSize = 100;
    int maxConcurrent = 4;
    int nextToStart = 1;
    int nextToYield = 1;
    int pending = 0;
    bool finished = false;
    QHash<int, QList<Song>> ready;
    QHash<int, MusicException> failures;
    QList<Song> assembled;
    CancellationToken ct;
    std::function<void(Result<QList<Song>>)> onPage;
    std::function<void(Result<Unit>)> onFinished;
};

NeteaseProvider& NeteaseProvider::shared()
{
    static NeteaseProvider instance;
    return instance;
}

NeteaseProvider::NeteaseProvider() = default;

QString NeteaseProvider::identifier() const
{
    return QStringLiteral("netease");
}

QString NeteaseProvider::displayName() const
{
    return QStringLiteral("网易云音乐");
}

// MARK: - 凭据

std::optional<QString> NeteaseProvider::loadLoginCookie()
{
    const std::optional<QString> raw = CredentialStore::shared().load(CredentialKey::NeteaseCookie);
    if (!raw) return std::nullopt;
    const QString normalized = NeteaseCookieNormalizer::normalize(*raw);
    if (normalized.isEmpty()) return std::nullopt;
    return normalized;
}

QString NeteaseProvider::requireUserID()
{
    const std::optional<QString> userID = CredentialStore::shared().load(CredentialKey::NeteaseUserID);
    if (!userID || userID->isEmpty()) throw MusicException::notLoggedIn();
    return *userID;
}

// MARK: - 认证

Task<QString> NeteaseProvider::fetchQRCodeKey(CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/login/qr/key"),
        {{QStringLiteral("randomCNIP"), QStringLiteral("true")}}, std::nullopt, std::nullopt,
        QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const std::optional<QString> key = json::optionalString(json::prop(json::prop(json, "data"), "unikey"));
    if (!key) throw MusicException::invalidResponse();
    co_return *key;
}

Task<QString> NeteaseProvider::fetchQRCodeImage(const QString& key, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/login/qr/create"),
        {{QStringLiteral("key"), key}, {QStringLiteral("qrimg"), QStringLiteral("true")}},
        std::nullopt, std::nullopt, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const std::optional<QString> qrimg = json::optionalString(json::prop(json::prop(json, "data"), "qrimg"));
    if (!qrimg) throw MusicException::invalidResponse();
    co_return *qrimg;
}

Task<QRLoginStatus> NeteaseProvider::checkQRCodeStatus(const QString& key, CancellationToken ct)
{
    const QString timestamp = QString::number(QDateTime::currentMSecsSinceEpoch());
    const QByteArray data = co_await request(QStringLiteral("/login/qr/check"),
        {{QStringLiteral("key"), key},
            {QStringLiteral("timestamp"), timestamp},
            {QStringLiteral("randomCNIP"), QStringLiteral("true")}},
        std::nullopt, std::nullopt, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const std::optional<int> code = json::optionalInt(json::prop(json, "code"));
    if (!code) throw MusicException::invalidResponse();

    switch (*code) {
    case 800:
        co_return QRLoginStatus::expired();
    case 801:
        co_return QRLoginStatus::waitingScan();
    case 802:
        co_return QRLoginStatus::scannedWaitingConfirm();
    case 803: {
        const std::optional<QString> cookie = json::optionalString(json::prop(json, "cookie"));
        if (!cookie) throw MusicException::invalidResponse();
        co_return QRLoginStatus::success(*cookie);
    }
    default:
        co_return QRLoginStatus::failed(
            json::optionalString(json::prop(json, "message")).value_or(QStringLiteral("未知错误")));
    }
}

Task<void> NeteaseProvider::logout(CancellationToken ct)
{
    try {
        const std::optional<QString> cookie = loadLoginCookie();
        co_await request(QStringLiteral("/logout"), {}, cookie, std::nullopt,
            QStringLiteral("POST"), true, ct);
    } catch (...) {
        CredentialStore::shared().remove(CredentialKey::NeteaseCookie);
        CredentialStore::shared().remove(CredentialKey::NeteaseUserID);
        resetSessionGuard();
        clearCache();
        throw;
    }
    CredentialStore::shared().remove(CredentialKey::NeteaseCookie);
    CredentialStore::shared().remove(CredentialKey::NeteaseUserID);
    resetSessionGuard();
    clearCache();
    co_return;
}

void NeteaseProvider::resetSessionGuard()
{
    std::lock_guard<std::mutex> lock(m_sessionGuardGate);
    m_sessionGuard.reset();
}

Task<std::optional<AccountInfo>> NeteaseProvider::fetchAccountInfo(CancellationToken ct)
{
    const std::optional<QString> cookie = loadLoginCookie();
    if (!cookie) co_return std::optional<AccountInfo>{};
    co_return co_await fetchAccountInfo(*cookie, ct);
}

Task<std::optional<AccountInfo>> NeteaseProvider::fetchAccountInfo(
    const QString& cookie, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/user/account"), {}, cookie,
        std::nullopt, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QJsonValue account = json::prop(json, "account");
    const QJsonValue profile = json::prop(json, "profile");
    if (!json::hasValue(account) || !json::hasValue(profile)) co_return std::optional<AccountInfo>{};

    AccountInfo info;
    info.userID = json::optionalIDString(json::prop(account, "id")).value_or(QString());
    info.nickname = json::optionalString(json::prop(profile, "nickname"))
                        .value_or(QStringLiteral("未知用户"));
    info.avatarURL = json::optionalString(json::prop(profile, "avatarUrl"));
    info.isVIP = json::optionalInt(json::prop(account, "vipType")).value_or(0) > 0;
    co_return std::optional<AccountInfo>(info);
}

// MARK: - 搜索

Task<SearchResult> NeteaseProvider::search(
    const QString& query, SearchType type, int page, int limit, CancellationToken ct)
{
    int typeCode = 1000;
    switch (type) {
    case SearchType::Song:
        typeCode = 1;
        break;
    case SearchType::Artist:
        typeCode = 100;
        break;
    case SearchType::Album:
        typeCode = 10;
        break;
    default:
        typeCode = 1000;
        break;
    }

    const QByteArray data = co_await request(QStringLiteral("/cloudsearch"),
        {{QStringLiteral("keywords"), query},
            {QStringLiteral("type"), QString::number(typeCode)},
            {QStringLiteral("limit"), QString::number(limit)},
            {QStringLiteral("offset"), QString::number((page - 1) * limit)}},
        std::nullopt, 120, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QJsonValue result = json::prop(json, "result");
    if (!json::hasValue(result)) throw MusicException::invalidResponse();

    SearchResult searchResult;
    switch (type) {
    case SearchType::Song:
        searchResult.songs = json::compactMap<Song>(json::array(json::prop(result, "songs")),
            [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });
        searchResult.totalCount = json::optionalInt(json::prop(result, "songCount")).value_or(0);
        break;
    case SearchType::Artist:
        for (const QJsonValue& element : json::array(json::prop(result, "artists"))) {
            searchResult.artists.append(mapArtist(element));
        }
        searchResult.totalCount = json::optionalInt(json::prop(result, "artistCount")).value_or(0);
        break;
    case SearchType::Album:
        for (const QJsonValue& element : json::array(json::prop(result, "albums"))) {
            searchResult.albums.append(mapAlbum(element));
        }
        searchResult.totalCount = json::optionalInt(json::prop(result, "albumCount")).value_or(0);
        break;
    default:
        for (const QJsonValue& element : json::array(json::prop(result, "playlists"))) {
            searchResult.playlists.append(mapPlaylist(element));
        }
        searchResult.totalCount = json::optionalInt(json::prop(result, "playlistCount")).value_or(0);
        break;
    }

    searchResult.hasMore = json::optionalBool(json::prop(result, "hasMore"))
                               .value_or(page * limit < searchResult.totalCount);
    co_return searchResult;
}

// MARK: - 歌单 / 专辑 / 歌手

Task<PlaylistDetail> NeteaseProvider::fetchPlaylistDetail(const QString& id, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/playlist/detail"),
        {{QStringLiteral("id"), id}}, loadLoginCookie(), 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QJsonValue playlistDict = json::prop(json, "playlist");
    if (!json::hasValue(playlistDict)) throw MusicException::invalidResponse();

    PlaylistDetail detail;
    detail.playlist = mapPlaylist(playlistDict);
    const int trackIds = static_cast<int>(json::array(json::prop(playlistDict, "trackIds")).size());
    detail.totalTrackCount = json::optionalInt(json::prop(playlistDict, "trackCount")).value_or(trackIds);
    detail.tracks = json::compactMap<Song>(json::array(json::prop(playlistDict, "tracks")),
        [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });
    co_return detail;
}

Task<QList<Song>> NeteaseProvider::fetchPlaylistTracks(
    const QString& id, int page, int limit, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/playlist/track/all"),
        {{QStringLiteral("id"), id},
            {QStringLiteral("limit"), QString::number(limit)},
            {QStringLiteral("offset"), QString::number((page - 1) * limit)}},
        loadLoginCookie(), 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QJsonValue songs = json::prop(json, "songs");
    if (!songs.isArray()) throw MusicException::invalidResponse();
    co_return json::compactMap<Song>(songs.toArray(),
        [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });
}

std::optional<QList<Song>> NeteaseProvider::cachedPlaylistTracks(const QString& id)
{
    std::lock_guard<std::mutex> lock(m_playlistGate);
    const auto iterator = m_playlistTrackCache.find(id);
    if (iterator == m_playlistTrackCache.end()) return std::nullopt;
    if (QDateTime::currentDateTimeUtc() >= iterator->cachedAt.addSecs(playlistTrackCacheTtlSeconds)) {
        m_playlistTrackCache.erase(iterator);
        return std::nullopt;
    }
    return iterator->songs;
}

void NeteaseProvider::storePlaylistTracks(const QList<Song>& songs, const QString& id)
{
    std::lock_guard<std::mutex> lock(m_playlistGate);
    m_playlistTrackCache.insert(id, PlaylistTrackEntry{songs, QDateTime::currentDateTimeUtc()});
    if (m_playlistTrackCache.size() <= playlistTrackCacheLimit) return;
    const int overflow = static_cast<int>(m_playlistTrackCache.size()) - playlistTrackCacheLimit;
    QList<QPair<QString, QDateTime>> ordered;
    ordered.reserve(m_playlistTrackCache.size());
    for (auto iterator = m_playlistTrackCache.constBegin(); iterator != m_playlistTrackCache.constEnd();
         ++iterator) {
        ordered.append({iterator.key(), iterator->cachedAt});
    }
    std::stable_sort(ordered.begin(), ordered.end(),
        [](const QPair<QString, QDateTime>& left, const QPair<QString, QDateTime>& right) {
            return left.second < right.second;
        });
    for (int index = 0; index < overflow; ++index) m_playlistTrackCache.remove(ordered[index].first);
}

void NeteaseProvider::startNextStreamPage(const std::shared_ptr<StreamPlaylistState>& state)
{
    if (state->finished) return;
    if (state->nextToStart > state->pageCount) return;
    const int page = state->nextToStart;
    state->nextToStart += 1;
    state->pending += 1;
    detach(runStreamPage(state, page,
        state->provider->fetchPlaylistTracks(state->id, page, state->pageSize, state->ct)));
}

void NeteaseProvider::pumpStream(const std::shared_ptr<StreamPlaylistState>& state)
{
    while (!state->finished) {
        const auto failure = state->failures.constFind(state->nextToYield);
        if (failure != state->failures.constEnd()) {
            state->finished = true;
            state->onFinished(voidFailure(failure.value()));
            return;
        }

        const auto ready = state->ready.find(state->nextToYield);
        if (ready == state->ready.end()) {
            if (state->nextToYield > state->pageCount) {
                if (state->pending == 0) {
                    state->finished = true;
                    state->provider->storePlaylistTracks(state->assembled, state->id);
                    state->onFinished(voidSuccess());
                }
                return;
            }
            if (state->ct.isCancellationRequested()) {
                state->finished = true;
                state->onFinished(voidFailure(MusicException::cancelled()));
                return;
            }
            if (state->pending == 0) startNextStreamPage(state);
            return;
        }

        const QList<Song> songs = ready.value();
        state->ready.erase(ready);
        state->assembled += songs;
        state->onPage(Result<QList<Song>>::success(songs));
        state->nextToYield += 1;
        if (state->nextToStart <= state->pageCount) startNextStreamPage(state);
    }
}

Task<void> NeteaseProvider::runStreamPage(
    std::shared_ptr<StreamPlaylistState> state, int page, Task<QList<Song>> inner)
{
    try {
        const QList<Song> songs = co_await inner;
        state->pending -= 1;
        if (state->finished) co_return;
        state->ready.insert(page, songs);
        pumpStream(state);
        co_return;
    } catch (const MusicException& error) {
        state->pending -= 1;
        if (state->finished) co_return;
        state->failures.insert(page, error);
        pumpStream(state);
        co_return;
    } catch (const std::exception& error) {
        state->pending -= 1;
        if (state->finished) co_return;
        state->failures.insert(page, MusicException::unknown(QString::fromUtf8(error.what())));
        pumpStream(state);
        co_return;
    } catch (...) {
        state->pending -= 1;
        if (state->finished) co_return;
        state->failures.insert(page, MusicException::unknown(QStringLiteral("未知错误")));
        pumpStream(state);
        co_return;
    }
}

void NeteaseProvider::streamPlaylistTracks(const QString& id, int totalCount, int pageSize,
    int maxConcurrent, CancellationToken ct, std::function<void(Result<QList<Song>>)> onPage,
    std::function<void(Result<Unit>)> onFinished)
{
    auto state = std::make_shared<StreamPlaylistState>();
    state->provider = this;
    state->id = id;
    state->pageCount = qMax(1,
        static_cast<int>(std::ceil(
            static_cast<double>(totalCount) / static_cast<double>(pageSize))));
    state->pageSize = pageSize;
    state->maxConcurrent = maxConcurrent;
    state->ct = ct;
    state->onPage = std::move(onPage);
    state->onFinished = std::move(onFinished);

    if (ct.isCancellationRequested()) {
        state->finished = true;
        state->onFinished(voidFailure(MusicException::cancelled()));
        return;
    }
    while (!state->finished && state->nextToStart <= state->pageCount
        && state->nextToStart <= state->maxConcurrent) {
        startNextStreamPage(state);
    }
    pumpStream(state);
}

Task<PlaylistDetail> NeteaseProvider::fetchAlbumDetail(const QString& id, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/album"),
        {{QStringLiteral("id"), id}}, std::nullopt, 600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QJsonValue albumDict = json::prop(json, "album");
    if (!json::hasValue(albumDict)) throw MusicException::invalidResponse();

    const Album album = mapAlbum(albumDict);
    const QList<Song> songs = json::compactMap<Song>(json::array(json::prop(json, "songs")),
        [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });

    const QJsonValue albumArtist = json::prop(albumDict, "artist");
    std::optional<QString> artistID;
    if (json::hasValue(albumArtist)) {
        const std::optional<QString> raw = json::optionalIDString(json::prop(albumArtist, "id"));
        if (raw && *raw != QLatin1String("0")) artistID = raw;
    }

    Playlist playlist;
    playlist.id = album.id;
    playlist.name = album.name;
    playlist.coverURL = album.coverURL;
    playlist.trackCount = static_cast<int>(songs.size());
    playlist.creatorName = json::optionalString(json::prop(albumArtist, "name"));
    playlist.source = SongSource::Netease;

    PlaylistDetail detail;
    detail.playlist = playlist;
    detail.tracks = songs;
    detail.totalTrackCount = static_cast<int>(songs.size());
    detail.artistID = artistID;
    co_return detail;
}

Task<ArtistDetail> NeteaseProvider::fetchArtistDetail(const QString& id, CancellationToken ct)
{
    const QList<QByteArray> responses = co_await whenAllRequests({
        [this, id, ct]() -> Task<QByteArray> {
            return request(QStringLiteral("/artist/detail"), {{QStringLiteral("id"), id}},
                std::nullopt, 600, QStringLiteral("GET"), true, ct);
        },
        [this, id, ct]() -> Task<QByteArray> {
            return request(QStringLiteral("/artist/top/song"), {{QStringLiteral("id"), id}},
                std::nullopt, 600, QStringLiteral("GET"), true, ct);
        },
        [this, id, ct]() -> Task<QByteArray> {
            return request(QStringLiteral("/artist/album"),
                {{QStringLiteral("id"), id}, {QStringLiteral("limit"), QStringLiteral("20")}},
                std::nullopt, 600, QStringLiteral("GET"), true, ct);
        },
    });

    const QJsonValue profileJson = parseJson(responses.at(0));
    const QJsonValue artistDict = json::prop(json::prop(profileJson, "data"), "artist");
    if (!json::hasValue(artistDict)) throw MusicException::invalidResponse();

    ArtistDetail detail;
    detail.artist = mapArtist(artistDict);
    const QJsonValue songsJson = parseJson(responses.at(1));
    detail.hotSongs = json::compactMap<Song>(json::array(json::prop(songsJson, "songs")),
        [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });
    const QJsonValue albumsJson = parseJson(responses.at(2));
    for (const QJsonValue& element : json::array(json::prop(albumsJson, "hotAlbums"))) {
        detail.albums.append(mapAlbum(element));
    }
    co_return detail;
}

// MARK: - 播放地址

Task<PlayableURL> NeteaseProvider::fetchPlayableURL(
    const QString& songID, QualityLevel quality, CancellationToken ct)
{
    const std::optional<QString> cookie = loadLoginCookie();
    const QString level = quality::apiValue(quality);

    std::optional<QUrl> standardUrl;
    std::optional<AudioQuality> standardQuality;
    bool standardIsPreview = false;
    std::optional<qint64> standardSizeBytes;

    try {
        const QByteArray data = co_await request(QStringLiteral("/song/url/v1"),
            {{QStringLiteral("id"), songID}, {QStringLiteral("level"), level}},
            cookie, 240, QStringLiteral("GET"), true, ct);
        const QJsonValue json = parseJson(data);
        const QJsonArray firstArray = json::array(json::prop(json, "data"));
        if (!firstArray.isEmpty()) {
            const QJsonValue song = firstArray.first();
            const std::optional<QString> urlString = json::optionalString(json::prop(song, "url"));
            if (urlString) {
                const QUrl raw(*urlString);
                if (raw.isValid() && !raw.scheme().isEmpty()) {
                    const QUrl primary = upgradeToHttps(raw);
                    const std::optional<int> br = json::optionalInt(json::prop(song, "br"));
                    const bool hasTrial = json::prop(song, "freeTrialInfo").isObject();
                    const bool isPreview = hasTrial || (br && (*br == 128012 || *br == 128018));

                    standardUrl = primary;
                    standardIsPreview = isPreview;
                    standardSizeBytes = json::optionalLong(json::prop(song, "size"));

                    std::optional<int> bitrate;
                    if (br && *br / 1000 > 0) bitrate = *br / 1000;

                    AudioQuality audio;
                    audio.level = quality::fromAPIValue(
                        json::optionalString(json::prop(song, "level")).value_or(QString()));
                    audio.bitrate = bitrate;
                    audio.sampleRate = json::optionalInt(json::prop(song, "sr"));
                    audio.isActual = true;
                    audio.codec = codecName(json::optionalString(json::prop(song, "encodeType")), primary);
                    standardQuality = audio;

                    if (!isPreview && co_await isStreamReachable(primary, ct)) {
                        PlayableURL playable;
                        playable.url = primary.toString(QUrl::FullyEncoded);
                        playable.quality = audio;
                        playable.sizeBytes = standardSizeBytes;
                        co_return playable;
                    }
                }
            }
        }
    } catch (const MusicException& error) {
        if (error.kind() == MusicErrorKind::Cancelled) throw;
    }

    if (ct.isCancellationRequested()) throw MusicException::cancelled();

    const QStringList sources{QStringLiteral("unm"), QStringLiteral("gdmusic")};
    for (const QString& source : sources) {
        try {
            const std::optional<QUrl> match = co_await fetchMatchURL(songID, source, ct);
            if (!match) continue;
            const QUrl upgraded = upgradeToHttps(*match);
            if (!co_await isStreamReachable(upgraded, ct)) continue;
            PlayableURL playable;
            playable.url = upgraded.toString(QUrl::FullyEncoded);
            playable.quality.level = QualityLevel::Unknown;
            playable.quality.isActual = true;
            co_return playable;
        } catch (const MusicException& error) {
            if (error.kind() == MusicErrorKind::Cancelled) throw;
        }
    }

    if (standardUrl) {
        PlayableURL playable;
        playable.url = standardUrl->toString(QUrl::FullyEncoded);
        if (standardQuality) {
            playable.quality = *standardQuality;
        } else {
            playable.quality.level = QualityLevel::Unknown;
            playable.quality.isActual = true;
        }
        playable.isPreview = standardIsPreview;
        playable.sizeBytes = standardSizeBytes;
        co_return playable;
    }
    throw MusicException::noPlayableURL();
}

Task<std::optional<QUrl>> NeteaseProvider::fetchMatchURL(
    const QString& songID, const std::optional<QString>& source, CancellationToken ct)
{
    QHash<QString, QString> query;
    query.insert(QStringLiteral("id"), songID);
    if (source && !source->isEmpty()) query.insert(QStringLiteral("source"), *source);
    const QByteArray data = co_await request(QStringLiteral("/song/url/match"), query,
        loadLoginCookie(), 240, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const std::optional<QString> urlString = json::optionalString(json::prop(json, "data"));
    if (!urlString) co_return std::optional<QUrl>{};
    const QUrl url(*urlString);
    if (!url.isValid() || url.scheme().isEmpty()) co_return std::optional<QUrl>{};
    co_return std::optional<QUrl>(url);
}

QUrl NeteaseProvider::upgradeToHttps(const QUrl& url)
{
    if (url.scheme().compare(QStringLiteral("http"), Qt::CaseInsensitive) != 0) return url;
    QUrl upgraded = url;
    upgraded.setScheme(QStringLiteral("https"));
    return upgraded;
}

Task<bool> NeteaseProvider::isStreamReachable(const QUrl& url, CancellationToken ct)
{
    const QString key = url.toString(QUrl::FullyEncoded);
    {
        std::lock_guard<std::mutex> lock(m_reachGate);
        const auto iterator = m_reachCache.constFind(key);
        if (iterator != m_reachCache.constEnd()
            && iterator.value().addSecs(reachCacheTtlSeconds) > QDateTime::currentDateTimeUtc()) {
            co_return true;
        }
    }

    try {
        const HTTPResponse response = co_await m_probeClient.get(url,
            {{QStringLiteral("Range"), QStringLiteral("bytes=0-0")}}, probeTimeoutMs, ct);
        const bool ok = response.statusCode >= 200 && response.statusCode <= 299;
        if (ok) {
            std::lock_guard<std::mutex> lock(m_reachGate);
            m_reachCache.insert(key, QDateTime::currentDateTimeUtc());
        }
        co_return ok;
    } catch (...) {
        co_return false;
    }
}

// MARK: - 歌词

Task<LyricResult> NeteaseProvider::fetchLyrics(const QString& songID, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/lyric/new"),
        {{QStringLiteral("id"), songID}}, loadLoginCookie(), 1800, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);

    const QString lrc = json::optionalString(json::prop(json::prop(json, "lrc"), "lyric"))
                            .value_or(QString());
    const std::optional<QString> tlyric =
        json::optionalString(json::prop(json::prop(json, "tlyric"), "lyric"));
    const std::optional<QString> romalrc =
        json::optionalString(json::prop(json::prop(json, "romalrc"), "lyric"));
    const std::optional<QString> yrc =
        json::optionalString(json::prop(json::prop(json, "yrc"), "lyric"));

    const bool isPureMusic = lrc.trimmed().isEmpty() && (!yrc || yrc->isEmpty());

    if (yrc && !yrc->isEmpty()) {
        LyricResult result;
        result.lines = LRCParser::parseYRC(*yrc, tlyric, romalrc);
        result.hasWordTiming = true;
        result.isPureMusic = false;
        co_return result;
    }

    LyricResult result;
    result.lines = LRCParser::parse(lrc, tlyric, romalrc);
    result.hasWordTiming = false;
    result.isPureMusic = isPureMusic;
    co_return result;
}

// MARK: - 用户数据

Task<QList<Playlist>> NeteaseProvider::fetchUserPlaylists(CancellationToken ct)
{
    const std::optional<QString> cookie = loadLoginCookie();
    if (!cookie) throw MusicException::notLoggedIn();
    const QString userID = requireUserID();
    const QByteArray data = co_await request(QStringLiteral("/user/playlist"),
        {{QStringLiteral("uid"), userID}, {QStringLiteral("limit"), QStringLiteral("1000")}},
        cookie, 120, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QJsonValue playlists = json::prop(json, "playlist");
    if (!playlists.isArray()) throw MusicException::invalidResponse();
    co_return json::compactMap<Playlist>(playlists.toArray(),
        [](const QJsonValue& element) { return std::optional<Playlist>(NeteaseProvider::mapPlaylist(element)); });
}

Task<QStringList> NeteaseProvider::fetchLikedSongIDs(CancellationToken ct)
{
    const std::optional<QString> cookie = loadLoginCookie();
    if (!cookie) throw MusicException::notLoggedIn();
    const QString userID = requireUserID();
    const QByteArray data = co_await request(QStringLiteral("/likelist"),
        {{QStringLiteral("uid"), userID}}, cookie, 60, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QJsonValue ids = json::prop(json, "ids");
    if (!ids.isArray()) throw MusicException::invalidResponse();
    QStringList result;
    for (const QJsonValue& element : ids.toArray()) {
        const QString id = json::optionalIDString(element).value_or(QString());
        if (!id.isEmpty()) result.append(id);
    }
    co_return result;
}

Task<QList<Song>> NeteaseProvider::fetchLikedSongs(CancellationToken ct)
{
    const QStringList idStrings = co_await fetchLikedSongIDs(ct);
    if (idStrings.isEmpty()) co_return QList<Song>{};
    const std::optional<QString> cookie = loadLoginCookie();

    QList<Song> result;
    for (int start = 0; start < idStrings.size(); start += detailBatchSize) {
        const int end = qMin(start + detailBatchSize, static_cast<int>(idStrings.size()));
        const QStringList batch = idStrings.mid(start, end - start);
        const QByteArray detailData = co_await request(QStringLiteral("/song/detail"),
            {{QStringLiteral("ids"), batch.join(QLatin1Char(','))}}, cookie, 300,
            QStringLiteral("GET"), true, ct);
        const QJsonValue detailJson = parseJson(detailData);
        const QJsonValue songs = json::prop(detailJson, "songs");
        if (!songs.isArray()) continue;
        result += json::compactMap<Song>(songs.toArray(),
            [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });
    }
    co_return result;
}

Task<void> NeteaseProvider::likeSong(const QString& id, bool like, CancellationToken ct)
{
    const QString cookie = loadLoginCookie().value_or(QString());
    if (cookie.isEmpty()) throw MusicException::notLoggedIn();
    const std::optional<QString> userID = CredentialStore::shared().load(CredentialKey::NeteaseUserID);
    if (!userID || userID->isEmpty()) throw MusicException::notLoggedIn();

    const QByteArray data = co_await request(QStringLiteral("/song/like"),
        {{QStringLiteral("id"), id},
            {QStringLiteral("uid"), *userID},
            {QStringLiteral("like"), like ? QStringLiteral("true") : QStringLiteral("false")}},
        cookie, std::nullopt, QStringLiteral("POST"), true, ct);
    const QJsonValue json = parseJson(data);
    const std::optional<int> code = json::optionalInt(json::prop(json, "code"));
    if (code != 200) throw MusicException::apiError(code.value_or(-1), likeFailureMessage(json));
    invalidateCache(QStringList{QStringLiteral("/likelist"), QStringLiteral("/song/detail"),
        QStringLiteral("/user/playlist"), QStringLiteral("/playlist/detail")});
    co_return;
}

Task<QList<Playlist>> NeteaseProvider::fetchRecommendPlaylists(CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/personalized"),
        {{QStringLiteral("limit"), QStringLiteral("20")}}, loadLoginCookie(), 600,
        QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QJsonValue result = json::prop(json, "result");
    if (!result.isArray()) throw MusicException::invalidResponse();
    co_return json::compactMap<Playlist>(result.toArray(),
        [](const QJsonValue& element) { return std::optional<Playlist>(NeteaseProvider::mapPlaylist(element)); });
}

Task<QList<Song>> NeteaseProvider::fetchDailyRecommendSongs(CancellationToken ct)
{
    const std::optional<QString> cookie = loadLoginCookie();
    if (!cookie) throw MusicException::notLoggedIn();
    const QByteArray data = co_await request(QStringLiteral("/recommend/songs"), {}, cookie, 300,
        QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QJsonValue dailySongs = json::prop(json::prop(json, "data"), "dailySongs");
    if (!dailySongs.isArray()) throw MusicException::invalidResponse();
    co_return json::compactMap<Song>(dailySongs.toArray(),
        [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });
}

// MARK: - 电台

Task<QList<RadioCategory>> NeteaseProvider::fetchRadioCategories(CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/dj/catelist"), {}, std::nullopt, 3600,
        QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QJsonValue categories = json::prop(json, "categories");
    if (!categories.isArray()) throw MusicException::invalidResponse();

    QList<RadioCategory> result;
    for (const QJsonValue& dict : categories.toArray()) {
        const std::optional<QString> name = json::optionalString(json::prop(dict, "name"));
        if (!name) continue;
        RadioCategory category;
        category.id = json::optionalIDString(json::prop(dict, "id")).value_or(QString());
        for (const QJsonValue& element : json::array(json::prop(dict, "sub"))) {
            const std::optional<QString> sub = json::optionalString(json::prop(element, "name"));
            if (sub) category.subCategories.append(*sub);
        }
        category.name = *name;
        result.append(category);
    }
    co_return result;
}

Task<QList<RadioStation>> NeteaseProvider::fetchRecommendedRadios(int limit, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/dj/recommend"),
        {{QStringLiteral("limit"), QString::number(limit)}}, std::nullopt, 600,
        QStringLiteral("GET"), true, ct);
    co_return parseRadioStations(data);
}

Task<QList<RadioStation>> NeteaseProvider::fetchHotRadios(
    const std::optional<QString>& categoryID, int limit, CancellationToken ct)
{
    QHash<QString, QString> query;
    query.insert(QStringLiteral("limit"), QString::number(limit));
    if (categoryID && !categoryID->isEmpty()) query.insert(QStringLiteral("cat"), *categoryID);
    const QByteArray data = co_await request(QStringLiteral("/dj/hot"), query, std::nullopt, 600,
        QStringLiteral("GET"), true, ct);
    co_return parseRadioStations(data);
}

QList<RadioStation> NeteaseProvider::parseRadioStations(const QByteArray& data)
{
    const QJsonValue json = parseJson(data);
    const QJsonValue radios = json::prop(json, "djRadios");
    if (!radios.isArray()) throw MusicException::invalidResponse();
    return json::compactMap<RadioStation>(radios.toArray(),
        [](const QJsonValue& element) { return NeteaseProvider::mapRadioStation(element); });
}

Task<QList<RadioProgram>> NeteaseProvider::fetchRadioPrograms(
    const QString& radioID, int page, int limit, CancellationToken ct)
{
    const int offset = (page - 1) * limit;
    const QByteArray data = co_await request(QStringLiteral("/dj/program"),
        {{QStringLiteral("rid"), radioID},
            {QStringLiteral("limit"), QString::number(limit)},
            {QStringLiteral("offset"), QString::number(offset)}},
        std::nullopt, 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QJsonValue programs = json::prop(json, "programs");
    if (!programs.isArray()) throw MusicException::invalidResponse();
    co_return json::compactMap<RadioProgram>(programs.toArray(),
        [](const QJsonValue& element) { return NeteaseProvider::mapRadioProgram(element, std::nullopt); });
}

// MARK: - 歌手资料

Task<ArtistProfile> NeteaseProvider::fetchArtistProfile(const QString& id, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/artist/detail"),
        {{QStringLiteral("id"), id}}, loadLoginCookie(), 600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QJsonValue payload = json::prop(json, "data");
    const QJsonValue artistDict = json::prop(payload, "artist");
    if (!json::hasValue(payload) || !json::hasValue(artistDict)) throw MusicException::invalidResponse();

    ArtistProfile profile;
    profile.artist = mapArtist(artistDict);
    const QString rawTags =
        json::optionalString(json::prop(artistDict, "identifyTag")).value_or(QString());
    for (const QString& tag : rawTags.split(QLatin1Char(','), Qt::SkipEmptyParts)) {
        const QString trimmed = tag.trimmed();
        if (!trimmed.isEmpty()) profile.identifyTags.append(trimmed);
    }
    profile.briefDescription = json::optionalString(json::prop(artistDict, "briefDesc"));
    profile.albumCount = json::optionalInt(json::prop(artistDict, "albumSize")).value_or(0);
    profile.songCount = json::optionalInt(json::prop(artistDict, "musicSize")).value_or(0);
    profile.mvCount = json::optionalInt(json::prop(artistDict, "mvSize")).value_or(0);
    profile.videoCount = json::optionalInt(json::prop(payload, "videoCount")).value_or(0);
    profile.isFollowed = json::optionalBool(json::prop(artistDict, "followed"));
    co_return profile;
}

Task<QList<Song>> NeteaseProvider::fetchHotArtistSongs(const QString& id, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/artist/top/song"),
        {{QStringLiteral("id"), id}}, std::nullopt, 600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    co_return json::compactMap<Song>(json::array(json::prop(json, "songs")),
        [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });
}

Task<ArtistSongPage> NeteaseProvider::fetchArtistSongs(
    const QString& id, int offset, int limit, const QString& order, CancellationToken ct)
{
    std::optional<int> ttl;
    if (order == QLatin1String("hot")) ttl = 300;
    const QByteArray data = co_await request(QStringLiteral("/artist/songs"),
        {{QStringLiteral("id"), id},
            {QStringLiteral("order"), order},
            {QStringLiteral("offset"), QString::number(offset)},
            {QStringLiteral("limit"), QString::number(limit)}},
        loadLoginCookie(), ttl, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    const QList<Song> songs = json::compactMap<Song>(json::array(json::prop(json, "songs")),
        [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });

    ArtistSongPage page;
    page.songs = songs;
    page.total = json::optionalInt(json::prop(json, "total"))
                     .value_or(offset + static_cast<int>(songs.size()));
    page.hasMore = json::optionalBool(json::prop(json, "more"))
                       .value_or(static_cast<int>(songs.size()) >= limit);
    co_return page;
}

Task<ArtistAlbumPage> NeteaseProvider::fetchArtistAlbums(
    const QString& id, int offset, int limit, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/artist/album"),
        {{QStringLiteral("id"), id},
            {QStringLiteral("offset"), QString::number(offset)},
            {QStringLiteral("limit"), QString::number(limit)},
            {QStringLiteral("total"), QStringLiteral("true")}},
        std::nullopt, 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);

    ArtistAlbumPage page;
    for (const QJsonValue& element : json::array(json::prop(json, "hotAlbums"))) {
        page.albums.append(mapAlbum(element));
    }
    page.isFollowed = json::optionalBool(json::prop(json::prop(json, "artist"), "followed"));
    page.hasMore = json::optionalBool(json::prop(json, "more"))
                       .value_or(static_cast<int>(page.albums.size()) >= limit);
    co_return page;
}

Task<ArtistMVPage> NeteaseProvider::fetchArtistMVs(
    const QString& id, int offset, int limit, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/artist/mv"),
        {{QStringLiteral("id"), id},
            {QStringLiteral("offset"), QString::number(offset)},
            {QStringLiteral("limit"), QString::number(limit)},
            {QStringLiteral("total"), QStringLiteral("true")}},
        std::nullopt, 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);

    ArtistMVPage page;
    page.mvs = json::compactMap<ArtistMV>(json::array(json::prop(json, "mvs")),
        [](const QJsonValue& element) { return NeteaseProvider::mapArtistMV(element); });
    page.hasMore = json::optionalBool(json::prop(json, "hasMore"))
                       .value_or(static_cast<int>(page.mvs.size()) >= limit);
    co_return page;
}

Task<ArtistIntro> NeteaseProvider::fetchArtistIntro(const QString& id, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/artist/desc"),
        {{QStringLiteral("id"), id}}, std::nullopt, 3600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);

    ArtistIntro intro;
    for (const QJsonValue& entry : json::array(json::prop(json, "introduction"))) {
        const QString body = json::optionalString(json::prop(entry, "txt"))
                                 .value_or(QString())
                                 .trimmed();
        if (body.isEmpty()) continue;
        ArtistIntroSection section;
        section.id = QUuid::createUuid().toString(QUuid::WithoutBraces);
        section.title = json::optionalString(json::prop(entry, "ti")).value_or(QString()).trimmed();
        section.body = body;
        intro.sections.append(section);
    }
    const QString brief = json::optionalString(json::prop(json, "briefDesc"))
                              .value_or(QString())
                              .trimmed();
    if (!brief.isEmpty()) intro.briefDescription = brief;
    co_return intro;
}

Task<QList<Artist>> NeteaseProvider::fetchSimilarArtists(
    const QString& artistID, CancellationToken ct)
{
    const QByteArray data = co_await request(QStringLiteral("/simi/artist"),
        {{QStringLiteral("id"), artistID}}, std::nullopt, 600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = parseJson(data);
    QJsonValue raw = json::prop(json, "artists");
    if (!raw.isArray()) raw = json::prop(json, "data");
    if (!raw.isArray()) throw MusicException::invalidResponse();
    QList<Artist> artists;
    for (const QJsonValue& element : raw.toArray()) artists.append(mapArtist(element));
    co_return artists;
}

// MARK: - 网络请求基础

Task<QByteArray> NeteaseProvider::request(const QString& path,
    const QHash<QString, QString>& query, const std::optional<QString>& cookie,
    std::optional<int> cacheTtlSeconds, const QString& method, bool noteAuthRejection,
    CancellationToken ct)
{
    return requestImpl(path, query, cookie, cacheTtlSeconds, method, noteAuthRejection, ct);
}

Task<QByteArray> NeteaseProvider::requestImpl(QString path,
    QHash<QString, QString> query, std::optional<QString> cookie,
    std::optional<int> cacheTtlSeconds, QString method, bool noteAuthRejection,
    CancellationToken ct)
{
    const QString cacheKeyValue = cacheKey(path, query, cookie);
    int generation = 0;
    {
        std::lock_guard<std::mutex> lock(m_cacheGate);
        generation = m_responseCacheGeneration;
    }

    const bool cacheable =
        method == QLatin1String("GET") && cacheTtlSeconds && *cacheTtlSeconds > 0;
    if (cacheable) {
        if (const std::optional<QByteArray> cached = tryGetCachedResponse(cacheKeyValue)) {
            co_return *cached;
        }
    }

    try {
        co_await HelperProcessManager::shared().startIfNeeded(ct);
        const Result<QUrl> urlResult = HelperProcessManager::shared().makeURL(path, query);
        if (urlResult.isFailure()) throw urlResult.error();
        const QUrl url = urlResult.value();

        QHash<QString, QString> headers = HelperProcessManager::shared().authHeaders();
        if (cookie && !cookie->isEmpty()) {
            headers.insert(QStringLiteral("X-CT-Cookie"), *cookie);
        }

        HTTPResponse response;
        if (method == QLatin1String("POST")) {
            response = co_await m_session.postForm(url, QByteArray(), headers, requestTimeoutMs, ct);
        } else {
            response = co_await m_session.get(url, headers, requestTimeoutMs, ct);
        }

        const int status = response.statusCode;
        const QByteArray data = response.body;

        if (status == 301 || status == 403) {
            if (noteAuthRejection) noteSessionRejection();
            throw MusicException::apiError(
                status, QStringLiteral("网易云拒绝了这次请求（可能被风控），稍后重试"));
        }
        if (status == 401) throw MusicException::helperAuthFailed();
        if (status == 429) throw MusicException::rateLimited();
        if (status < 200 || status > 299) {
            throw MusicException::apiError(status, QStringLiteral("HTTP %1").arg(status));
        }

        if (data.size() <= 64 * 1024 && isAuthRejectionBody(data)) {
            if (noteAuthRejection) noteSessionRejection();
            throw MusicException::apiError(301, QStringLiteral("该接口要求重新登录后才能访问"));
        }

        if (cacheable) cacheResponse(data, cacheKeyValue, *cacheTtlSeconds, generation);
        co_return data;
    } catch (const MusicException&) {
        throw;
    } catch (const std::exception& error) {
        throw MusicException::unknown(QString::fromUtf8(error.what()));
    } catch (...) {
        throw MusicException::unknown(QStringLiteral("未知错误"));
    }
}

bool NeteaseProvider::isAuthRejectionBody(const QByteArray& data)
{
    try {
        const QJsonValue json = parseJson(data);
        return json::optionalInt(json::prop(json, "code")) == 301;
    } catch (...) {
        return false;
    }
}

QJsonValue NeteaseProvider::parseJson(const QByteArray& data)
{
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(data, &error);
    if (error.error != QJsonParseError::NoError) throw MusicException::invalidResponse();
    if (document.isObject()) return document.object();
    if (document.isArray()) return document.array();
    if (document.isNull()) return QJsonValue(QJsonValue::Null);
    throw MusicException::invalidResponse();
}

// MARK: - 会话失效判定

void NeteaseProvider::noteSessionRejection()
{
    SessionGuardDecision decision = SessionGuardDecision::Ignore;
    {
        std::lock_guard<std::mutex> lock(m_sessionGuardGate);
        decision = m_sessionGuard.noteRejection();
    }
    if (decision == SessionGuardDecision::ProbeSession) {
        detach(confirmSessionWithProbe());
    }
}

Task<void> NeteaseProvider::confirmSessionWithProbe()
{
    bool alive = false;
    try {
        const std::optional<QString> cookie = loadLoginCookie();
        const QByteArray data = co_await request(QStringLiteral("/user/account"), {}, cookie,
            std::nullopt, QStringLiteral("GET"), false, CancellationToken::none());
        const QJsonValue json = parseJson(data);
        alive = json::hasValue(json::prop(json::prop(json, "account"), "id"));
    } catch (...) {
        alive = false;
    }

    SessionGuardDecision decision = SessionGuardDecision::Ignore;
    {
        std::lock_guard<std::mutex> lock(m_sessionGuardGate);
        decision = m_sessionGuard.resolveProbe(alive);
    }

    if (decision == SessionGuardDecision::SessionAlive) {
        CTLog::general().info(
            QStringLiteral("单接口返回 301/403，但 /user/account 探针正常 —— 判定为风控拒绝，保留登录态"));
    } else if (decision == SessionGuardDecision::SessionExpired) {
        CTLog::security().warn(QStringLiteral("/user/account 探针同样失败，判定会话确实失效"));
        clearCache();
        if (sessionExpired) sessionExpired();
    }
    co_return;
}

// MARK: - 缓存维护

QString NeteaseProvider::cacheKey(const QString& path, const QHash<QString, QString>& query,
    const std::optional<QString>& cookie)
{
    QStringList keys = query.keys();
    std::sort(keys.begin(), keys.end());
    QStringList pairs;
    pairs.reserve(keys.size());
    for (const QString& key : keys) {
        const QString value = query.value(key);
        pairs.append(QString::number(key.toUtf8().size()) + QLatin1Char(':') + key
            + QString::number(value.toUtf8().size()) + QLatin1Char(':') + value);
    }
    const QString queryPart = pairs.join(QLatin1Char('&'));

    QString scope;
    if (cookie && !cookie->isEmpty()) {
        scope = QString::fromLatin1(
            QCryptographicHash::hash(cookie->toUtf8(), QCryptographicHash::Sha256).toHex());
    } else {
        scope = QStringLiteral("anon");
    }
    return path + QLatin1Char('?') + queryPart + QLatin1Char('|') + scope;
}

std::optional<QByteArray> NeteaseProvider::tryGetCachedResponse(const QString& key)
{
    std::lock_guard<std::mutex> lock(m_cacheGate);
    const auto iterator = m_responseCache.constFind(key);
    if (iterator != m_responseCache.constEnd()
        && iterator->expiresAt > QDateTime::currentDateTimeUtc()) {
        return iterator->data;
    }
    return std::nullopt;
}

void NeteaseProvider::cacheResponse(
    const QByteArray& data, const QString& key, int ttlSeconds, int generation)
{
    if (ttlSeconds <= 0) return;
    std::lock_guard<std::mutex> lock(m_cacheGate);
    if (generation != m_responseCacheGeneration) return;
    const auto existing = m_responseCache.constFind(key);
    if (existing != m_responseCache.constEnd()) m_responseCacheBytes -= existing->data.size();
    m_responseCache.insert(
        key, CacheEntry{data, QDateTime::currentDateTimeUtc().addSecs(ttlSeconds)});
    m_responseCacheBytes += data.size();
    enforceResponseCacheLimitsLocked();
}

void NeteaseProvider::pruneExpiredCacheLocked()
{
    const QDateTime now = QDateTime::currentDateTimeUtc();
    QStringList expired;
    for (auto iterator = m_responseCache.constBegin(); iterator != m_responseCache.constEnd();
         ++iterator) {
        if (iterator->expiresAt <= now) expired.append(iterator.key());
    }
    for (const QString& key : expired) {
        const auto iterator = m_responseCache.find(key);
        if (iterator == m_responseCache.end()) continue;
        m_responseCacheBytes -= iterator->data.size();
        m_responseCache.erase(iterator);
    }
    if (m_responseCacheBytes < 0) m_responseCacheBytes = 0;
}

void NeteaseProvider::enforceResponseCacheLimitsLocked()
{
    pruneExpiredCacheLocked();
    if (m_responseCache.size() <= responseCacheEntryLimit
        && m_responseCacheBytes <= responseCacheByteLimit) {
        return;
    }
    QList<QPair<QString, QDateTime>> ordered;
    ordered.reserve(m_responseCache.size());
    for (auto iterator = m_responseCache.constBegin(); iterator != m_responseCache.constEnd();
         ++iterator) {
        ordered.append({iterator.key(), iterator->expiresAt});
    }
    std::stable_sort(ordered.begin(), ordered.end(),
        [](const QPair<QString, QDateTime>& left, const QPair<QString, QDateTime>& right) {
            return left.second < right.second;
        });
    for (const auto& pair : ordered) {
        if (m_responseCache.size() <= responseCacheEntryLimit
            && m_responseCacheBytes <= responseCacheByteLimit) {
            break;
        }
        const auto iterator = m_responseCache.find(pair.first);
        if (iterator == m_responseCache.end()) continue;
        m_responseCacheBytes -= iterator->data.size();
        m_responseCache.erase(iterator);
    }
}

void NeteaseProvider::invalidateCache(const QStringList& pathPrefixes)
{
    std::lock_guard<std::mutex> lock(m_cacheGate);
    m_responseCacheGeneration += 1;

    for (const QString& prefix : pathPrefixes) {
        if (prefix == QLatin1String("/playlist/track/all") || prefix == QLatin1String("/playlist/detail")) {
            std::lock_guard<std::mutex> playlistLock(m_playlistGate);
            m_playlistTrackCache.clear();
            break;
        }
    }

    for (const QString& prefix : pathPrefixes) {
        QStringList hits;
        for (auto iterator = m_responseCache.constBegin(); iterator != m_responseCache.constEnd();
             ++iterator) {
            const QString path = pathOfCacheKey(iterator.key());
            if (path == prefix || path.startsWith(prefix + QLatin1Char('/'))) hits.append(iterator.key());
        }
        for (const QString& key : hits) {
            const auto iterator = m_responseCache.find(key);
            if (iterator == m_responseCache.end()) continue;
            m_responseCacheBytes -= iterator->data.size();
            m_responseCache.erase(iterator);
        }
    }
    if (m_responseCacheBytes < 0) m_responseCacheBytes = 0;
}

void NeteaseProvider::invalidateCache(const QString& pathPrefix)
{
    invalidateCache(QStringList{pathPrefix});
}

QString NeteaseProvider::pathOfCacheKey(const QString& key)
{
    const qsizetype question = key.indexOf(QLatin1Char('?'));
    const qsizetype pipe = key.indexOf(QLatin1Char('|'));
    qsizetype cut = -1;
    if (question >= 0 && pipe >= 0) {
        cut = qMin(question, pipe);
    } else if (question >= 0) {
        cut = question;
    } else {
        cut = pipe;
    }
    return cut < 0 ? key : key.left(cut);
}

void NeteaseProvider::clearCache()
{
    {
        std::lock_guard<std::mutex> lock(m_cacheGate);
        m_responseCacheGeneration += 1;
        m_responseCache.clear();
        m_responseCacheBytes = 0;
    }
    {
        std::lock_guard<std::mutex> lock(m_reachGate);
        m_reachCache.clear();
    }
    {
        std::lock_guard<std::mutex> lock(m_playlistGate);
        m_playlistTrackCache.clear();
    }
}

// MARK: - 模型映射

QString NeteaseProvider::likeFailureMessage(const QJsonValue& json)
{
    const std::optional<int> code = json::optionalInt(json::prop(json, "code"));
    std::optional<QString> serverText = json::optionalString(json::prop(json, "message"));
    if (!serverText) serverText = json::optionalString(json::prop(json, "msg"));
    if (code && (*code == 405 || *code == 524)) {
        return serverText.value_or(QStringLiteral("被网易云限流"))
            + QStringLiteral("。这是账号级限流，连点只会让等待更久，请 %1 秒后再试一次")
                  .arg(ClearToneConstants::likeWriteCooldownSeconds);
    }
    return serverText.value_or(QStringLiteral("操作失败"));
}

std::optional<Song> NeteaseProvider::mapSong(const QJsonValue& dict)
{
    const std::optional<QString> id = json::optionalIDString(json::prop(dict, "id"));
    if (!id) return std::nullopt;

    Song song;
    song.id = *id;
    song.title = json::optionalString(json::prop(dict, "name")).value_or(QStringLiteral("未知歌曲"));

    QJsonValue artistsValue = json::prop(dict, "ar");
    if (!artistsValue.isArray()) artistsValue = json::prop(dict, "artists");
    for (const QJsonValue& element : json::array(artistsValue)) song.artists.append(mapArtist(element));

    const QJsonValue al = json::prop(dict, "al");
    const QJsonValue albumValue = json::prop(dict, "album");
    if (json::hasValue(al)) {
        song.album = mapAlbum(al);
    } else if (json::hasValue(albumValue)) {
        song.album = mapAlbum(albumValue);
    }

    const std::optional<double> dt = json::optionalDouble(json::prop(dict, "dt"));
    const std::optional<double> duration = json::optionalDouble(json::prop(dict, "duration"));
    song.duration = (dt ? *dt : duration.value_or(0.0)) / 1000.0;

    std::optional<QString> cover = json::optionalString(json::prop(json::prop(dict, "al"), "picUrl"));
    if (!cover) cover = json::optionalString(json::prop(json::prop(dict, "album"), "picUrl"));
    if (!cover) cover = json::optionalString(json::prop(dict, "picUrl"));
    song.coverURL = cover;

    const int st = json::optionalInt(json::prop(dict, "st")).value_or(0);
    const bool isPlayable = st >= 0;
    song.isPlayable = isPlayable;
    song.unavailableReason =
        isPlayable ? std::nullopt : std::optional<QString>(QStringLiteral("歌曲已下架"));
    song.source = SongSource::Netease;
    return song;
}

Artist NeteaseProvider::mapArtist(const QJsonValue& dict)
{
    Artist artist;
    artist.id = json::optionalIDString(json::prop(dict, "id")).value_or(QStringLiteral("0"));
    artist.name = json::optionalString(json::prop(dict, "name")).value_or(QStringLiteral("未知歌手"));

    std::optional<QString> avatar = json::optionalString(json::prop(dict, "picUrl"));
    if (!avatar) avatar = json::optionalString(json::prop(dict, "img1v1Url"));
    if (!avatar) avatar = json::optionalString(json::prop(dict, "cover"));
    if (!avatar) avatar = json::optionalString(json::prop(dict, "avatar"));
    artist.avatarURL = avatar;

    QJsonValue aliasValue = json::prop(dict, "alias");
    if (!aliasValue.isArray()) aliasValue = json::prop(dict, "transNames");
    for (const QJsonValue& element : json::array(aliasValue)) artist.alias.append(element.toString());
    return artist;
}

Album NeteaseProvider::mapAlbum(const QJsonValue& dict)
{
    Album album;
    album.id = json::optionalIDString(json::prop(dict, "id")).value_or(QStringLiteral("0"));
    album.name = json::optionalString(json::prop(dict, "name")).value_or(QStringLiteral("未知专辑"));
    album.coverURL = json::optionalString(json::prop(dict, "picUrl"));
    return album;
}

Playlist NeteaseProvider::mapPlaylist(const QJsonValue& dict)
{
    Playlist playlist;
    playlist.id = json::optionalIDString(json::prop(dict, "id")).value_or(QStringLiteral("0"));
    playlist.name = json::optionalString(json::prop(dict, "name")).value_or(QStringLiteral("未知歌单"));
    std::optional<QString> cover = json::optionalString(json::prop(dict, "coverImgUrl"));
    if (!cover) cover = json::optionalString(json::prop(dict, "picUrl"));
    playlist.coverURL = cover;
    playlist.trackCount = json::optionalInt(json::prop(dict, "trackCount")).value_or(0);
    playlist.creatorName = json::optionalString(json::prop(json::prop(dict, "creator"), "nickname"));
    playlist.descriptionText = json::optionalString(json::prop(dict, "description"));
    playlist.isSubscribed = json::optionalBool(json::prop(dict, "subscribed")).value_or(false);
    playlist.source = SongSource::Netease;
    return playlist;
}

std::optional<RadioStation> NeteaseProvider::mapRadioStation(const QJsonValue& dict)
{
    const std::optional<QString> id = json::optionalIDString(json::prop(dict, "id"));
    if (!id) return std::nullopt;
    const QJsonValue dj = json::prop(dict, "dj");
    const QJsonValue isSub = json::prop(dict, "isSub");

    RadioStation station;
    station.id = *id;
    station.name = json::optionalString(json::prop(dict, "name")).value_or(QStringLiteral("未命名电台"));
    station.coverURL = json::optionalString(json::prop(dict, "picUrl"));
    station.programCount = json::optionalInt(json::prop(dict, "programCount")).value_or(0);
    station.subscriberCount = json::optionalInt(json::prop(dict, "subCount")).value_or(0);
    station.creatorName = json::optionalString(json::prop(dj, "nickname"));
    station.categoryName = json::optionalString(json::prop(dict, "categoryName"));
    if (!station.categoryName) {
        station.categoryName = json::optionalString(json::prop(dict, "category"));
    }
    station.descriptionText = json::optionalString(json::prop(dict, "desc"));
    station.isSubscribed = json::optionalInt(isSub) == 1 || json::optionalBool(isSub) == true;
    return station;
}

std::optional<RadioProgram> NeteaseProvider::mapRadioProgram(
    const QJsonValue& dict, const std::optional<QString>& stationName)
{
    const std::optional<QString> id = json::optionalIDString(json::prop(dict, "id"));
    if (!id) return std::nullopt;

    const QJsonValue mainSong = json::prop(dict, "mainSong");
    std::optional<Song> song;
    if (json::hasValue(mainSong)) song = mapSong(mainSong);

    std::optional<qint64> durationMs = json::optionalLong(json::prop(dict, "duration"));
    if (!durationMs && json::hasValue(mainSong)) {
        durationMs = json::optionalLong(json::prop(mainSong, "duration"));
    }

    RadioProgram program;
    program.id = *id;
    program.title = json::optionalString(json::prop(dict, "name"))
                        .value_or(song ? song->title : QStringLiteral("未命名节目"));
    std::optional<QString> cover = json::optionalString(json::prop(dict, "coverImgUrl"));
    if (!cover && song) cover = song->coverURL;
    program.coverURL = cover;
    program.duration = static_cast<double>(durationMs.value_or(0)) / 1000.0;
    const std::optional<qint64> createTime = json::optionalLong(json::prop(dict, "createTime"));
    if (createTime) program.createTime = QDateTime::fromMSecsSinceEpoch(*createTime);
    program.playCount = json::optionalInt(json::prop(dict, "playCount")).value_or(0);
    program.stationName = stationName;
    program.song = song;
    return program;
}

std::optional<ArtistMV> NeteaseProvider::mapArtistMV(const QJsonValue& dict)
{
    const std::optional<QString> id = json::optionalIDString(json::prop(dict, "id"));
    if (!id) return std::nullopt;

    ArtistMV mv;
    mv.id = *id;
    mv.name = json::optionalString(json::prop(dict, "name")).value_or(QStringLiteral("未命名 MV"));
    mv.artistName = json::optionalString(json::prop(dict, "artistName"));
    std::optional<QString> cover = json::optionalString(json::prop(dict, "imgurl16v9"));
    if (!cover) cover = json::optionalString(json::prop(dict, "imgurl"));
    mv.coverURL = cover;
    mv.duration = static_cast<double>(json::optionalLong(json::prop(dict, "duration")).value_or(0)) / 1000.0;
    mv.playCount = static_cast<int>(json::optionalLong(json::prop(dict, "playCount")).value_or(0));
    const std::optional<qint64> publishTime = json::optionalLong(json::prop(dict, "publishTime"));
    if (publishTime) mv.publishDate = QDateTime::fromMSecsSinceEpoch(*publishTime);
    return mv;
}

std::optional<QString> NeteaseProvider::codecName(
    const std::optional<QString>& encodeType, const std::optional<QUrl>& url)
{
    std::optional<QString> token;
    if (encodeType && !encodeType->trimmed().isEmpty()) token = encodeType->trimmed();
    if (!token && url) {
        const QString suffix = QFileInfo(url->path()).suffix();
        if (!suffix.isEmpty()) token = suffix;
    }
    if (!token || token->isEmpty()) return std::nullopt;

    const QString lowered = token->toLower();
    if (lowered == QLatin1String("mp3")) return QStringLiteral("MP3");
    if (lowered == QLatin1String("aac") || lowered == QLatin1String("m4a")
        || lowered == QLatin1String("m4b")) {
        return QStringLiteral("AAC");
    }
    if (lowered == QLatin1String("flac")) return QStringLiteral("FLAC");
    if (lowered == QLatin1String("alac")) return QStringLiteral("ALAC");
    if (lowered == QLatin1String("opus")) return QStringLiteral("OPUS");
    if (lowered == QLatin1String("wav") || lowered == QLatin1String("wave")) {
        return QStringLiteral("WAV");
    }
    return token->toUpper();
}

} // namespace ct
