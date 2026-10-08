#pragma once

#include "Core/Models/MusicModels.h"

#include <QDateTime>
#include <QList>
#include <QString>

#include <cmath>
#include <optional>

namespace ct {

struct SongQualityOverride {
    QString songID;
    QualityLevel level = QualityLevel::Unknown;
    QDateTime updatedAt = QDateTime::currentDateTime();

    QString id() const { return songID; }

    bool operator==(const SongQualityOverride&) const = default;
};

namespace songQualityPolicy {

inline const QList<QualityLevel> selectableLevels = {
    QualityLevel::Standard,
    QualityLevel::Higher,
    QualityLevel::ExHigh,
    QualityLevel::Lossless,
    QualityLevel::HiRes,
};

inline constexpr QualityLevel autoLevel = QualityLevel::Unknown;

inline QualityLevel defaultLevel(bool isVIP)
{
    return isVIP ? QualityLevel::Lossless : QualityLevel::ExHigh;
}

inline QualityLevel effectiveGlobalLevel(QualityLevel preference, bool isVIP)
{
    return preference == autoLevel ? defaultLevel(isVIP) : preference;
}

inline QualityLevel effectiveLevel(const std::optional<QualityLevel>& overridden, QualityLevel global)
{
    return overridden.value_or(global);
}

inline bool useLocalCache(bool hasOverride) { return !hasOverride; }

inline bool shouldWriteCache(bool hasOverride, bool isPreview) { return !hasOverride && !isPreview; }

inline std::optional<int> derivedBitrateKbps(const std::optional<qint64>& sizeBytes, double duration)
{
    if (!sizeBytes || *sizeBytes <= 0 || duration <= 1) return std::nullopt;
    const double kbps = static_cast<double>(*sizeBytes) * 8 / duration / 1000;
    if (!std::isfinite(kbps) || kbps < 1) return std::nullopt;
    return static_cast<int>(qRound(kbps));
}

} // namespace songQualityPolicy

} // namespace ct
