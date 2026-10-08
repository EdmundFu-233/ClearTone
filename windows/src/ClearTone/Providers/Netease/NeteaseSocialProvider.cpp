#include "Providers/Netease/NeteaseSocialProvider.h"

#include "Core/Models/JsonHelpers.h"
#include "Core/Security/CredentialStore.h"
#include "Providers/Netease/NeteaseProvider.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

#include <algorithm>
#include <cmath>
#include <limits>

namespace ct {

namespace {

QJsonValue firstPresent(const QJsonValue& primary, const QJsonValue& fallback)
{
    return json::hasValue(primary) ? primary : fallback;
}

bool isNonEmptyObject(const QJsonValue& value)
{
    return value.isObject() && !value.toObject().isEmpty();
}

} // namespace

NeteaseSocialProvider& NeteaseSocialProvider::shared()
{
    static NeteaseSocialProvider instance;
    return instance;
}

// MARK: - 内部工具

void NeteaseSocialProvider::requireWriteSucceeded(const QJsonValue& json, const QString& action)
{
    const std::optional<int> code = json::optionalInt(json::prop(json, "code"));
    if (!code) throw MusicException::invalidResponse();
    if (*code != 200) {
        std::optional<QString> message = json::optionalString(json::prop(json, "msg"));
        if (!message) message = json::optionalString(json::prop(json, "message"));
        throw MusicException::apiError(
            *code, action + QStringLiteral("失败：") + message.value_or(QStringLiteral("未知错误")));
    }
}

QString NeteaseSocialProvider::requireLoginCookie()
{
    const std::optional<QString> cookie = NeteaseProvider::loadLoginCookie();
    if (!cookie || cookie->isEmpty()) throw MusicException::notLoggedIn();
    return *cookie;
}

QString NeteaseSocialProvider::requireUserID()
{
    const std::optional<QString> userID = CredentialStore::shared().load(CredentialKey::NeteaseUserID);
    if (!userID || userID->isEmpty()) throw MusicException::notLoggedIn();
    return *userID;
}

QJsonValue NeteaseSocialProvider::normalizeRadioStationJson(const QJsonValue& dict, bool markSubscribed)
{
    const bool hasPicString = json::optionalString(json::prop(dict, "pic")).has_value();
    const bool patchPic = !json::hasValue(json::prop(dict, "picUrl")) && hasPicString;
    if (!patchPic && !markSubscribed) return dict;

    QJsonObject map = dict.toObject();
    if (patchPic) {
        map.insert(QStringLiteral("picUrl"),
            json::optionalString(json::prop(dict, "pic")).value_or(QString()));
    }
    if (markSubscribed) map.insert(QStringLiteral("isSub"), 1);
    return map;
}

std::optional<QString> NeteaseSocialProvider::anyValue(const QJsonValue& value)
{
    if (value.isString()) {
        const QString text = value.toString();
        return text.isEmpty() ? std::nullopt : std::optional<QString>(text);
    }
    if (value.isDouble()) {
        const double number = value.toDouble();
        if (std::floor(number) == number && std::abs(number) < 9007199254740992.0) {
            return QString::number(static_cast<qint64>(number));
        }
        return QString::number(number, 'g', 17);
    }
    return std::nullopt;
}

std::optional<int> NeteaseSocialProvider::intValue(const QJsonValue& value)
{
    return json::optionalInt(value);
}

QDateTime NeteaseSocialProvider::dateFromMilliseconds(const QJsonValue& value)
{
    const std::optional<qint64> milliseconds = json::optionalLong(value);
    if (!milliseconds) return QDateTime::currentDateTimeUtc();
    if (*milliseconds > 100000000000LL) {
        return QDateTime::fromMSecsSinceEpoch(*milliseconds);
    }
    return QDateTime::fromSecsSinceEpoch(*milliseconds);
}

std::optional<QString> NeteaseSocialProvider::hotSearchIconLabel(int type)
{
    if (type == 1) return QStringLiteral("新");
    if (type == 2) return QStringLiteral("沸");
    return std::nullopt;
}

std::optional<QString> NeteaseSocialProvider::decodeNestedLastMessage(const std::optional<QString>& raw)
{
    if (!raw || raw->isEmpty()) return std::nullopt;
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(raw->toUtf8(), &error);
    if (error.error == QJsonParseError::NoError && document.isObject()) {
        const std::optional<QString> text =
            json::optionalString(json::prop(document.object(), "msg"));
        if (text && !text->isEmpty()) return text;
    }
    return raw;
}

int NeteaseSocialProvider::categoryGroupOrder(const QString& name)
{
    const QStringList order{QStringLiteral("语种"), QStringLiteral("风格"), QStringLiteral("场景"),
        QStringLiteral("情感"), QStringLiteral("主题")};
    const int index = static_cast<int>(order.indexOf(name));
    return index < 0 ? static_cast<int>(order.size()) : index;
}

// MARK: - 歌单写操作

Task<void> NeteaseSocialProvider::subscribePlaylist(
    const QString& id, bool subscribe, CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QJsonValue json = NeteaseProvider::parseJson(
        co_await NeteaseProvider::shared().request(QStringLiteral("/playlist/subscribe"),
            {{QStringLiteral("id"), id},
                {QStringLiteral("t"), subscribe ? QStringLiteral("1") : QStringLiteral("0")}},
            cookie, std::nullopt, QStringLiteral("POST"), true, ct));
    requireWriteSucceeded(json, subscribe ? QStringLiteral("收藏歌单") : QStringLiteral("取消收藏"));
    NeteaseProvider::shared().invalidateCache(QStringList{QStringLiteral("/playlist/detail"),
        QStringLiteral("/playlist/track/all"), QStringLiteral("/user/playlist")});
    co_return;
}

Task<Playlist> NeteaseSocialProvider::createPlaylist(
    const QString& name, bool isPrivate, CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty()) throw MusicException::invalidResponse();
    const QJsonValue json = NeteaseProvider::parseJson(
        co_await NeteaseProvider::shared().request(QStringLiteral("/playlist/create"),
            {{QStringLiteral("name"), trimmed},
                {QStringLiteral("privacy"), isPrivate ? QStringLiteral("10") : QStringLiteral("0")},
                {QStringLiteral("type"), QStringLiteral("NORMAL")}},
            cookie, std::nullopt, QStringLiteral("POST"), true, ct));
    requireWriteSucceeded(json, QStringLiteral("创建歌单"));
    const QJsonValue playlist = json::prop(json, "playlist");
    if (!json::hasValue(playlist)) throw MusicException::invalidResponse();
    NeteaseProvider::shared().invalidateCache(QStringLiteral("/user/playlist"));
    co_return NeteaseProvider::mapPlaylist(playlist);
}

