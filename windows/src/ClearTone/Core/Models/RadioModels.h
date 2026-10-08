#pragma once

#include "Core/Models/MusicModels.h"

#include <QDateTime>
#include <QString>

#include <optional>

namespace ct {

struct RadioStation {
    QString id;
    QString name;
    std::optional<QString> coverURL;
    int programCount = 0;
    int subscriberCount = 0;
    std::optional<QString> creatorName;
    std::optional<QString> categoryName;
    std::optional<QString> descriptionText;
    bool isSubscribed = false;

    bool operator==(const RadioStation&) const = default;
};

struct RadioProgram {
    QString id;
    QString title;
    std::optional<QString> coverURL;
    double duration = 0;
    std::optional<QDateTime> createTime;
    int playCount = 0;
    std::optional<QString> stationName;
    std::optional<Song> song;

    bool isPlayable() const { return song && song->isPlayable; }

    bool operator==(const RadioProgram&) const = default;
};

struct RadioCategory {
    QString id;
    QString name;
    QStringList subCategories;

    bool operator==(const RadioCategory&) const = default;
};

} // namespace ct
