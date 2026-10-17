#pragma once

#include "Core/Async.h"

#include <QByteArray>
#include <QHash>
#include <QImage>
#include <QList>
#include <QObject>
#include <QQueue>
#include <QString>

#include <memory>
#include <optional>

namespace ct {

class HTTPClient;

class CoverImageLoader : public QObject {
public:
    static CoverImageLoader& shared();

    explicit CoverImageLoader(HTTPClient* client = nullptr, QObject* parent = nullptr);
    ~CoverImageLoader() override;

    virtual Task<std::optional<QImage>> load(const QString& url, int decodeWidth = 0,
        CancellationToken ct = CancellationToken::none());
    virtual Task<std::optional<QByteArray>> loadBytes(const QString& url,
        CancellationToken ct = CancellationToken::none());

    std::optional<QImage> peekMemory(const QString& url, int decodeWidth = 0);
    void clearMemoryCache();
    void pruneDiskCache();

    static QString sizedUrl(const QString& url, int decodeWidth = 0);
    static QString cacheRoot();
    static QString diskCachePath(const QString& url);

    static constexpr int MemoryEntryLimit = 80;
    static constexpr int MaxConcurrentLoads = 6;
    static constexpr qint64 MemoryByteLimit = 8LL * 1024 * 1024;
    static constexpr qint64 DiskByteLimit = 64LL * 1024 * 1024;
    static constexpr qint64 MaxSingleDiskFileBytes = 512LL * 1024;
    static constexpr int DiskMaxAgeDays = 30;

private:
    struct MemoryEntry {
        QImage image;
        qint64 bytes = 0;
    };

    struct PendingWaiter {
        int id = 0;
        CancellationToken token;
        int cancelCallbackId = 0;
        Callback<std::optional<QImage>> callback;
    };

    std::optional<QImage> memoryLookup(const QString& key);
    void insertIntoMemory(const QString& key, const QImage& image);
    void pumpQueue();
    Task<std::optional<QByteArray>> readBytes(const QString& url, CancellationToken ct);
    Task<void> loadCoreImage(QString key, QString url, int decodeWidth, CancellationToken ct);
    Awaitable<std::optional<QImage>> waitForImage(const QString& key, CancellationToken ct);

    std::unique_ptr<HTTPClient> m_ownedClient;
    HTTPClient* m_client = nullptr;
    QHash<QString, MemoryEntry> m_memory;
    QList<QString> m_lru;
    qint64 m_memoryBytes = 0;
    QHash<QString, QList<PendingWaiter>> m_pendingImages;
    struct ImageRequest { QString key; QString url; int width = 0; };
    QQueue<ImageRequest> m_queuedImages;
    int m_activeLoads = 0;
    int m_nextWaiterId = 0;
    int m_writesSincePrune = 0;
};

} // namespace ct