Task<void> NeteaseSocialProvider::deletePlaylist(const QString& id, CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QStringList ids = id.split(QLatin1Char(','), Qt::SkipEmptyParts);
    if (ids.isEmpty()) throw MusicException::invalidResponse();
    for (const QString& part : ids) {
        for (const QChar character : part) {
            if (!character.isDigit()) throw MusicException::invalidResponse();
        }
    }
    const QJsonValue json = NeteaseProvider::parseJson(
        co_await NeteaseProvider::shared().request(QStringLiteral("/playlist/delete"),
            {{QStringLiteral("id"), ids.join(QLatin1Char(','))}}, cookie, std::nullopt,
            QStringLiteral("POST"), true, ct));
    requireWriteSucceeded(json, QStringLiteral("删除歌单"));
    NeteaseProvider::shared().invalidateCache(QStringList{
        QStringLiteral("/user/playlist"), QStringLiteral("/playlist/detail")});
    co_return;
}

Task<void> NeteaseSocialProvider::updatePlaylistName(
    const QString& id, const QString& name, CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QString trimmed = name.trimmed();
    if (trimmed.isEmpty()) throw MusicException::invalidResponse();
    const QJsonValue json = NeteaseProvider::parseJson(
        co_await NeteaseProvider::shared().request(QStringLiteral("/playlist/name/update"),
            {{QStringLiteral("id"), id}, {QStringLiteral("name"), trimmed}}, cookie, std::nullopt,
            QStringLiteral("POST"), true, ct));
    requireWriteSucceeded(json, QStringLiteral("重命名歌单"));
    NeteaseProvider::shared().invalidateCache(QStringList{
        QStringLiteral("/user/playlist"), QStringLiteral("/playlist/detail")});
    co_return;
}

Task<void> NeteaseSocialProvider::addSongsToPlaylist(
    const QString& playlistID, const QStringList& songIDs, CancellationToken ct)
{
    co_await manipulatePlaylistTracks(QStringLiteral("add"), playlistID, songIDs, ct);
}

Task<void> NeteaseSocialProvider::removeSongsFromPlaylist(
    const QString& playlistID, const QStringList& songIDs, CancellationToken ct)
{
    co_await manipulatePlaylistTracks(QStringLiteral("del"), playlistID, songIDs, ct);
}

Task<void> NeteaseSocialProvider::manipulatePlaylistTracks(
    const QString& op, const QString& playlistID, const QStringList& songIDs, CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    QStringList ids;
    for (const QString& songID : songIDs) {
        if (!songID.isEmpty()) ids.append(songID);
    }
    if (ids.isEmpty()) co_return;
    const QJsonValue json = NeteaseProvider::parseJson(
        co_await NeteaseProvider::shared().request(QStringLiteral("/playlist/tracks"),
            {{QStringLiteral("op"), op},
                {QStringLiteral("pid"), playlistID},
                {QStringLiteral("tracks"), ids.join(QLatin1Char(','))},
                {QStringLiteral("imme"), QStringLiteral("true")}},
            cookie, std::nullopt, QStringLiteral("POST"), true, ct));
    requireWriteSucceeded(
        json, op == QLatin1String("add") ? QStringLiteral("添加到歌单") : QStringLiteral("从歌单移除"));
    NeteaseProvider::shared().invalidateCache(QStringList{QStringLiteral("/playlist/detail"),
        QStringLiteral("/playlist/track/all"), QStringLiteral("/user/playlist")});
    co_return;
}

// MARK: - 收藏

Task<void> NeteaseSocialProvider::subscribeAlbum(
    const QString& id, bool subscribe, CancellationToken ct)
{
    co_await toggleSub(QStringLiteral("/album/sub"), id, subscribe, QStringLiteral("专辑"),
        QStringLiteral("id"), ct);
}

Task<void> NeteaseSocialProvider::subscribeArtist(
    const QString& id, bool subscribe, CancellationToken ct)
{
    co_await toggleSub(QStringLiteral("/artist/sub"), id, subscribe, QStringLiteral("歌手"),
        QStringLiteral("id"), ct);
}

Task<void> NeteaseSocialProvider::subscribeRadio(
    const QString& id, bool subscribe, CancellationToken ct)
{
    co_await toggleSub(QStringLiteral("/dj/sub"), id, subscribe, QStringLiteral("电台"),
        QStringLiteral("rid"), ct);
}

Task<void> NeteaseSocialProvider::toggleSub(const QString& route, const QString& id, bool subscribe,
    const QString& action, const QString& queryKey, CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QJsonValue json = NeteaseProvider::parseJson(
        co_await NeteaseProvider::shared().request(route,
            {{queryKey, id},
                {QStringLiteral("t"), subscribe ? QStringLiteral("1") : QStringLiteral("0")}},
            cookie, std::nullopt, QStringLiteral("POST"), true, ct));
    requireWriteSucceeded(json,
        (subscribe ? QStringLiteral("收藏") : QStringLiteral("取消收藏")) + action);
    NeteaseProvider::shared().invalidateCache(QStringList{QStringLiteral("/album"),
        QStringLiteral("/artist"), QStringLiteral("/dj"), QStringLiteral("/user/playlist")});
    co_return;
}

