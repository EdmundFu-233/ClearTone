#include "Core/Models/DiscoveryModels.h"

namespace ct {

namespace topSongArea {

QString displayName(TopSongArea area)
{
    switch (area) {
    case TopSongArea::All:
        return QStringLiteral("全部");
    case TopSongArea::Chinese:
        return QStringLiteral("华语");
    case TopSongArea::Western:
        return QStringLiteral("欧美");
    case TopSongArea::Japan:
        return QStringLiteral("日本");
    case TopSongArea::Korea:
        return QStringLiteral("韩国");
    }
    return QStringLiteral("全部");
}

int areaID(TopSongArea area)
{
    switch (area) {
    case TopSongArea::All:
        return 0;
    case TopSongArea::Chinese:
        return 7;
    case TopSongArea::Western:
        return 96;
    case TopSongArea::Japan:
        return 8;
    case TopSongArea::Korea:
        return 16;
    }
    return 0;
}

} // namespace topSongArea

namespace topPlaylistOrder {

QString displayName(TopPlaylistOrder order)
{
    return order == TopPlaylistOrder::Hot ? QStringLiteral("最热") : QStringLiteral("最新");
}

QString apiValue(TopPlaylistOrder order)
{
    return order == TopPlaylistOrder::Hot ? QStringLiteral("hot") : QStringLiteral("new");
}

} // namespace topPlaylistOrder

QString SearchSuggestion::id() const
{
    QString kindName;
    switch (suggestionKind) {
    case Kind::Song:
        kindName = QStringLiteral("song");
        break;
    case Kind::Artist:
        kindName = QStringLiteral("artist");
        break;
    case Kind::Album:
        kindName = QStringLiteral("album");
        break;
    case Kind::Playlist:
        kindName = QStringLiteral("playlist");
        break;
    }
    return kindName + QStringLiteral("-") + targetID;
}

double UserLevelInfo::progressFraction() const
{
    if (nextLevelNeedLoginDays <= 0) return 0;
    const double raw = static_cast<double>(currentLoginDays) / nextLevelNeedLoginDays;
    return qBound(0.0, raw, 1.0);
}

QString SubscribeTarget::displayName() const
{
    switch (kind) {
    case Kind::Playlist:
        return QStringLiteral("歌单");
    case Kind::Album:
        return QStringLiteral("专辑");
    case Kind::Artist:
        return QStringLiteral("歌手");
    case Kind::Radio:
        return QStringLiteral("电台");
    }
    return QStringLiteral("歌单");
}

std::optional<QString> SubscribeTarget::countKey() const
{
    switch (kind) {
    case Kind::Playlist:
        return QStringLiteral("收藏歌单");
    case Kind::Album:
        return std::nullopt;
    case Kind::Artist:
        return QStringLiteral("关注歌手");
    case Kind::Radio:
        return QStringLiteral("收藏电台");
    }
    return std::nullopt;
}

} // namespace ct
