#pragma once

#include "Core/Models/MusicModels.h"

#include <QDateTime>
#include <QList>
#include <QString>

#include <optional>

namespace ct {

struct TopList {
    QString id;
    QString name;
    std::optional<QString> coverURL;
    std::optional<QString> updateFrequency;
    int trackCount = 0;
    int playCount = 0;
    std::optional<QString> descriptionText;
    std::optional<QString> iconURL;

    bool operator==(const TopList&) const = default;
};

enum class TopSongArea {
    All,
    Chinese,
    Western,
    Japan,
    Korea,
};

namespace topSongArea {
QString displayName(TopSongArea area);
int areaID(TopSongArea area);
} // namespace topSongArea

enum class TopPlaylistOrder {
    Hot,
    New,
};

namespace topPlaylistOrder {
QString displayName(TopPlaylistOrder order);
QString apiValue(TopPlaylistOrder order);
} // namespace topPlaylistOrder

struct PlaylistCategoryGroup {
    QString name;
    QStringList categories;

    bool operator==(const PlaylistCategoryGroup&) const = default;
};

struct SearchSuggestion {
    enum class Kind {
        Song,
        Artist,
        Album,
        Playlist,
    };

    Kind suggestionKind = Kind::Song;
    QString title;
    std::optional<QString> subtitle;
    std::optional<QString> coverURL;
    QString targetID;

    QString id() const;
    bool operator==(const SearchSuggestion&) const = default;
};

struct HotSearchTerm {
    QString keyword;
    int score = 0;
    std::optional<QString> displayPrefix;
    std::optional<QString> icon;

    QString id() const { return keyword; }
    bool operator==(const HotSearchTerm&) const = default;
};

struct UserLevelInfo {
    int level = 0;
    int listenSongs = 0;
    int listenDays = 0;
    int currentLoginDays = 0;
    int nextLevelNeedLoginDays = 0;
    int nextLevelNeedListenSongs = 0;
    int currentProgress = 0;

    int remainingLoginDays() const { return qMax(0, nextLevelNeedLoginDays); }
    double progressFraction() const;

    bool operator==(const UserLevelInfo&) const = default;
};

struct ListenRecord {
    Song song;
    int playCount = 0;
    std::optional<QDateTime> lastPlayedAt;

    QString id() const { return song.id; }
    bool operator==(const ListenRecord&) const = default;
};

struct SignInResult {
    enum class Kind {
        Success,
        AlreadySigned,
        Failed,
    };

    Kind kind = Kind::Failed;
    int point = 0;
    QString reason;

    bool isSuccess() const { return kind == Kind::Success; }
    bool operator==(const SignInResult&) const = default;
};

struct SubscribeTarget {
    enum class Kind {
        Playlist,
        Album,
        Artist,
        Radio,
    };

    Kind kind = Kind::Playlist;
    QString value;

    QString id() const { return value; }
    QString displayName() const;
    std::optional<QString> countKey() const;

    static SubscribeTarget playlist(QString value) { return {Kind::Playlist, std::move(value)}; }
    static SubscribeTarget album(QString value) { return {Kind::Album, std::move(value)}; }
    static SubscribeTarget artist(QString value) { return {Kind::Artist, std::move(value)}; }
    static SubscribeTarget radio(QString value) { return {Kind::Radio, std::move(value)}; }

    bool operator==(const SubscribeTarget&) const = default;
};

} // namespace ct
