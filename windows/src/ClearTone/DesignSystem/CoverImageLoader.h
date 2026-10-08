#pragma once

#include "Core/Async.h"

#include <QByteArray>
#include <QHash>
#include <QImage>
#include <QList>
#include <QObject>
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

    void pruneDiskCache();

    static QString cacheRoot();
    static QString diskCachePath(const QString& url);

    static constexpr int MemoryEntryLimit = 400;
    static constexpr qint64 MemoryByteLimit = 64LL * 1024 * 1024;
    static constexpr qint64 DiskByteLimit = 300LL * 1024 * 1024;
    static constexpr int DiskMaxAgeDays = 60;

private:
    struct MemoryEntry {
        QImage image;
        qint64 bytes = 0;
    };

    std::optional<QImage> memoryLookup(const QString& key);
    void insertIntoMemory(const QString& key, const QImage& image);
    Task<std::optional<QByteArray>> readBytes(const QString& url, CancellationToken ct);
    Task<void> loadCoreImage(QString key, QString url, int decodeWidth, CancellationToken ct);
    Awaitable<std::optional<QImage>> waitForImage(const QString& key);

    std::unique_ptr<HTTPClient> m_ownedClient;
    HTTPClient* m_client = nullptr;
    QHash<QString, MemoryEntry> m_memory;
    QList<QString> m_lru;
    qint64 m_memoryBytes = 0;
    QHash<QString, QList<Callback<std::optional<QImage>>>> m_pendingImages;
};

} // namespace ct
