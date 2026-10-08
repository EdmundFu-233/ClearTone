#pragma once

#include "Core/Models/MusicModels.h"
#include "Core/Models/MusicProvider.h"
#include "Core/Persistence/AppSettings.h"
#include "Playback/PlayQueue.h"

#include <QJsonObject>
#include <QJsonValue>
#include <QObject>
#include <QString>
#include <QTimer>

#include <functional>
#include <optional>

namespace ct {

class PersistenceStore {
public:
    static PersistenceStore& shared();

    PersistenceStore();

    QString storageRoot() const;

    // 队列
    void saveQueue(const PersistedQueue& queue);
    std::optional<PersistedQueue> loadQueue();
    void clearQueue();

    // 设置（settings.json 内的 JSON 值）
    void saveSetting(const QString& key, const QJsonValue& value);
    QJsonValue loadSetting(const QString& key);
    void removeSetting(const QString& key);
    QString settingKeyFor(const QString& key) const;

    // 离线缓存（账号 / 喜欢的歌曲 / 用户歌单 / 本地曲库 / 最近播放）
    void saveCachedAccount(const AccountInfo& account);
    std::optional<AccountInfo> loadCachedAccount();
    void clearCachedAccount();

    void saveCachedLikedSongs(const QList<Song>& songs);
    QList<Song> loadCachedLikedSongs();
    void saveCachedLikedSongIDs(const QStringList& ids);
    QStringList loadCachedLikedSongIDs();
    void clearCachedLikedSongs();

    void saveCachedUserPlaylists(const QList<Playlist>& playlists);
    QList<Playlist> loadCachedUserPlaylists();
    void clearCachedUserPlaylists();

    void saveLocalLibrary(const QStringList& paths);
    QStringList loadLocalLibrary();

    void saveRecentSongs(const QList<Song>& songs);
    QList<Song> loadRecentSongs();

private:
    QString queuePath() const;
    QString settingsPath() const;
    QJsonObject& settingsFile();
    void persistSettingsFile();
    void purgeOrphanedDemoAudio();
    static bool isNotLegacyDemoSong(const Song& song);

    QJsonObject m_settingsCache;
    bool m_settingsLoaded = false;
};

class PersistenceWriter : public QObject {
    Q_OBJECT

public:
    static PersistenceWriter& shared();

    void schedule(const PersistedQueue& queue);
    void scheduleRecent(const QList<Song>& songs);
    void flushNow();
    void persistAndFlush(const std::optional<PersistedQueue>& queue, const std::optional<QList<Song>>& recent);
    void reset();

    // 测试钩子
    std::function<void(const PersistedQueue&)> queueWriteOverride;
    std::function<void(const QList<Song>&)> recentWriteOverride;

private:
    explicit PersistenceWriter(QObject* parent = nullptr);

    void scheduleFlushLocked();
    void writePending();
    void writeQueueSnapshot(const PersistedQueue& queue);
    void writeRecentSnapshot(const QList<Song>& recent);

    QTimer* m_flushTimer = nullptr;
    std::optional<PersistedQueue> m_pendingQueue;
    std::optional<QList<Song>> m_pendingRecent;
    int m_consecutiveWriteFailures = 0;

    static constexpr int maxAutoRetries = 5;
    static constexpr int debounceMs = 800;
    static constexpr qint64 maxBytes = 8LL * 1024 * 1024;
};

} // namespace ct
