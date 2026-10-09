#include "DesignSystem/CoverImageLoader.h"

#include "Core/Logging/CTLog.h"
#include "Core/Networking/HTTPClient.h"
#include "Core/Persistence/StoragePaths.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <QTimer>
#include <QUrl>

#include <algorithm>

namespace ct {

namespace {

const QString& userAgent()
{
    static const QString agent = QStringLiteral(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36");
    return agent;
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
    const qint64 bytes = static_cast<qint64>(image.width()) * image.height() * 4;
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
    if (url.isEmpty()) co_return std::optional<QImage>{};
    const QString key = url + QLatin1Char('|') + QString::number(decodeWidth);

    if (auto cached = memoryLookup(key)) co_return cached;

    if (!m_pendingImages.contains(key)) {
        m_pendingImages.insert(key, QList<Callback<std::optional<QImage>>>{});
        detach(loadCoreImage(key, url, decodeWidth, ct));
    }
    co_return co_await waitForImage(key);
}

Awaitable<std::optional<QImage>> CoverImageLoader::waitForImage(const QString& key)
{
    return Awaitable<std::optional<QImage>>{[this, key](Callback<std::optional<QImage>> callback) {
        auto it = m_pendingImages.find(key);
        if (it == m_pendingImages.end()) {
            // 核心加载已在同步路径上完成（磁盘命中 / 立即失败），直接读内存结果。
            callback(Result<std::optional<QImage>>::success(memoryLookup(key)));
            return;
        }
        it->append(std::move(callback));
    }};
}

Task<void> CoverImageLoader::loadCoreImage(
    QString key, QString url, int decodeWidth, CancellationToken ct)
{
    std::optional<QImage> result;
    try {
        auto bytes = co_await readBytes(url, ct);
        if (bytes && !bytes->isEmpty()) {
            QImage image;
            if (image.loadFromData(*bytes)) {
                if (decodeWidth > 0 && image.width() != decodeWidth) {
                    image = image.scaledToWidth(decodeWidth, Qt::SmoothTransformation);
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

    const QList<Callback<std::optional<QImage>>> callbacks = m_pendingImages.take(key);
    for (const auto& callback : callbacks) {
        callback(Result<std::optional<QImage>>::success(result));
    }
}

Task<std::optional<QByteArray>> CoverImageLoader::loadBytes(const QString& url, CancellationToken ct)
{
    if (url.isEmpty()) co_return std::optional<QByteArray>{};
    try {
        co_return co_await readBytes(url, ct);
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
            const QByteArray bytes = cached.readAll();
            if (!bytes.isEmpty()) co_return std::optional<QByteArray>(bytes);
        }
    }

    if (ct.isCancellationRequested()) throw MusicException::cancelled();

    const QHash<QString, QString> headers{{QStringLiteral("User-Agent"), userAgent()}};
    const HTTPResponse response = co_await m_client->get(parsed, headers, 20000, ct);
    if (response.statusCode < 200 || response.statusCode >= 300 || response.body.isEmpty()) {
        co_return std::optional<QByteArray>{};
    }

    const QByteArray bytes = response.body;
    QDir().mkpath(QFileInfo(cachePath).absolutePath());
    QSaveFile file(cachePath);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(bytes);
        file.commit();
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
        const QDateTime modified = info.lastModified();
        const QDateTime read = info.lastRead();
        Entry entry;
        entry.path = info.absoluteFilePath();
        entry.size = info.size();
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
