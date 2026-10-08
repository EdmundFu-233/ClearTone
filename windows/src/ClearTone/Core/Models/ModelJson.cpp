#include "Core/Models/ModelJson.h"

#include "Core/Models/JsonHelpers.h"

namespace ct {

namespace {

QJsonArray artistsToJson(const QList<Artist>& artists)
{
    QJsonArray array;
    for (const Artist& artist : artists) array.append(toJson(artist));
    return array;
}

QJsonArray aliasesToJson(const QStringList& aliases)
{
    QJsonArray array;
    for (const QString& alias : aliases) array.append(alias);
    return array;
}

} // namespace

QString qualityLevelToJson(QualityLevel level)
{
    switch (level) {
    case QualityLevel::Standard:
        return QStringLiteral("standard");
    case QualityLevel::Higher:
        return QStringLiteral("higher");
    case QualityLevel::ExHigh:
        return QStringLiteral("exHigh");
    case QualityLevel::Lossless:
        return QStringLiteral("lossless");
    case QualityLevel::HiRes:
        return QStringLiteral("hiRes");
    case QualityLevel::Unknown:
        return QStringLiteral("unknown");
    }
    return QStringLiteral("unknown");
}

QualityLevel qualityLevelFromJson(const QJsonValue& value, QualityLevel fallback)
{
    // 兼容 old 数据：中文持久化名（"无损" 等）也会出现在设置里。
    const QString raw = value.toString();
    if (raw.isEmpty()) return fallback;
    if (raw == QLatin1String("standard")) return QualityLevel::Standard;
    if (raw == QLatin1String("higher")) return QualityLevel::Higher;
    if (raw == QLatin1String("exHigh")) return QualityLevel::ExHigh;
    if (raw == QLatin1String("lossless")) return QualityLevel::Lossless;
    if (raw == QLatin1String("hiRes")) return QualityLevel::HiRes;
    if (raw == QLatin1String("unknown")) return QualityLevel::Unknown;
    if (auto persisted = quality::fromPersistedName(raw)) return *persisted;
    return fallback;
}

QString songSourceToJson(SongSource source)
{
    return source == SongSource::Local ? QStringLiteral("local") : QStringLiteral("netease");
}

SongSource songSourceFromJson(const QJsonValue& value)
{
    if (value.isDouble()) return static_cast<int>(value.toDouble()) == 1 ? SongSource::Local : SongSource::Netease;
    return value.toString() == QLatin1String("local") ? SongSource::Local : SongSource::Netease;
}

QJsonObject toJson(const Album& album)
{
    QJsonObject object;
    object[QStringLiteral("id")] = album.id;
    object[QStringLiteral("name")] = album.name;
    if (album.coverURL) object[QStringLiteral("coverURL")] = *album.coverURL;
    return object;
}

std::optional<Album> albumFromJson(const QJsonValue& value)
{
    if (!value.isObject()) return std::nullopt;
    Album album;
    album.id = json::optionalIDString(value.toObject().value(QStringLiteral("id"))).value_or(QString());
    album.name = json::string(value.toObject().value(QStringLiteral("name")));
    album.coverURL = json::optionalString(value.toObject().value(QStringLiteral("coverURL")));
    return album;
}

QJsonObject toJson(const Artist& artist)
{
    QJsonObject object;
    object[QStringLiteral("id")] = artist.id;
    object[QStringLiteral("name")] = artist.name;
    if (artist.avatarURL) object[QStringLiteral("avatarURL")] = *artist.avatarURL;
    if (!artist.alias.isEmpty()) object[QStringLiteral("alias")] = aliasesToJson(artist.alias);
    return object;
}

std::optional<Artist> artistFromJson(const QJsonValue& value)
{
    if (!value.isObject()) return std::nullopt;
    const QJsonObject object = value.toObject();
    Artist artist;
    artist.id = json::optionalIDString(object.value(QStringLiteral("id"))).value_or(QString());
    artist.name = json::string(object.value(QStringLiteral("name")));
    artist.avatarURL = json::optionalString(object.value(QStringLiteral("avatarURL")));
    const QJsonArray aliases = json::array(object.value(QStringLiteral("alias")));
    for (const QJsonValue& alias : aliases) {
        if (alias.isString()) artist.alias.append(alias.toString());
    }
    return artist;
}

QJsonObject toJson(const Song& song)
{
    QJsonObject object;
    object[QStringLiteral("id")] = song.id;
    object[QStringLiteral("title")] = song.title;
    object[QStringLiteral("artists")] = artistsToJson(song.artists);
    if (song.album) object[QStringLiteral("album")] = toJson(*song.album);
    object[QStringLiteral("duration")] = song.duration;
    if (song.coverURL) object[QStringLiteral("coverURL")] = *song.coverURL;
    object[QStringLiteral("isPlayable")] = song.isPlayable;
    if (song.unavailableReason) object[QStringLiteral("unavailableReason")] = *song.unavailableReason;
    object[QStringLiteral("source")] = songSourceToJson(song.source);
    if (song.localFileURL) object[QStringLiteral("localFileURL")] = *song.localFileURL;
    return object;
}

std::optional<Song> songFromJson(const QJsonValue& value)
{
    if (!value.isObject()) return std::nullopt;
    const QJsonObject object = value.toObject();
    Song song;
    song.id = json::optionalIDString(object.value(QStringLiteral("id"))).value_or(QString());
    song.title = json::string(object.value(QStringLiteral("title")));
    const QJsonArray artists = json::array(object.value(QStringLiteral("artists")));
    for (const QJsonValue& artist : artists) {
        if (auto mapped = artistFromJson(artist)) song.artists.append(std::move(*mapped));
    }
    song.album = albumFromJson(object.value(QStringLiteral("album")));
    song.duration = json::optionalDouble(object.value(QStringLiteral("duration"))).value_or(0);
    song.coverURL = json::optionalString(object.value(QStringLiteral("coverURL")));
    song.isPlayable = json::optionalBool(object.value(QStringLiteral("isPlayable"))).value_or(true);
    song.unavailableReason = json::optionalString(object.value(QStringLiteral("unavailableReason")));
    song.source = songSourceFromJson(object.value(QStringLiteral("source")));
    song.localFileURL = json::optionalString(object.value(QStringLiteral("localFileURL")));
    return song;
}

QJsonObject toJson(const Playlist& playlist)
{
    QJsonObject object;
    object[QStringLiteral("id")] = playlist.id;
    object[QStringLiteral("name")] = playlist.name;
    if (playlist.coverURL) object[QStringLiteral("coverURL")] = *playlist.coverURL;
    object[QStringLiteral("trackCount")] = playlist.trackCount;
    if (playlist.creatorName) object[QStringLiteral("creatorName")] = *playlist.creatorName;
    if (playlist.descriptionText) object[QStringLiteral("descriptionText")] = *playlist.descriptionText;
    object[QStringLiteral("isSubscribed")] = playlist.isSubscribed;
    object[QStringLiteral("source")] = songSourceToJson(playlist.source);
    return object;
}

std::optional<Playlist> playlistFromJson(const QJsonValue& value)
{
    if (!value.isObject()) return std::nullopt;
    const QJsonObject object = value.toObject();
    Playlist playlist;
    playlist.id = json::optionalIDString(object.value(QStringLiteral("id"))).value_or(QString());
    playlist.name = json::string(object.value(QStringLiteral("name")));
    playlist.coverURL = json::optionalString(object.value(QStringLiteral("coverURL")));
    playlist.trackCount = json::optionalInt(object.value(QStringLiteral("trackCount"))).value_or(0);
    playlist.creatorName = json::optionalString(object.value(QStringLiteral("creatorName")));
    playlist.descriptionText = json::optionalString(object.value(QStringLiteral("descriptionText")));
    playlist.isSubscribed = json::optionalBool(object.value(QStringLiteral("isSubscribed"))).value_or(false);
    playlist.source = songSourceFromJson(object.value(QStringLiteral("source")));
    return playlist;
}

QJsonObject toJson(const AccountInfo& account)
{
    QJsonObject object;
    object[QStringLiteral("userID")] = account.userID;
    object[QStringLiteral("nickname")] = account.nickname;
    if (account.avatarURL) object[QStringLiteral("avatarURL")] = *account.avatarURL;
    object[QStringLiteral("isVIP")] = account.isVIP;
    return object;
}

std::optional<AccountInfo> accountFromJson(const QJsonValue& value)
{
    if (!value.isObject()) return std::nullopt;
    const QJsonObject object = value.toObject();
    AccountInfo account;
    account.userID = json::optionalIDString(object.value(QStringLiteral("userID"))).value_or(QString());
    account.nickname = json::string(object.value(QStringLiteral("nickname")));
    account.avatarURL = json::optionalString(object.value(QStringLiteral("avatarURL")));
    account.isVIP = json::optionalBool(object.value(QStringLiteral("isVIP"))).value_or(false);
    return account;
}

} // namespace ct