Task<QList<Playlist>> NeteaseSocialProvider::fetchSubscribedPlaylists(int limit, CancellationToken ct)
{
    const QString userID = requireUserID();
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/user/playlist"),
        {{QStringLiteral("uid"), userID},
            {QStringLiteral("limit"), QString::number(limit)},
            {QStringLiteral("offset"), QStringLiteral("0")}},
        cookie, 120, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue list = json::prop(json, "playlist");
    if (!list.isArray()) throw MusicException::invalidResponse();

    QList<Playlist> playlists;
    for (const QJsonValue& dict : list.toArray()) {
        Playlist playlist = NeteaseProvider::mapPlaylist(dict);
        playlist.isSubscribed = json::optionalInt(json::prop(dict, "subCount")).value_or(0) > 0;
        playlists.append(playlist);
    }
    co_return playlists;
}

Task<QList<Album>> NeteaseSocialProvider::fetchSubscribedAlbums(int limit, CancellationToken ct)
{
    const QString userID = requireUserID();
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/album/sublist"),
        {{QStringLiteral("uid"), userID}, {QStringLiteral("limit"), QString::number(limit)}},
        cookie, 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue albums = json::prop(json, "data");
    if (!albums.isArray()) throw MusicException::invalidResponse();

    QList<Album> result;
    for (const QJsonValue& element : albums.toArray()) result.append(NeteaseProvider::mapAlbum(element));
    co_return result;
}

Task<QList<Artist>> NeteaseSocialProvider::fetchSubscribedArtists(int limit, CancellationToken ct)
{
    const QString userID = requireUserID();
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/artist/sublist"),
        {{QStringLiteral("uid"), userID}, {QStringLiteral("limit"), QString::number(limit)}},
        cookie, 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue artists = json::prop(json, "data");
    if (!artists.isArray()) throw MusicException::invalidResponse();

    QList<Artist> result;
    for (const QJsonValue& element : artists.toArray()) result.append(NeteaseProvider::mapArtist(element));
    co_return result;
}

