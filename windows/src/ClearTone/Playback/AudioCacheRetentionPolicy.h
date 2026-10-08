#pragma once

#include <QDateTime>
#include <QHash>
#include <QSet>
#include <QString>

#include <chrono>

namespace ct::audioCacheRetentionPolicy {

inline constexpr qint64 maxAgeSeconds = 7 * 24 * 60 * 60;

inline std::chrono::seconds maxAge()
{
    return std::chrono::seconds(maxAgeSeconds);
}

inline bool isExpired(const QDateTime& cachedAt, const QDateTime& now, std::chrono::seconds age)
{
    const qint64 elapsedMs = cachedAt.msecsTo(now);
    if (elapsedMs < 0) return false;
    const qint64 ageMs = std::chrono::duration_cast<std::chrono::milliseconds>(age).count();
    return elapsedMs >= ageMs;
}

inline bool isExpired(const QDateTime& cachedAt)
{
    return isExpired(cachedAt, QDateTime::currentDateTimeUtc(), maxAge());
}

inline QSet<QString> expiredIDs(
    const QHash<QString, QDateTime>& cachedAtByID, const QDateTime& now, std::chrono::seconds age)
{
    QSet<QString> result;
    for (auto it = cachedAtByID.constBegin(); it != cachedAtByID.constEnd(); ++it) {
        if (isExpired(it.value(), now, age)) result.insert(it.key());
    }
    return result;
}

inline QSet<QString> expiredIDs(const QHash<QString, QDateTime>& cachedAtByID)
{
    return expiredIDs(cachedAtByID, QDateTime::currentDateTimeUtc(), maxAge());
}

} // namespace ct::audioCacheRetentionPolicy
