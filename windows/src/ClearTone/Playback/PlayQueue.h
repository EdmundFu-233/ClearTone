#pragma once

#include "Core/Models/MusicModels.h"

#include <QDateTime>
#include <QJsonObject>
#include <QList>
#include <QSet>
#include <QString>
#include <QUuid>

#include <functional>
#include <optional>

namespace ct {

struct PlaybackState {
    enum class Kind {
        Idle,
        Loading,
        Playing,
        Paused,
        Buffering,
        Ended,
        Failed,
    };

    Kind kind = Kind::Idle;
    QString songId;
    QString reason;

    bool isPlaying() const { return kind == Kind::Playing; }
    bool isPlayIntentActive() const
    {
        return kind == Kind::Playing || kind == Kind::Buffering || kind == Kind::Loading;
    }
    bool isBuffering() const { return kind == Kind::Buffering; }
    bool isLoading() const { return kind == Kind::Loading; }
};

enum class PlayMode {
    Sequential,
    LoopAll,
    LoopOne,
    Shuffle,
};

namespace playMode {
QString displayName(PlayMode mode);
QString glyph(PlayMode mode);
} // namespace playMode

struct QueueItem {
    QUuid id = QUuid::createUuid();
    Song song;
    QDateTime addedAt = QDateTime::currentDateTime();

    bool operator==(const QueueItem& other) const { return id == other.id; }
};

class ShuffleHistory {
public:
    bool isEmpty() const { return m_stack.isEmpty(); }
    int count() const { return m_stack.size(); }

    void append(const QUuid& id);
    std::optional<QUuid> popLast();
    bool contains(const QUuid& id) const { return m_set.contains(id); }
    void removeAll();
    void removeAllWhere(const std::function<bool(const QUuid&)>& predicate);

private:
    QList<QUuid> m_stack;
    QSet<QUuid> m_set;
};

class PlayQueue {
public:
    QList<QueueItem> items;
    int currentIndex = -1;
    PlayMode mode = PlayMode::Sequential;

    QueueItem* currentItem();
    const QueueItem* currentItem() const;
    bool isEmpty() const { return items.isEmpty(); }
    int count() const { return items.size(); }

    bool hasNext() const;
    bool hasPrevious() const;

    void replace(const QList<Song>& songs, int startAt = 0);
    void append(const Song& song);
    void appendRange(const QList<Song>& songs);
    void insertNext(const Song& song);
    bool remove(const QUuid& itemID);
    void clear();
    void move(int fromIndex, int toIndex);
    bool jumpTo(const QUuid& itemID);

    QueueItem* next();
    QueueItem* previous();
    QueueItem* handleEnded();

private:
    ShuffleHistory m_shuffleHistory;
};

struct PersistedQueue {
    QList<QueueItem> items;
    int currentIndex = -1;
    PlayMode mode = PlayMode::Sequential;
    double currentTime = 0;
    float volume = 0;
    bool isMuted = false;
    QualityLevel requestedQuality = QualityLevel::Unknown;
    float playbackRate = 1.0f;

    static PersistedQueue from(const PlayQueue& queue, double currentTime, float volume, bool isMuted,
        QualityLevel requestedQuality, float playbackRate);
    PlayQueue toPlayQueue() const;
};

QJsonObject toJson(const PersistedQueue& queue);
std::optional<PersistedQueue> persistedQueueFromJson(const QJsonValue& value);

} // namespace ct
