#pragma once

#include <QDateTime>
#include <QList>
#include <QString>

#include <optional>

namespace ct {

enum class SongSource {
    Netease,
    Local,
};

struct Artist {
    QString id;
    QString name;
    std::optional<QString> avatarURL;
    QStringList alias;

    QString displayNameWithAlias() const;
    bool operator==(const Artist&) const = default;
};

struct Album {
    QString id;
    QString name;
    std::optional<QString> coverURL;

    bool operator==(const Album&) const = default;
};

struct Song {
    QString id;
    QString title;
    QList<Artist> artists;
    std::optional<Album> album;
    double duration = 0;
    std::optional<QString> coverURL;
    bool isPlayable = true;
    std::optional<QString> unavailableReason;
    SongSource source = SongSource::Netease;
    std::optional<QString> localFileURL;

    QString artistNames() const;
    bool operator==(const Song&) const = default;
};

enum class QualityLevel {
    Standard,
    Higher,
    ExHigh,
    Lossless,
    HiRes,
    Unknown,
};

namespace quality {
QString displayName(QualityLevel level);
QString persistedName(QualityLevel level);
std::optional<QualityLevel> fromPersistedName(const QString& raw);
QualityLevel fromAPIValue(const QString& raw);
QString apiValue(QualityLevel level);
} // namespace quality

struct AudioQuality {
    QualityLevel level = QualityLevel::Unknown;
    std::optional<int> bitrate;
    std::optional<int> sampleRate;
    std::optional<int> bitDepth;
    bool isActual = false;
    std::optional<QString> codec;

    bool operator==(const AudioQuality&) const = default;
};

struct Playlist {
    QString id;
    QString name;
    std::optional<QString> coverURL;
    int trackCount = 0;
    std::optional<QString> creatorName;
    std::optional<QString> descriptionText;
    bool isSubscribed = false;
    SongSource source = SongSource::Netease;

    bool operator==(const Playlist&) const = default;
};

struct PlayableURL {
    QString url;
    AudioQuality quality;
    std::optional<QDateTime> expiresAt;
    bool isPreview = false;
    bool isCached = false;
    std::optional<qint64> sizeBytes;
};

struct LyricWord {
    double time = 0;
    double duration = 0;
    QString text;

    bool operator==(const LyricWord&) const = default;
};

struct LyricLine {
    QString id;
    double time = 0;
    QString text;
    std::optional<QString> translation;
    std::optional<QString> romanization;
    std::optional<QList<LyricWord>> words;

    bool operator==(const LyricLine&) const = default;
};

} // namespace ct
