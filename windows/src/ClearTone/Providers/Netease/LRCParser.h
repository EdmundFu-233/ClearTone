#pragma once

#include "Core/Models/MusicModels.h"

#include <QList>
#include <QString>

#include <optional>

namespace ct {

class LRCParser {
public:
    static QList<LyricLine> parse(const QString& lrc,
        const std::optional<QString>& translation = std::nullopt,
        const std::optional<QString>& romanization = std::nullopt);

    static QList<LyricLine> parseYRC(const QString& yrc,
        const std::optional<QString>& translation = std::nullopt,
        const std::optional<QString>& romanization = std::nullopt);

    static std::optional<int> currentLineIndex(
        const QList<LyricLine>& lines, double time, double offset = 0);
};

} // namespace ct
