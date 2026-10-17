#include "DesignSystem/CoverImageLoader.h"

#include "Core/Logging/CTLog.h"
#include "Core/Networking/HTTPClient.h"
#include "Core/Persistence/StoragePaths.h"

#include <QCryptographicHash>
#include <QBuffer>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QImageWriter>
#include <QSaveFile>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>

#include <algorithm>

namespace ct {

namespace {

const QString& userAgent()
{
    static const QString agent = QStringLiteral(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36");
    return agent;
}

QByteArray compressLargeCoverBytes(const QByteArray& raw)
{
    if (raw.size() <= 96 * 1024) return raw;
    QBuffer inBuffer;
    inBuffer.setData(raw);
    if (!inBuffer.open(QIODevice::ReadOnly)) return raw;
    QImageReader reader(&inBuffer);
    reader.setAutoTransform(true);
    const QSize source = reader.size();
    if (source.isValid() && (source.width() > 640 || source.height() > 640)) {
        reader.setScaledSize(source.scaled(640, 640, Qt::KeepAspectRatio));
    }
    const QImage image = reader.read();
    if (image.isNull()) return raw;
    QByteArray compressed;
    QBuffer outBuffer(&compressed);
    if (!outBuffer.open(QIODevice::WriteOnly)) return raw;
    QImageWriter writer(&outBuffer, "jpg");
    writer.setQuality(82);
    if (!writer.write(image) || compressed.isEmpty() || compressed.size() >= raw.size()) {
        return raw;
    }
    return compressed;
}

} // namespace

CoverImageLoader& CoverImageLoader::shared()
{
    static CoverImageLoader instance;
    return instance;
}

CoverImageLoader::CoverImageLoader(HTTPClient* client, QObject* parent)
    : QObject(parent)
    , m_ownedClient(client ? nullptr : std::make_unique<HTTPClient>(nullptr, false))
    , m_client(client ? client : m_ownedClient.get())
{
    QTimer::singleShot(0, this, [this] { pruneDiskCache(); });
}

CoverImageLoader::~CoverImageLoader() = default;

QString CoverImageLoader::sizedUrl(const QString& url, int decodeWidth)
{
    if (url.isEmpty()) return url;
    QUrl parsed(url);
    if (!parsed.isValid() || parsed.isLocalFile()) return url;
    const QString host = parsed.host().toLower();
    if (!host.endsWith(QLatin1String("music.126.net"))) return url;
    if (parsed.scheme().compare(QLatin1String("http"), Qt::CaseInsensitive) == 0) {
        parsed.setScheme(QStringLiteral("https"));
    }
    const int pixels = qBound(48, decodeWidth > 0 ? decodeWidth : 320, 640);
    QUrlQuery query(parsed);
    query.removeAllQueryItems(QStringLiteral("param"));
    query.addQueryItem(QStringLiteral("param"), QStringLiteral("%1y%1").arg(pixels));
    parsed.setQuery(query);
    return parsed.toString(QUrl::FullyEncoded);
}

QString CoverImageLoader::cacheRoot()
{
    return QDir(StoragePaths::root()).filePath(QStringLiteral("CoverCache"));
}

QString CoverImageLoader::diskCachePath(const QString& url)
{
    const QString hash = QString::fromLatin1(
        QCryptographicHash::hash(url.toUtf8(), QCryptographicHash::Sha256).toHex());
    return QDir(cacheRoot()).filePath(
        hash.left(2) + QLatin1Char('/') + hash + QStringLiteral(".img"));
}

std::optional<QImage> CoverImageLoader::peekMemory(const QString& url, int decodeWidth)
{
    if (url.isEmpty()) return std::nullopt;
    const QString effectiveUrl = sizedUrl(url, decodeWidth);
    const QString key = effectiveUrl + QLatin1Char('|') + QString::number(decodeWidth);
    return memoryLookup(key);
}

void CoverImageLoader::clearMemoryCache()
{
    m_memory.clear();
    m_lru.clear();
    m_memoryBytes = 0;
}

std::optional<QImage> CoverImageLoader::memoryLookup(const QString& key)
{
    auto it = m_memory.find(key);
    if (it == m_memory.end()) return std::nullopt;
    m_lru.removeOne(key);
    m_lru.prepend(key);
    return it->image;
}

void CoverImageLoader::insertIntoMemory(const QString& key, const QImage& image)
{
    const qint64 bytes = static_cast<qint64>(image.sizeInBytes());
    auto existing = m_memory.find(key);
    if (existing != m_memory.end()) {
        m_memoryBytes -= existing->bytes;
        m_lru.removeOne(key);
    }
    m_memory.insert(key, MemoryEntry{image, bytes});
    m_memoryBytes += bytes;
    m_lru.prepend(key);

    while (m_lru.size() > MemoryEntryLimit || m_memoryBytes > MemoryByteLimit) {
        if (m_lru.isEmpty()) break;
        const QString oldest = m_lru.takeLast();
        auto old = m_memory.find(oldest);
        if (old != m_memory.end()) {
            m_memoryBytes -= old->bytes;
            m_memory.erase(old);
        }
    }
    if (m_memoryBytes < 0) m_memoryBytes = 0;
}

Task<std::optional<QImage>> CoverImageLoader::load(
    const QString& url, int decodeWidth, CancellationToken ct)
{
    if (url.isEmpty() || ct.isCancellationRequested()) co_return std::optional<QImage>{};
    const QString effectiveUrl = sizedUrl(url, decodeWidth);
    const QString key = effectiveUrl + QLatin1Char('|') + QString::number(decodeWidth);

    if (auto cached = memoryLookup(key)) co_return cached;

    if (!m_pendingImages.contains(key)) {
        m_pendingImages.insert(key, QList<PendingWaiter>{});
        m_queuedImages.enqueue({key, effectiveUrl, decodeWidth});
        pumpQueue();
    }
    co_return co_await waitForImage(key, ct);
}

void CoverImageLoader::pumpQueue()
{
    while (m_activeLoads < MaxConcurrentLoads && !m_queuedImages.isEmpty()) {
        const ImageRequest request = m_queuedImages.dequeue();
        if (!m_pendingImages.contains(request.key)) {
            continue;
        }
        ++m_activeLoads;
        detach(loadCoreImage(request.key, request.url, request.width, CancellationToken::none()));
    }
}

Awaitable<std::optional<QImage>> CoverImageLoader::waitForImage(
    const QString& key, CancellationToken ct)
{
    return Awaitable<std::optional<QImage>>{[this, key, ct](Callback<std::optional<QImage>> callback) {
        auto it = m_pendingImages.find(key);
        if (it == m_pendingImages.end()) {
            callback(Result<std::optional<QImage>>::success(memoryLookup(key)));
            return;
        }
        if (ct.isCancellationRequested()) {
            if (it->isEmpty()) m_pendingImages.erase(it);
            callback(Result<std::optional<QImage>>::success(std::nullopt));
            return;
        }
        const int waiterId = ++m_nextWaiterId;
        PendingWaiter waiter;
        waiter.id = waiterId;
        waiter.token = ct;
        waiter.callback = std::move(callback);
        if (ct.canBeCancelled()) {
            waiter.cancelCallbackId = ct.registerCallback([this, key, waiterId] {
                auto pendingIt = m_pendingImages.find(key);
                if (pendingIt == m_pendingImages.end()) return;
                Callback<std::optional<QImage>> cancelledCb;
                for (int i = 0; i < pendingIt->size(); ++i) {
                    if ((*pendingIt)[i].id == waiterId) {
                        cancelledCb = std::move((*pendingIt)[i].callback);
                        pendingIt->removeAt(i);
                        break;
                    }
                }
                if (pendingIt->isEmpty()) {
                    // Only erase if still queued (not yet actively loading), or leave an empty list
                    // for active load unless we check m_queuedImages.
                    for (int i = 0; i < m_queuedImages.size(); ++i) {
                        if (m_queuedImages.at(i).key == key) {
                            m_queuedImages.removeAt(i);
                            m_pendingImages.erase(pendingIt);
                            break;
                        }
                    }
                }
                if (cancelledCb) {
                    cancelledCb(Result<std::optional<QImage>>::success(std::nullopt));
                }
            });
        }
        it->append(std::move(waiter));
    }};
}

Task<void> CoverImageLoader::loadCoreImage(
    QString key, QString url, int decodeWidth, CancellationToken ct)
{
    std::optional<QImage> result;
    try {
        auto bytes = co_await readBytes(url, ct);
        if (bytes && !bytes->isEmpty()) {
            QBuffer buffer(&*bytes);
            buffer.open(QIODevice::ReadOnly);
            QImageReader reader(&buffer);
            reader.setAutoTransform(true);
            const QSize source = reader.size();
            if (decodeWidth > 0 && source.isValid()
                && (source.width() > decodeWidth || source.height() > decodeWidth)) {
                reader.setScaledSize(QSize(decodeWidth,
                    qMax(1, qRound(static_cast<double>(source.height()) * decodeWidth / source.width()))));
            }
            QImage image = reader.read();
            if (!image.isNull()) {
                if (decodeWidth > 0 && image.width() > decodeWidth) {
                    image = image.scaledToWidth(decodeWidth, Qt::SmoothTransformation);
                }
                const QImage::Format targetFormat = image.hasAlphaChannel()
                    ? QImage::Format_ARGB32_Premultiplied
                    : QImage::Format_RGB32;
                if (image.format() != targetFormat) {
                    image = image.convertToFormat(targetFormat);
                }
                insertIntoMemory(key, image);
                result = image;
            }
        }
    } catch (const MusicException& error) {
        CTLog::general().debug(
            QStringLiteral("封面加载失败 %1: %2").arg(url, CTLog::sanitize(error.message())));
    } catch (const std::exception& error) {
        CTLog::general().debug(
            QStringLiteral("封面加载异常 %1: %2").arg(url, QString::fromUtf8(error.what())));
    } catch (...) {
        CTLog::general().debug(QStringLiteral("封面加载未知异常 %1").arg(url));
    }

    const QList<PendingWaiter> waiters = m_pendingImages.take(key);
    for (const PendingWaiter& waiter : waiters) {
        waiter.token.unregisterCallback(waiter.cancelCallbackId);
        if (waiter.callback) {
            waiter.callback(Result<std::optional<QImage>>::success(result));
        }
    }
    --m_activeLoads;
    QTimer::singleShot(0, this, [this] { pumpQueue(); });
}

Task<std::optional<QByteArray>> CoverImageLoader::loadBytes(const QString& url, CancellationToken ct)
{
    if (url.isEmpty()) co_return std::optional<QByteArray>{};
    try {
        co_return co_await readBytes(sizedUrl(url, 320), ct);
    } catch (...) {
        co_return std::optional<QByteArray>{};
    }
}

Task<std::optional<QByteArray>> CoverImageLoader::readBytes(const QString& url, CancellationToken ct)
{
    const QUrl parsed(url);
    if (parsed.isLocalFile()) {
        QFile local(parsed.toLocalFile());
        if (!local.open(QIODevice::ReadOnly)) co_return std::optional<QByteArray>{};
        const QByteArray bytes = local.readAll();
        if (bytes.isEmpty()) co_return std::optional<QByteArray>{};
        co_return bytes;
    }

    const QString cachePath = diskCachePath(url);
    {
        QFile cached(cachePath);
        if (cached.open(QIODevice::ReadOnly)) {
            const qint64 fileSize = cached.size();
            if (fileSize > 0 && fileSize <= MaxSingleDiskFileBytes) {
                const QByteArray bytes = cached.readAll();
                if (!bytes.isEmpty()) co_return std::optional<QByteArray>(bytes);
            } else if (fileSize > MaxSingleDiskFileBytes) {
                cached.close();
                QFile::remove(cachePath);
            }
        }
    }

    if (ct.isCancellationRequested()) throw MusicException::cancelled();

    const QHash<QString, QString> headers{{QStringLiteral("User-Agent"), userAgent()}};
    const HTTPResponse response = co_await m_client->get(parsed, headers, 12000, ct);
    if (response.statusCode < 200 || response.statusCode >= 300 || response.body.isEmpty()) {
        co_return std::optional<QByteArray>{};
    }

    const QByteArray bytes = compressLargeCoverBytes(response.body);
    QDir().mkpath(QFileInfo(cachePath).absolutePath());
    QSaveFile file(cachePath);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(bytes);
        file.commit();
    }
    if (++m_writesSincePrune >= 40) {
        m_writesSincePrune = 0;
        QTimer::singleShot(0, this, [this] { pruneDiskCache(); });
    }
    co_return bytes;
}

void CoverImageLoader::pruneDiskCache()
{
    const QString root = cacheRoot();
    if (!QDir(root).exists()) return;

    struct Entry {
        QString path;
        qint64 size = 0;
        QDateTime lastUsed;
    };

    QList<Entry> files;
    QDirIterator it(root, QDir::Files | QDir::Hidden | QDir::System, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        it.next();
        const QFileInfo info = it.fileInfo();
        const qint64 fileSize = info.size();
        if (fileSize > MaxSingleDiskFileBytes) {
            QFile::remove(info.absoluteFilePath());
            continue;
        }
        const QDateTime modified = info.lastModified();
        const QDateTime read = info.lastRead();
        Entry entry;
        entry.path = info.absoluteFilePath();
        entry.size = fileSize;
        entry.lastUsed = read.isValid() && read > modified ? read : modified;
        files.append(entry);
    }

    std::sort(files.begin(), files.end(), [](const Entry& a, const Entry& b) {
        return a.lastUsed < b.lastUsed;
    });

    qint64 total = 0;
    for (const Entry& entry : files) total += entry.size;

    const QDateTime now = QDateTime::currentDateTimeUtc();
    for (const Entry& entry : files) {
        const bool expired = !entry.lastUsed.isValid()
            || entry.lastUsed.secsTo(now) > static_cast<qint64>(DiskMaxAgeDays) * 24 * 3600;
        if (!expired && total <= DiskByteLimit) break;
        total -= entry.size;
        QFile::remove(entry.path);
    }
}

} // namespace ct
