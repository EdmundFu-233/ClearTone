#include "Core/Models/MusicModels.h"

#include "Core/Models/MusicProvider.h"

#include "Core/Models/JsonHelpers.h"

namespace ct {

QString Song::artistNames() const
{
    QStringList names;
    names.reserve(artists.size());
    for (const Artist& artist : artists) names.append(artist.name);
    return names.join(QStringLiteral(" / "));
}

QString Artist::displayNameWithAlias() const
{
    for (const QString& candidate : alias) {
        if (!candidate.isEmpty() && candidate != name) {
            return name + QStringLiteral(" · ") + candidate;
        }
    }
    return name;
}

namespace quality {

QString displayName(QualityLevel level)
{
    switch (level) {
    case QualityLevel::Standard:
        return QStringLiteral("标准");
    case QualityLevel::Higher:
        return QStringLiteral("较高");
    case QualityLevel::ExHigh:
        return QStringLiteral("极高");
    case QualityLevel::Lossless:
        return QStringLiteral("无损");
    case QualityLevel::HiRes:
        return QStringLiteral("Hi-Res");
    case QualityLevel::Unknown:
        return QStringLiteral("未知");
    }
    return QStringLiteral("未知");
}

QString persistedName(QualityLevel level) { return displayName(level); }

std::optional<QualityLevel> fromPersistedName(const QString& raw)
{
    if (raw == QStringLiteral("标准")) return QualityLevel::Standard;
    if (raw == QStringLiteral("较高")) return QualityLevel::Higher;
    if (raw == QStringLiteral("极高")) return QualityLevel::ExHigh;
    if (raw == QStringLiteral("无损")) return QualityLevel::Lossless;
    if (raw == QStringLiteral("Hi-Res")) return QualityLevel::HiRes;
    if (raw == QStringLiteral("未知")) return QualityLevel::Unknown;
    return std::nullopt;
}

QualityLevel fromAPIValue(const QString& raw)
{
    if (raw == QLatin1String("standard")) return QualityLevel::Standard;
    if (raw == QLatin1String("higher")) return QualityLevel::Higher;
    if (raw == QLatin1String("exhigh")) return QualityLevel::ExHigh;
    if (raw == QLatin1String("lossless")) return QualityLevel::Lossless;
    if (raw == QLatin1String("hires")) return QualityLevel::HiRes;
    return QualityLevel::Unknown;
}

QString apiValue(QualityLevel level)
{
    switch (level) {
    case QualityLevel::Standard:
        return QStringLiteral("standard");
    case QualityLevel::Higher:
        return QStringLiteral("higher");
    case QualityLevel::ExHigh:
        return QStringLiteral("exhigh");
    case QualityLevel::Lossless:
        return QStringLiteral("lossless");
    case QualityLevel::HiRes:
        return QStringLiteral("hires");
    case QualityLevel::Unknown:
        return QStringLiteral("standard");
    }
    return QStringLiteral("standard");
}

} // namespace quality

namespace searchType {

QString displayName(SearchType type)
{
    switch (type) {
    case SearchType::Song:
        return QStringLiteral("单曲");
    case SearchType::Artist:
        return QStringLiteral("歌手");
    case SearchType::Album:
        return QStringLiteral("专辑");
    case SearchType::Playlist:
        return QStringLiteral("歌单");
    }
    return QStringLiteral("单曲");
}

QList<SearchType> all()
{
    return {SearchType::Song, SearchType::Artist, SearchType::Album, SearchType::Playlist};
}

} // namespace searchType

} // namespace ct
