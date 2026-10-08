#include "Playback/PlayQueue.h"

#include "Core/Models/JsonHelpers.h"
#include "Core/Models/ModelJson.h"

#include <QJsonArray>
#include <QRandomGenerator>

#include <cmath>
#include <limits>

namespace ct {

namespace {

PlayMode playModeFromJson(const QJsonValue& value)
{
    const QString raw = value.toString();
    if (raw == QLatin1String("loopAll")) return PlayMode::LoopAll;
    if (raw == QLatin1String("loopOne")) return PlayMode::LoopOne;
    if (raw == QLatin1String("shuffle")) return PlayMode::Shuffle;
    return PlayMode::Sequential;
}

QString playModeToJson(PlayMode mode)
{
    switch (mode) {
    case PlayMode::Sequential:
        return QStringLiteral("sequential");
    case PlayMode::LoopAll:
        return QStringLiteral("loopAll");
    case PlayMode::LoopOne:
        return QStringLiteral("loopOne");
    case PlayMode::Shuffle:
        return QStringLiteral("shuffle");
    }
    return QStringLiteral("sequential");
}

} // namespace

QString playMode::displayName(PlayMode mode)
{
    switch (mode) {
    case PlayMode::Sequential:
        return QStringLiteral("顺序播放");
    case PlayMode::LoopAll:
        return QStringLiteral("列表循环");
    case PlayMode::LoopOne:
        return QStringLiteral("单曲循环");
    case PlayMode::Shuffle:
        return QStringLiteral("随机播放");
    }
    return QStringLiteral("顺序播放");
}

QString playMode::glyph(PlayMode mode)
{
    switch (mode) {
    case PlayMode::Sequential:
        return QStringLiteral("arrow.right");
    case PlayMode::LoopAll:
        return QStringLiteral("repeat");
    case PlayMode::LoopOne:
        return QStringLiteral("repeat.1");
    case PlayMode::Shuffle:
        return QStringLiteral("shuffle");
    }
    return QStringLiteral("arrow.right");
}

void ShuffleHistory::append(const QUuid& id)
{
    m_stack.append(id);
    m_set.insert(id);
}

std::optional<QUuid> ShuffleHistory::popLast()
{
    if (m_stack.isEmpty()) return std::nullopt;
    const QUuid id = m_stack.takeLast();
    if (!m_stack.contains(id)) m_set.remove(id);
    return id;
}

void ShuffleHistory::removeAll()
{
    m_stack.clear();
    m_set.clear();
}

void ShuffleHistory::removeAllWhere(const std::function<bool(const QUuid&)>& predicate)
{
    QList<QUuid> kept;
    kept.reserve(m_stack.size());
    for (const QUuid& id : std::as_const(m_stack)) {
        if (!predicate(id)) kept.append(id);
    }
    m_stack = kept;
    m_set.clear();
    for (const QUuid& id : std::as_const(m_stack)) m_set.insert(id);
}

QueueItem* PlayQueue::currentItem()
{
    return currentIndex >= 0 && currentIndex < items.size() ? &items[currentIndex] : nullptr;
}

const QueueItem* PlayQueue::currentItem() const
{
    return currentIndex >= 0 && currentIndex < items.size() ? &items[currentIndex] : nullptr;
}

bool PlayQueue::hasNext() const
{
    if (items.isEmpty()) return false;
    switch (mode) {
    case PlayMode::LoopOne:
    case PlayMode::LoopAll:
        return true;
    case PlayMode::Sequential:
        return currentIndex < items.size() - 1;
    case PlayMode::Shuffle:
        return true;
    }
    return false;
}

bool PlayQueue::hasPrevious() const
{
    if (items.isEmpty()) return false;
    switch (mode) {
    case PlayMode::LoopOne:
        return true;
    case PlayMode::Shuffle:
        return !m_shuffleHistory.isEmpty();
    case PlayMode::LoopAll:
    case PlayMode::Sequential:
        return currentIndex > 0;
    }
    return false;
}

void PlayQueue::replace(const QList<Song>& songs, int startAt)
{
    items.clear();
    items.reserve(songs.size());
    for (const Song& song : songs) {
        QueueItem item;
        item.song = song;
        items.append(item);
    }
    currentIndex = items.isEmpty() ? -1 : qBound(0, startAt, items.size() - 1);
    m_shuffleHistory.removeAll();
}

void PlayQueue::append(const Song& song)
{
    QueueItem item;
    item.song = song;
    items.append(item);
    if (currentIndex == -1) currentIndex = 0;
}

void PlayQueue::appendRange(const QList<Song>& songs)
{
    for (const Song& song : songs) {
        QueueItem item;
        item.song = song;
        items.append(item);
    }
    if (currentIndex == -1 && !items.isEmpty()) currentIndex = 0;
}

void PlayQueue::insertNext(const Song& song)
{
    QueueItem item;
    item.song = song;
    if (currentIndex == -1) {
        items.append(item);
        currentIndex = 0;
    } else {
        items.insert(currentIndex + 1, item);
    }
}

bool PlayQueue::remove(const QUuid& itemID)
{
    int index = -1;
    for (int i = 0; i < items.size(); ++i) {
        if (items[i].id == itemID) {
            index = i;
            break;
        }
    }
    if (index < 0) return false;
    items.removeAt(index);
    m_shuffleHistory.removeAllWhere([&](const QUuid& id) { return id == itemID; });
    if (index < currentIndex) {
        currentIndex -= 1;
    } else if (index == currentIndex && currentIndex >= items.size()) {
        currentIndex = items.size() - 1;
    }
    return true;
}

void PlayQueue::clear()
{
    items.clear();
    currentIndex = -1;
    m_shuffleHistory.removeAll();
}

void PlayQueue::move(int fromIndex, int toIndex)
{
    if (fromIndex < 0 || fromIndex >= items.size()) return;
    if (toIndex < 0) return;
    if (toIndex >= items.size()) toIndex = items.size() - 1;
    if (fromIndex == toIndex) return;

    const auto currentID = currentItem() ? std::optional<QUuid>(currentItem()->id) : std::nullopt;
    const QueueItem item = items[fromIndex];
    items.removeAt(fromIndex);
    items.insert(toIndex, item);
    if (currentID) {
        for (int i = 0; i < items.size(); ++i) {
            if (items[i].id == *currentID) {
                currentIndex = i;
                break;
            }
        }
    }
}

bool PlayQueue::jumpTo(const QUuid& itemID)
{
    int index = -1;
    for (int i = 0; i < items.size(); ++i) {
        if (items[i].id == itemID) {
            index = i;
            break;
        }
    }
    if (index < 0) return false;
    if (mode == PlayMode::Shuffle && currentItem()) {
        m_shuffleHistory.append(currentItem()->id);
    }
    currentIndex = index;
    return true;
}

QueueItem* PlayQueue::next()
{
    if (items.isEmpty()) return nullptr;
    if (mode == PlayMode::Shuffle && currentItem()) {
        m_shuffleHistory.append(currentItem()->id);
    }

    switch (mode) {
    case PlayMode::LoopOne:
        return currentItem();
    case PlayMode::Sequential:
        if (currentIndex >= items.size() - 1) return nullptr;
        currentIndex += 1;
        return currentItem();
    case PlayMode::LoopAll:
        currentIndex = (currentIndex + 1) % items.size();
        return currentItem();
    case PlayMode::Shuffle: {
        QList<int> remaining;
        for (int index = 0; index < items.size(); ++index) {
            if (index != currentIndex && !m_shuffleHistory.contains(items[index].id)) {
                remaining.append(index);
            }
        }
        if (!remaining.isEmpty()) {
            currentIndex = remaining[QRandomGenerator::global()->bounded(remaining.size())];
        } else {
            m_shuffleHistory.removeAll();
            QList<int> candidates;
            for (int index = 0; index < items.size(); ++index) {
                if (index != currentIndex) candidates.append(index);
            }
            if (candidates.isEmpty()) return currentItem();
            currentIndex = candidates[QRandomGenerator::global()->bounded(candidates.size())];
        }
        return currentItem();
    }
    }
    return currentItem();
}

QueueItem* PlayQueue::previous()
{
    if (items.isEmpty()) return nullptr;

    switch (mode) {
    case PlayMode::LoopOne:
        return currentItem();
    case PlayMode::Shuffle:
        if (const auto lastID = m_shuffleHistory.popLast()) {
            for (int i = 0; i < items.size(); ++i) {
                if (items[i].id == *lastID) {
                    currentIndex = i;
                    return currentItem();
                }
            }
        }
        return currentItem();
    case PlayMode::LoopAll:
    case PlayMode::Sequential:
        if (currentIndex <= 0) return nullptr;
        currentIndex -= 1;
        return currentItem();
    }
    return currentItem();
}

QueueItem* PlayQueue::handleEnded()
{
    if (items.isEmpty()) return nullptr;
    switch (mode) {
    case PlayMode::LoopOne:
        return currentItem();
    case PlayMode::Sequential:
        if (currentIndex >= items.size() - 1) return nullptr;
        currentIndex += 1;
        return currentItem();
    case PlayMode::LoopAll:
        currentIndex = (currentIndex + 1) % items.size();
        return currentItem();
    case PlayMode::Shuffle:
        return next();
    }
    return currentItem();
}

PersistedQueue PersistedQueue::from(const PlayQueue& queue, double currentTime, float volume,
    bool isMuted, QualityLevel requestedQuality, float playbackRate)
{
    PersistedQueue persisted;
    persisted.items = queue.items;
    persisted.currentIndex = queue.currentIndex;
    persisted.mode = queue.mode;
    persisted.currentTime = currentTime;
    persisted.volume = volume;
    persisted.isMuted = isMuted;
    persisted.requestedQuality = requestedQuality;
    persisted.playbackRate = playbackRate;
    return persisted;
}

PlayQueue PersistedQueue::toPlayQueue() const
{
    PlayQueue queue;
    queue.mode = mode;
    QList<Song> songs;
    songs.reserve(items.size());
    for (const QueueItem& item : items) songs.append(item.song);
    queue.replace(songs, 0);
    for (int i = 0; i < items.size() && i < queue.items.size(); ++i) {
        queue.items[i].id = items[i].id;
    }
    if (currentIndex >= 0 && currentIndex < queue.items.size()) {
        queue.jumpTo(queue.items[currentIndex].id);
    }
    return queue;
}

QJsonObject toJson(const PersistedQueue& queue)
{
    QJsonObject object;
    QJsonArray items;
    for (const QueueItem& item : queue.items) {
        QJsonObject entry;
        entry[QStringLiteral("id")] = item.id.toString(QUuid::WithoutBraces);
        entry[QStringLiteral("song")] = toJson(item.song);
        entry[QStringLiteral("addedAt")] = json::dateTimeToJson(item.addedAt);
        items.append(entry);
    }
    object[QStringLiteral("items")] = items;
    object[QStringLiteral("currentIndex")] = queue.currentIndex;
    object[QStringLiteral("mode")] = playModeToJson(queue.mode);
    if (std::isnan(queue.currentTime)) {
        object[QStringLiteral("currentTime")] = QStringLiteral("NaN");
    } else if (std::isinf(queue.currentTime)) {
        object[QStringLiteral("currentTime")] =
            queue.currentTime > 0 ? QStringLiteral("Infinity") : QStringLiteral("-Infinity");
    } else {
        object[QStringLiteral("currentTime")] = queue.currentTime;
    }
    object[QStringLiteral("volume")] = static_cast<double>(queue.volume);
    object[QStringLiteral("isMuted")] = queue.isMuted;
    object[QStringLiteral("requestedQuality")] = qualityLevelToJson(queue.requestedQuality);
    object[QStringLiteral("playbackRate")] = static_cast<double>(queue.playbackRate);
    return object;
}

std::optional<PersistedQueue> persistedQueueFromJson(const QJsonValue& value)
{
    if (!value.isObject()) return std::nullopt;
    const QJsonObject object = value.toObject();
    PersistedQueue queue;
    const QJsonArray items = json::array(object.value(QStringLiteral("items")));
    for (const QJsonValue& entry : items) {
        if (!entry.isObject()) continue;
        const QJsonObject itemObject = entry.toObject();
        QueueItem item;
        const auto id = json::optionalString(itemObject.value(QStringLiteral("id")));
        if (id) {
            const QUuid parsed = QUuid::fromString(*id);
            if (!parsed.isNull()) item.id = parsed;
        }
        const auto song = songFromJson(itemObject.value(QStringLiteral("song")));
        if (!song) continue;
        item.song = *song;
        if (const auto addedAt = json::parseDateTime(itemObject.value(QStringLiteral("addedAt")))) {
            item.addedAt = *addedAt;
        }
        queue.items.append(item);
    }
    queue.currentIndex = json::optionalInt(object.value(QStringLiteral("currentIndex"))).value_or(-1);
    queue.mode = playModeFromJson(object.value(QStringLiteral("mode")));
    const QJsonValue currentTime = object.value(QStringLiteral("currentTime"));
    if (currentTime.isString()) {
        const QString raw = currentTime.toString();
        if (raw == QLatin1String("NaN")) {
            queue.currentTime = std::numeric_limits<double>::quiet_NaN();
        } else if (raw == QLatin1String("Infinity")) {
            queue.currentTime = std::numeric_limits<double>::infinity();
        } else if (raw == QLatin1String("-Infinity")) {
            queue.currentTime = -std::numeric_limits<double>::infinity();
        } else {
            queue.currentTime = json::optionalDouble(currentTime).value_or(0);
        }
    } else {
        queue.currentTime = json::optionalDouble(currentTime).value_or(0);
    }
    queue.volume = static_cast<float>(json::optionalDouble(object.value(QStringLiteral("volume"))).value_or(0));
    queue.isMuted = json::optionalBool(object.value(QStringLiteral("isMuted"))).value_or(false);
    queue.requestedQuality =
        qualityLevelFromJson(object.value(QStringLiteral("requestedQuality")), QualityLevel::Unknown);
    queue.playbackRate =
        static_cast<float>(json::optionalDouble(object.value(QStringLiteral("playbackRate"))).value_or(1.0));
    return queue;
}

} // namespace ct
