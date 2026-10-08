#pragma once

#include <QDateTime>
#include <QHash>
#include <QList>
#include <QQueue>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QUrl>

#include <functional>
#include <optional>

class QNetworkAccessManager;
class QTimer;

namespace ct {

class AudioCacheManager {
public:
    struct CacheMeta {
        QString formatName;
        int bitrateKbps = 0;
        QString fileExtension;
        qint64 sizeBytes = 0;
        QDateTime cachedAt;
        std::optional<QDateTime> lastAccessedAt;
    };

    struct CachedAudio {
        QUrl url;
        QString formatName;
        int bitrateKbps = 0;
    };

    static constexpr int DefaultTargetBitrate = 128000;

    static const QStringList& cacheFileExtensions();
    static AudioCacheManager& shared();

    explicit AudioCacheManager(QString cacheDirectory);
    ~AudioCacheManager();

    bool isEnabled() const { return m_isEnabled; }
    void setEnabled(bool value) { m_isEnabled = value; }

    QSet<QString> cachedSongIDs() const { return m_cachedSongIDs; }
    QSet<QString> cachingSongIDs() const { return m_cachingSongIDs; }
    qint64 totalCacheBytes() const;
    QString formattedTotalSize() const;

    static bool isCacheFile(const QString& path);
    static QStringList cacheClearDeletionTargets(
        const QStringList& paths, const std::optional<QString>& protectedSongID);
    static QString extensionFor(const std::optional<QString>& contentType, const std::optional<QUrl>& sourceURL);
    static QString formatBytes(qint64 bytes);

    std::optional<CachedAudio> cachedItem(const QString& songID);
    std::optional<CacheMeta> meta(const QString& songID) const;
    void setCurrentCachedSong(const std::optional<QString>& songID) { m_currentCachedSongID = songID; }
    void cacheInBackground(const QString& songID, const QUrl& sourceURL, double durationSeconds = 0);
    void clearAll();

    std::function<void()> stateChanged;

private:
    struct PendingCache {
        QString songID;
        QUrl sourceURL;
        double durationSeconds = 0;
        quint64 generation = 0;
    };

    QString filePathFor(const QString& songID, const CacheMeta& meta) const;
    void refreshIndex();
    void persistIndex();
    void persistIndexSoon();
    void pumpCacheQueue();
    void downloadJob(const PendingCache& job);
    void commitDownload(const PendingCache& job, const QString& path, const QString& formatName,
        const QString& extension, qint64 sizeBytes);
    void finishCacheJob(const PendingCache& job);
    void touchAccess(const QString& songID);
    int purgeExpired();
    void trimIfNeeded();
    bool hasSufficientDiskSpace() const;

    QString m_cacheDirectory;
    QString m_indexPath;
    QHash<QString, CacheMeta> m_index;
    QSet<QString> m_cachedSongIDs;
    QSet<QString> m_cachingSongIDs;
    QQueue<PendingCache> m_pending;

    bool m_isEnabled = true;
    bool m_isRunning = false;
    quint64 m_clearGeneration = 0;
    std::optional<QString> m_currentCachedSongID;
    bool m_indexDirty = false;

    QNetworkAccessManager* m_network = nullptr;
    QTimer* m_indexFlushTimer = nullptr;

    static constexpr long long maxCacheBytes = 1'500'000'000;
    static constexpr long long requiredFreeBytes = 64LL * 1024 * 1024;
    static constexpr int accessTouchIntervalMs = 60 * 1000;
    static constexpr int indexFlushDelayMs = 500;
    static constexpr int downloadTimeoutMs = 5 * 60 * 1000;
};

} // namespace ct
