#pragma once

#include "Core/Models/MusicModels.h"

#include <QString>

#include <optional>

namespace ct {

struct CacheHint {
    enum class Kind {
        None,
        Caching,
        Cached,
    };

    Kind kind = Kind::None;
    QString format;
    int bitrateKbps = 0;

    bool isPresent() const { return kind != Kind::None; }

    static CacheHint none() { return {}; }

    static CacheHint caching()
    {
        CacheHint hint;
        hint.kind = Kind::Caching;
        return hint;
    }

    static CacheHint cached(QString format, int bitrateKbps)
    {
        CacheHint hint;
        hint.kind = Kind::Cached;
        hint.format = std::move(format);
        hint.bitrateKbps = bitrateKbps;
        return hint;
    }

    bool operator==(const CacheHint&) const = default;
};

struct PlayingSourceInfo {
    QString text;
    QString shortText;
    bool isFromCache = false;
    CacheHint cache;
    QString detail;

    bool operator==(const PlayingSourceInfo&) const = default;
};

namespace playingSourceFormatter {

std::optional<PlayingSourceInfo> describe(const std::optional<AudioQuality>& actualQuality,
    QualityLevel requestedLevel, bool isFromCache,
    const std::optional<QString>& cacheFormat = std::nullopt,
    const std::optional<int>& cacheBitrateKbps = std::nullopt, bool isCaching = false);

} // namespace playingSourceFormatter

} // namespace ct
