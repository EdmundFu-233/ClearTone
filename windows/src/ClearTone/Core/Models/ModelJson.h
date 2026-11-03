#pragma once

#include "Core/Models/MusicModels.h"
#include "Core/Models/MusicProvider.h"

#include <QJsonObject>
#include <QJsonValue>

#include <optional>

namespace ct {

// 模型序列化保持 camelCase、忽略 null、枚举使用 camelCase 字符串，
// 用于持久化队列 / 设置缓存等需要跨版本读取的数据。

QString qualityLevelToJson(QualityLevel level);
QualityLevel qualityLevelFromJson(const QJsonValue& value, QualityLevel fallback = QualityLevel::Unknown);

QString songSourceToJson(SongSource source);
SongSource songSourceFromJson(const QJsonValue& value);

QJsonObject toJson(const Album& album);
std::optional<Album> albumFromJson(const QJsonValue& value);

QJsonObject toJson(const Artist& artist);
std::optional<Artist> artistFromJson(const QJsonValue& value);

QJsonObject toJson(const Song& song);
std::optional<Song> songFromJson(const QJsonValue& value);

QJsonObject toJson(const Playlist& playlist);
std::optional<Playlist> playlistFromJson(const QJsonValue& value);

QJsonObject toJson(const AccountInfo& account);
std::optional<AccountInfo> accountFromJson(const QJsonValue& value);

} // namespace ct