Task<RadioStation> NeteaseSocialProvider::fetchRadioStationDetail(
    const QString& radioID, CancellationToken ct)
{
    const std::optional<QString> cookie = NeteaseProvider::loadLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(QStringLiteral("/dj/detail"),
        {{QStringLiteral("rid"), radioID}}, cookie, 600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue dict = json::prop(json, "data");
    if (!json::hasValue(dict)) throw MusicException::invalidResponse();
    const std::optional<RadioStation> station =
        NeteaseProvider::mapRadioStation(normalizeRadioStationJson(dict, false));
    if (!station) throw MusicException::invalidResponse();
    co_return *station;
}

Task<QList<RadioStation>> NeteaseSocialProvider::fetchSubscribedRadios(int limit, CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(QStringLiteral("/dj/sublist"),
        {{QStringLiteral("limit"), QString::number(limit)}, {QStringLiteral("offset"), QStringLiteral("0")}},
        cookie, 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue radios = json::prop(json, "djRadios");
    if (!radios.isArray()) throw MusicException::invalidResponse();

    QList<RadioStation> result;
    for (const QJsonValue& raw : radios.toArray()) {
        if (const std::optional<RadioStation> station =
                NeteaseProvider::mapRadioStation(normalizeRadioStationJson(raw, true))) {
            result.append(*station);
        }
    }
    co_return result;
}

// MARK: - 榜单

Task<QList<TopList>> NeteaseSocialProvider::fetchTopLists(CancellationToken ct)
{
    const QByteArray data = co_await NeteaseProvider::shared().request(QStringLiteral("/toplist"),
        {}, std::nullopt, 3600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue list = json::prop(json, "list");
    if (!list.isArray()) throw MusicException::invalidResponse();

    QList<TopList> result;
    for (const QJsonValue& dict : list.toArray()) {
        const std::optional<QString> id = json::optionalIDString(json::prop(dict, "id"));
        if (!id) continue;
        TopList topList;
        topList.id = *id;
        topList.name = json::optionalString(json::prop(dict, "name")).value_or(QStringLiteral("未命名榜单"));
        topList.coverURL = json::optionalString(json::prop(dict, "coverImgUrl"));
        topList.updateFrequency = json::optionalString(json::prop(dict, "updateFrequency"));
        topList.trackCount = json::optionalInt(json::prop(dict, "trackCount")).value_or(0);
        topList.playCount = json::optionalInt(json::prop(dict, "playCount")).value_or(0);
        topList.descriptionText = json::optionalString(json::prop(dict, "description"));
        std::optional<QString> icon = json::optionalString(json::prop(dict, "icon"));
        if (!icon) icon = json::optionalString(json::prop(dict, "backgroundImageUrl"));
        topList.iconURL = icon;
        result.append(topList);
    }
    co_return result;
}

Task<QList<Song>> NeteaseSocialProvider::fetchTopSongs(TopSongArea area, CancellationToken ct)
{
    const QByteArray data = co_await NeteaseProvider::shared().request(QStringLiteral("/top/song"),
        {{QStringLiteral("type"), QString::number(topSongArea::areaID(area))},
            {QStringLiteral("total"), QStringLiteral("true")}},
        std::nullopt, 600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue songs = json::prop(json::prop(json, "data"), "songsData");
    if (!songs.isArray()) throw MusicException::invalidResponse();
    co_return json::compactMap<Song>(songs.toArray(),
        [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });
}

Task<QList<Playlist>> NeteaseSocialProvider::fetchHotPlaylists(const std::optional<QString>& category,
    TopPlaylistOrder order, int limit, int offset, CancellationToken ct)
{
    const QString cat = (!category || category->isEmpty()) ? QStringLiteral("全部") : *category;
    const QByteArray data = co_await NeteaseProvider::shared().request(QStringLiteral("/top/playlist"),
        {{QStringLiteral("order"), topPlaylistOrder::apiValue(order)},
            {QStringLiteral("limit"), QString::number(limit)},
            {QStringLiteral("offset"), QString::number(offset)},
            {QStringLiteral("total"), QStringLiteral("true")},
            {QStringLiteral("cat"), cat}},
        std::nullopt, 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue playlists = json::prop(json, "playlists");
    if (!playlists.isArray()) throw MusicException::invalidResponse();

    QList<Playlist> result;
    for (const QJsonValue& element : playlists.toArray()) {
        result.append(NeteaseProvider::mapPlaylist(element));
    }
    co_return result;
}

Task<QList<PlaylistCategoryGroup>> NeteaseSocialProvider::fetchPlaylistCategories(CancellationToken ct)
{
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/playlist/catlist"), {}, std::nullopt, 3600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue categories = json::prop(json, "categories");
    if (!categories.isObject()) throw MusicException::invalidResponse();

    QList<PlaylistCategoryGroup> groups;
    const QJsonObject object = categories.toObject();
    for (auto iterator = object.constBegin(); iterator != object.constEnd(); ++iterator) {
        if (!iterator.value().isArray()) continue;
        const QJsonArray raw = iterator.value().toArray();
        if (raw.isEmpty()) continue;
        QStringList values;
        bool valid = true;
        for (const QJsonValue& element : raw) {
            const std::optional<QString> text = json::optionalString(element);
            if (!text) {
                valid = false;
                break;
            }
            values.append(*text);
        }
        if (!valid) continue;
        PlaylistCategoryGroup group;
        group.name = iterator.key();
        group.categories = values;
        groups.append(group);
    }
    std::stable_sort(groups.begin(), groups.end(),
        [](const PlaylistCategoryGroup& left, const PlaylistCategoryGroup& right) {
            return categoryGroupOrder(left.name) < categoryGroupOrder(right.name);
        });
    co_return groups;
}

Task<QStringList> NeteaseSocialProvider::fetchHotPlaylistTags(CancellationToken ct)
{
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/playlist/hot"), {}, std::nullopt, 3600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue tags = json::prop(json, "tags");
    if (!tags.isArray()) throw MusicException::invalidResponse();
    QStringList result;
    for (const QJsonValue& element : tags.toArray()) {
        const std::optional<QString> name = json::optionalString(json::prop(element, "name"));
        if (name) result.append(*name);
    }
    co_return result;
}

// MARK: - 发现 / 推荐

Task<QList<Song>> NeteaseSocialProvider::fetchPersonalFM(CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/personal_fm"), {}, cookie, std::nullopt, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue songs = json::prop(json, "data");
    if (!songs.isArray()) throw MusicException::invalidResponse();
    co_return json::compactMap<Song>(songs.toArray(),
        [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });
}

Task<QList<Playlist>> NeteaseSocialProvider::fetchDailyRecommendPlaylists(CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/recommend/resource"), {}, cookie, 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue list = json::prop(json, "recommend");
    if (!list.isArray()) throw MusicException::invalidResponse();

    QList<Playlist> result;
    for (const QJsonValue& element : list.toArray()) {
        result.append(NeteaseProvider::mapPlaylist(element));
    }
    co_return result;
}

Task<QList<Song>> NeteaseSocialProvider::fetchNewSongs(int limit, CancellationToken ct)
{
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/personalized/newsong"),
        {{QStringLiteral("type"), QStringLiteral("recommend")},
            {QStringLiteral("limit"), QString::number(limit)},
            {QStringLiteral("areaId"), QStringLiteral("0")}},
        std::nullopt, 600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue list = json::prop(json, "result");
    if (!list.isArray()) throw MusicException::invalidResponse();
    co_return json::compactMap<Song>(list.toArray(),
        [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });
}

Task<QList<Album>> NeteaseSocialProvider::fetchNewAlbums(int limit, CancellationToken ct)
{
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/album/newest"), {}, std::nullopt, 600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue albums = json::prop(json, "albums");
    if (!albums.isArray()) throw MusicException::invalidResponse();

    QList<Album> result;
    const QJsonArray array = albums.toArray();
    const int take = qMin(qMax(1, limit), static_cast<int>(array.size()));
    for (int index = 0; index < take; ++index) {
        result.append(NeteaseProvider::mapAlbum(array.at(index)));
    }
    co_return result;
}

Task<QList<Song>> NeteaseSocialProvider::fetchSimilarSongs(
    const QString& songID, int limit, CancellationToken ct)
{
    const QByteArray data = co_await NeteaseProvider::shared().request(QStringLiteral("/simi/song"),
        {{QStringLiteral("id"), songID},
            {QStringLiteral("limit"), QString::number(limit)},
            {QStringLiteral("offset"), QStringLiteral("0")}},
        std::nullopt, 600, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue songs = json::prop(json, "songs");
    if (!songs.isArray()) throw MusicException::invalidResponse();
    co_return json::compactMap<Song>(songs.toArray(),
        [](const QJsonValue& element) { return NeteaseProvider::mapSong(element); });
}

Task<QList<Artist>> NeteaseSocialProvider::fetchSimilarArtists(
    const QString& artistID, CancellationToken ct)
{
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/simi/artist"), {{QStringLiteral("id"), artistID}}, std::nullopt, 600,
        QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    QJsonValue artists = json::prop(json, "artists");
    if (!artists.isArray()) artists = json::prop(json, "data");
    if (!artists.isArray()) throw MusicException::invalidResponse();

    QList<Artist> result;
    for (const QJsonValue& element : artists.toArray()) result.append(NeteaseProvider::mapArtist(element));
    co_return result;
}

Task<std::optional<Song>> NeteaseSocialProvider::dislikeDailyRecommend(
    const QString& songID, CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QJsonValue json = NeteaseProvider::parseJson(
        co_await NeteaseProvider::shared().request(QStringLiteral("/recommend/songs/dislike"),
            {{QStringLiteral("id"), songID}}, cookie, std::nullopt, QStringLiteral("POST"), true, ct));
    requireWriteSucceeded(json, QStringLiteral("反馈不喜欢"));
    NeteaseProvider::shared().invalidateCache(QStringLiteral("/recommend/songs"));
    const QJsonValue replacement = json::prop(json, "data");
    if (!json::hasValue(replacement)) co_return std::optional<Song>{};
    co_return NeteaseProvider::mapSong(replacement);
}

// MARK: - 搜索联想

std::optional<QString> NeteaseSocialProvider::suggestionSubtitle(
    const QJsonValue& dict, SearchSuggestion::Kind kind)
{
    QStringList names;
    for (const QJsonValue& element : json::array(json::prop(dict, "artists"))) {
        const std::optional<QString> name = json::optionalString(json::prop(element, "name"));
        if (name) names.append(*name);
    }

    switch (kind) {
    case SearchSuggestion::Kind::Song: {
        if (names.isEmpty()) return std::nullopt;
        const int total = static_cast<int>(
            json::optionalDouble(json::prop(dict, "duration")).value_or(0.0) / 1000.0);
        return names.join(QStringLiteral(" / ")) + QStringLiteral(" · ") + QString::number(total / 60)
            + QLatin1Char(':') + QString::number(total % 60).rightJustified(2, QLatin1Char('0'));
    }
    case SearchSuggestion::Kind::Artist: {
        const std::optional<int> size = json::optionalInt(json::prop(dict, "albumSize"));
        if (!size) return std::nullopt;
        return QStringLiteral("%1 张专辑").arg(*size);
    }
    case SearchSuggestion::Kind::Album:
        if (names.isEmpty()) return std::nullopt;
        return names.join(QStringLiteral(" / "));
    default: {
        const std::optional<int> count = json::optionalInt(json::prop(dict, "trackCount"));
        if (!count) return std::nullopt;
        return QStringLiteral("%1 首").arg(*count);
    }
    }
}

Task<QList<SearchSuggestion>> NeteaseSocialProvider::fetchSearchSuggestions(
    const QString& keyword, CancellationToken ct)
{
    const QString trimmed = keyword.trimmed();
    if (trimmed.isEmpty()) co_return QList<SearchSuggestion>{};

    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/search/suggest"), {{QStringLiteral("keywords"), trimmed}}, std::nullopt,
        std::nullopt, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue result = json::prop(json, "result");
    if (!json::hasValue(result)) co_return QList<SearchSuggestion>{};

    const QList<QPair<QString, SearchSuggestion::Kind>> sections{
        {QStringLiteral("songs"), SearchSuggestion::Kind::Song},
        {QStringLiteral("artists"), SearchSuggestion::Kind::Artist},
        {QStringLiteral("albums"), SearchSuggestion::Kind::Album},
        {QStringLiteral("playlists"), SearchSuggestion::Kind::Playlist},
    };

    QList<SearchSuggestion> output;
    for (const auto& section : sections) {
        const QJsonArray items = json::array(json::prop(result, section.first));
        int index = 0;
        for (const QJsonValue& item : items) {
            if (index >= 5) break;
            index += 1;
            const std::optional<QString> id = json::optionalIDString(json::prop(item, "id"));
            if (!id) continue;
            SearchSuggestion suggestion;
            suggestion.suggestionKind = section.second;
            suggestion.title = json::optionalString(json::prop(item, "name")).value_or(QString());
            suggestion.subtitle = suggestionSubtitle(item, section.second);
            suggestion.coverURL = json::optionalString(json::prop(item, "picUrl"));
            suggestion.targetID = *id;
            output.append(suggestion);
        }
    }
    co_return output;
}

Task<QList<HotSearchTerm>> NeteaseSocialProvider::fetchHotSearchTerms(CancellationToken ct)
{
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/search/hot"), {}, std::nullopt, 1800, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue result = json::prop(json, "result");
    const QJsonValue hots = json::prop(result, "hots");
    if (!json::hasValue(result) || !hots.isArray()) throw MusicException::invalidResponse();

    QList<HotSearchTerm> terms;
    for (const QJsonValue& item : hots.toArray()) {
        const QString keyword = json::optionalString(json::prop(item, "first")).value_or(QString());
        if (keyword.isEmpty()) continue;
        HotSearchTerm term;
        term.keyword = keyword;
        term.score = json::optionalInt(json::prop(item, "second")).value_or(0);
        term.displayPrefix = hotSearchIconLabel(json::optionalInt(json::prop(item, "iconType")).value_or(0));
        term.icon = std::nullopt;
        terms.append(term);
    }
    co_return terms;
}

// MARK: - 评论

QHash<QString, QString> NeteaseSocialProvider::commentQuery(
    const QString& songID, CommentSort sort, int page, int pageSize, const std::optional<QString>& cursor)
{
    QHash<QString, QString> query;
    query.insert(QStringLiteral("id"), songID);
    query.insert(QStringLiteral("type"), QStringLiteral("0"));
    query.insert(QStringLiteral("sortType"), QString::number(commentSort::apiValue(sort)));
    query.insert(QStringLiteral("pageNo"), QString::number(qMax(1, page)));
    query.insert(QStringLiteral("pageSize"), QString::number(qMax(1, pageSize)));
    if (sort == CommentSort::Newest && page > 1 && cursor) query.insert(QStringLiteral("cursor"), *cursor);
    return query;
}

CommentPage NeteaseSocialProvider::mapCommentPage(
    const QJsonValue& json, const std::optional<QString>& myID)
{
    const QJsonValue body = json::prop(json, "data");
    const QJsonValue commentsValue = json::prop(body, "comments");
    if (!json::hasValue(body) || !commentsValue.isArray()) throw MusicException::invalidResponse();
    const QJsonArray list = commentsValue.toArray();

    QList<Comment> comments;
    for (const QJsonValue& item : list) {
        QJsonValue id = json::prop(item, "commentId");
        if (!json::hasValue(id)) id = json::prop(item, "id");
        if (!json::hasValue(id)) continue;

        const QJsonValue user = json::prop(item, "user");
        const QString userID = json::optionalIDString(
            firstPresent(json::prop(user, "userId"), json::prop(item, "userId"))).value_or(QString());
        const QJsonArray repliedList = json::array(json::prop(item, "beReplied"));
        const QJsonValue replied =
            repliedList.isEmpty() ? QJsonValue(QJsonValue::Undefined) : repliedList.first();

        Comment comment;
        comment.id = json::optionalIDString(id).value_or(QString());
        comment.content = json::optionalString(json::prop(item, "content")).value_or(QString());
        comment.userID = userID;
        comment.nickname =
            json::optionalString(json::prop(user, "nickname")).value_or(QStringLiteral("匿名用户"));
        comment.avatarURL = json::optionalString(json::prop(user, "avatarUrl"));
        comment.time = dateFromMilliseconds(json::prop(item, "time"));
        comment.likedCount = json::optionalInt(json::prop(item, "likedCount")).value_or(0);
        comment.isLiked = json::optionalBool(json::prop(item, "liked")).value_or(false);
        comment.replyCount = json::optionalInt(json::prop(item, "replyCount")).value_or(0);
        comment.replyToNickname =
            json::optionalString(json::prop(json::prop(replied, "user"), "nickname"));
        comment.replyToContent = json::optionalString(json::prop(replied, "content"));
        comment.isMine = myID && userID == *myID;
        comments.append(comment);
    }

    CommentPage page;
    page.comments = comments;
    page.total = json::optionalInt(json::prop(body, "totalCount")).value_or(static_cast<int>(comments.size()));
    page.hasMore = json::optionalBool(json::prop(body, "hasMore")).value_or(false);
    if (!list.isEmpty()) page.nextCursor = json::optionalIDString(json::prop(list.last(), "time"));
    return page;
}

QHash<QString, QString> NeteaseSocialProvider::commentLikeQuery(
    const QString& songID, const QString& commentID, bool like)
{
    QHash<QString, QString> query;
    query.insert(QStringLiteral("id"), songID);
    query.insert(QStringLiteral("cid"), commentID);
    query.insert(QStringLiteral("type"), QStringLiteral("0"));
    query.insert(QStringLiteral("t"), like ? QStringLiteral("1") : QStringLiteral("0"));
    return query;
}

Task<CommentPage> NeteaseSocialProvider::fetchComments(const QString& songID, CommentSort sort,
    int page, int pageSize, const std::optional<QString>& cursor, CancellationToken ct)
{
    const std::optional<QString> cookie = NeteaseProvider::loadLoginCookie();
    std::optional<int> ttl;
    if (sort != CommentSort::Newest) ttl = 60;
    const QByteArray data = co_await NeteaseProvider::shared().request(QStringLiteral("/comment/new"),
        commentQuery(songID, sort, page, pageSize, cursor), cookie, ttl, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const std::optional<QString> myID = CredentialStore::shared().load(CredentialKey::NeteaseUserID);
    co_return mapCommentPage(json, myID);
}

Task<void> NeteaseSocialProvider::likeComment(
    const QString& songID, const QString& commentID, bool like, CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QJsonValue json = NeteaseProvider::parseJson(
        co_await NeteaseProvider::shared().request(QStringLiteral("/comment/like"),
            commentLikeQuery(songID, commentID, like), cookie, std::nullopt, QStringLiteral("POST"),
            true, ct));
    requireWriteSucceeded(json, like ? QStringLiteral("点赞评论") : QStringLiteral("取消点赞"));
    NeteaseProvider::shared().invalidateCache(
        QStringList{QStringLiteral("/comment/new"), QStringLiteral("/comment/music")});
    co_return;
}

// MARK: - 消息 / 动态

Task<QList<UserNotice>> NeteaseSocialProvider::fetchNotices(int limit, CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(QStringLiteral("/msg/notices"),
        {{QStringLiteral("limit"), QString::number(limit)}, {QStringLiteral("lasttime"), QStringLiteral("-1")}},
        cookie, 60, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue list = json::prop(json, "notices");
    if (!list.isArray()) throw MusicException::invalidResponse();

    QList<UserNotice> notices;
    for (const QJsonValue& item : list.toArray()) {
        const std::optional<QString> id = json::optionalIDString(json::prop(item, "id"));
        if (!id) continue;
        const QJsonValue user = json::prop(item, "user");
        UserNotice notice;
        notice.id = *id;
        notice.kind = UserNoticeKind::fromTypeCode(
            json::optionalInt(json::prop(item, "type")).value_or(0));
        notice.time = dateFromMilliseconds(json::prop(item, "time"));
        notice.actorNickname = json::optionalString(json::prop(user, "nickname"));
        notice.actorAvatarURL = json::optionalString(json::prop(user, "avatarUrl"));
        notice.content = json::optionalString(json::prop(item, "msg"));
        notice.replyCommentText = json::optionalString(json::prop(item, "replyCommentText"));
        notice.relatedID = json::optionalIDString(json::prop(item, "relatedId"));
        notices.append(notice);
    }
    co_return notices;
}

QJsonValue NeteaseSocialProvider::peerProfile(const QJsonValue& item, const std::optional<QString>& myID)
{
    const QJsonValue user = json::prop(item, "user");
    const QJsonValue from = json::prop(item, "fromUser");
    const QJsonValue to = json::prop(item, "toUser");

    QList<QJsonValue> pair;
    if (isNonEmptyObject(from)) pair.append(from);
    if (isNonEmptyObject(to)) pair.append(to);

    for (const QJsonValue& candidate : pair) {
        const std::optional<QString> candidateID = json::optionalIDString(json::prop(candidate, "id"));
        if (candidateID && (!myID || *candidateID != *myID)) return candidate;
    }

    const std::optional<QString> peerID = json::optionalIDString(
        firstPresent(json::prop(user, "id"), json::prop(user, "fromUserId")));
    if (peerID && myID && *peerID == *myID) return pair.isEmpty() ? user : pair.last();
    return pair.isEmpty() ? user : pair.first();
}

Task<QList<PrivateConversation>> NeteaseSocialProvider::fetchPrivateConversations(
    int limit, int offset, CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(QStringLiteral("/msg/private"),
        {{QStringLiteral("limit"), QString::number(limit)},
            {QStringLiteral("offset"), QString::number(offset)},
            {QStringLiteral("total"), QStringLiteral("true")}},
        cookie, 60, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);

    QJsonValue rawList = json::prop(json, "msgs");
    if (!rawList.isArray()) rawList = json::prop(json, "data");
    if (!rawList.isArray()) rawList = json::prop(json, "users");
    const QJsonArray list = rawList.isArray() ? rawList.toArray() : QJsonArray{};

    const std::optional<QString> myID = CredentialStore::shared().load(CredentialKey::NeteaseUserID);
    QList<PrivateConversation> conversations;
    for (const QJsonValue& item : list) {
        const QJsonValue user = json::prop(item, "user");
        const std::optional<QString> peerID = json::optionalIDString(
            firstPresent(json::prop(user, "id"), json::prop(user, "fromUserId")));
        if (!peerID) continue;

        const QJsonValue peer = peerProfile(item, myID);
        const QString peerIDString =
            json::optionalIDString(json::prop(peer, "id")).value_or(*peerID);

        PrivateConversation conversation;
        conversation.id = json::optionalIDString(
            firstPresent(json::prop(item, "lastMsgId"), json::prop(user, "id"))).value_or(*peerID);
        conversation.userID = peerIDString;
        conversation.nickname =
            json::optionalString(json::prop(peer, "nickname")).value_or(QStringLiteral("未知用户"));
        conversation.avatarURL = json::optionalString(json::prop(peer, "avatarUrl"));
        conversation.lastMessage =
            decodeNestedLastMessage(json::optionalString(json::prop(item, "lastMsg")));
        conversation.lastTime = dateFromMilliseconds(
            firstPresent(json::prop(item, "lastMsgTime"), json::prop(user, "lastMsgTime")));
        conversation.unreadCount = json::optionalInt(
            firstPresent(json::prop(item, "newMsgCount"), json::prop(user, "newMsgCount"))).value_or(0);
        conversations.append(conversation);
    }
    co_return conversations;
}

Task<QList<PrivateMessage>> NeteaseSocialProvider::fetchPrivateMessages(
    const QString& userID, int limit, CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/msg/private/history"),
        {{QStringLiteral("uid"), userID},
            {QStringLiteral("limit"), QString::number(limit)},
            {QStringLiteral("before"), QStringLiteral("0")},
            {QStringLiteral("total"), QStringLiteral("true")}},
        cookie, std::nullopt, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue list = json::prop(json, "msgs");
    if (!list.isArray()) throw MusicException::invalidResponse();

    const std::optional<QString> myID = CredentialStore::shared().load(CredentialKey::NeteaseUserID);
    QList<PrivateMessage> messages;
    for (const QJsonValue& item : list.toArray()) {
        const QJsonValue inner = json::prop(item, "msg");
        const QString text = json::optionalString(json::prop(inner, "content")).value_or(QString());
        if (text.isEmpty()) continue;
        const QJsonValue id = firstPresent(json::prop(inner, "id"), json::prop(item, "id"));
        if (!json::hasValue(id)) continue;
        const QString from = json::optionalIDString(
            firstPresent(json::prop(inner, "fromUserId"), json::prop(item, "fromUserId"))).value_or(QString());
        const QJsonValue sender = firstPresent(json::prop(item, "sender"), json::prop(item, "user"));

        PrivateMessage message;
        message.id = json::optionalIDString(id).value_or(QString());
        std::optional<int> msgType = json::optionalInt(json::prop(inner, "msgType"));
        if (!msgType) msgType = json::optionalInt(json::prop(item, "msgType"));
        message.kind = PrivateMessageKind::fromMsgType(msgType.value_or(1));
        message.content = text;
        message.time = dateFromMilliseconds(
            firstPresent(json::prop(inner, "time"), json::prop(item, "time")));
        message.isOutgoing = myID && !from.isEmpty() && *myID == from;
        message.senderNickname = json::optionalString(json::prop(sender, "nickname"));
        messages.append(message);
    }
    co_return messages;
}

Task<QList<MyComment>> NeteaseSocialProvider::fetchMyComments(int limit, CancellationToken ct)
{
    const QString userID = requireUserID();
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(QStringLiteral("/msg/comments"),
        {{QStringLiteral("uid"), userID},
            {QStringLiteral("limit"), QString::number(limit)},
            {QStringLiteral("before"), QStringLiteral("-1")}},
        cookie, 60, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue list = json::prop(json, "comments");
    if (!list.isArray()) throw MusicException::invalidResponse();

    QList<MyComment> comments;
    for (const QJsonValue& item : list.toArray()) {
        const QJsonArray repliedList = json::array(json::prop(item, "beReplied"));
        const QJsonValue replied =
            repliedList.isEmpty() ? QJsonValue(QJsonValue::Undefined) : repliedList.first();
        const std::optional<QString> commentID = anyValue(json::prop(item, "commentId"));
        if (!commentID) continue;

        const int resourceKindValue = intValue(json::prop(item, "type")).value_or(0);
        MyCommentResourceKind resourceKind = MyCommentResourceKind::Song;
        if (resourceKindValue >= 0 && resourceKindValue <= 7) {
            resourceKind = static_cast<MyCommentResourceKind>(resourceKindValue);
        }

        MyComment comment;
        comment.id = *commentID;
        comment.content = json::optionalString(json::prop(item, "content")).value_or(QString());
        comment.time = dateFromMilliseconds(json::prop(item, "time"));
        comment.likedCount = intValue(json::prop(item, "likedCount")).value_or(0);
        comment.resourceKind = resourceKind;
        comment.resourceID = anyValue(json::prop(item, "id"));
        comment.replyCount = intValue(json::prop(item, "replyCount")).value_or(0);
        comment.repliedNickname =
            json::optionalString(json::prop(json::prop(replied, "user"), "nickname"));
        comment.repliedContent = json::optionalString(json::prop(replied, "content"));
        comments.append(comment);
    }
    co_return comments;
}

// MARK: - 等级 / 记录 / 打卡

Task<UserLevelInfo> NeteaseSocialProvider::fetchUserLevel(CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/user/level"), {}, cookie, 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue dict = json::prop(json, "data");
    if (!json::hasValue(dict)) throw MusicException::invalidResponse();

    UserLevelInfo info;
    info.level = json::optionalInt(json::prop(dict, "level")).value_or(0);
    info.listenSongs = json::optionalInt(json::prop(dict, "listenSongs")).value_or(0);
    info.listenDays = json::optionalInt(json::prop(dict, "listenDays")).value_or(0);
    info.currentLoginDays = json::optionalInt(json::prop(dict, "currentLoginDays")).value_or(0);
    info.nextLevelNeedLoginDays =
        json::optionalInt(json::prop(dict, "nextLevelNeedLoginDays")).value_or(0);
    info.nextLevelNeedListenSongs =
        json::optionalInt(json::prop(dict, "nextLevelNeedListenSongs")).value_or(0);
    info.currentProgress = json::optionalInt(json::prop(dict, "currentProgress")).value_or(0);
    co_return info;
}

Task<QList<ListenRecord>> NeteaseSocialProvider::fetchListenRecords(bool weekly, CancellationToken ct)
{
    const QString userID = requireUserID();
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(QStringLiteral("/user/record"),
        {{QStringLiteral("uid"), userID},
            {QStringLiteral("type"), weekly ? QStringLiteral("1") : QStringLiteral("0")}},
        cookie, 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    const QJsonValue list = json::prop(json, weekly ? "weekData" : "allData");

    QList<ListenRecord> records;
    for (const QJsonValue& item : json::array(list)) {
        const QJsonValue songDict = json::prop(item, "song");
        if (!json::hasValue(songDict)) continue;
        const std::optional<Song> song = NeteaseProvider::mapSong(songDict);
        if (!song) continue;

        std::optional<int> playCount = json::optionalInt(json::prop(item, "score"));
        if (!playCount) playCount = json::optionalInt(json::prop(item, "count"));

        ListenRecord record;
        record.song = *song;
        record.playCount = playCount.value_or(0);
        record.lastPlayedAt = dateFromMilliseconds(json::prop(item, "playTime"));
        records.append(record);
    }

    std::stable_sort(records.begin(), records.end(),
        [](const ListenRecord& left, const ListenRecord& right) {
            const qint64 leftTime = left.lastPlayedAt ? left.lastPlayedAt->toMSecsSinceEpoch()
                                                      : std::numeric_limits<qint64>::min();
            const qint64 rightTime = right.lastPlayedAt ? right.lastPlayedAt->toMSecsSinceEpoch()
                                                        : std::numeric_limits<qint64>::min();
            return leftTime > rightTime;
        });
    co_return records;
}

Task<SignInResult> NeteaseSocialProvider::dailySignIn(CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QJsonValue json = NeteaseProvider::parseJson(
        co_await NeteaseProvider::shared().request(QStringLiteral("/daily_signin"),
            {{QStringLiteral("type"), QStringLiteral("0")}}, cookie, std::nullopt,
            QStringLiteral("POST"), true, ct));
    if (json::optionalInt(json::prop(json, "code")) == -2) {
        SignInResult result;
        result.kind = SignInResult::Kind::AlreadySigned;
        co_return result;
    }
    requireWriteSucceeded(json, QStringLiteral("打卡"));
    SignInResult result;
    result.kind = SignInResult::Kind::Success;
    result.point = json::optionalInt(json::prop(json, "point")).value_or(0);
    co_return result;
}

Task<QHash<QString, int>> NeteaseSocialProvider::fetchUserCounts(CancellationToken ct)
{
    const QString cookie = requireLoginCookie();
    const QByteArray data = co_await NeteaseProvider::shared().request(
        QStringLiteral("/user/subcount"), {}, cookie, 300, QStringLiteral("GET"), true, ct);
    const QJsonValue json = NeteaseProvider::parseJson(data);
    if (!json::hasValue(json::prop(json, "code"))) throw MusicException::invalidResponse();

    QHash<QString, int> counts;
    counts.insert(QStringLiteral("创建歌单"),
        intValue(json::prop(json, "createdPlaylistCount")).value_or(0));
    counts.insert(QStringLiteral("收藏歌单"),
        intValue(json::prop(json, "subPlaylistCount")).value_or(0));
    counts.insert(QStringLiteral("关注歌手"),
        intValue(json::prop(json, "artistCount")).value_or(0));
    counts.insert(QStringLiteral("收藏电台"),
        intValue(json::prop(json, "djRadioCount")).value_or(0));
    counts.insert(QStringLiteral("节目"), intValue(json::prop(json, "programCount")).value_or(0));
    counts.insert(QStringLiteral("MV"), intValue(json::prop(json, "mvCount")).value_or(0));
    co_return counts;
}

} // namespace ct
