#include "Playback/AudioCacheManager.h"

#include "Core/Logging/CTLog.h"
#include "Core/Models/JsonHelpers.h"
#include "Core/Models/ModelJson.h"
#include "Core/Models/MusicError.h"
#include "Core/Persistence/StoragePaths.h"
#include "Playback/AudioCacheRetentionPolicy.h"
#include "Playback/SongQuality.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QStorageInfo>
#include <QTimer>
#include <QUuid>

#include <algorithm>
#include <cmath>

namespace ct {

namespace {

const QString tempPrefix = QStringLiteral("tmp-");

QJsonObject metaToJson(const AudioCacheManager::CacheMeta& meta)
{
    QJsonObject object;
    object[QStringLiteral("formatName")] = meta.formatName;
    object[QStringLiteral("bitrateKbps")] = meta.bitrateKbps;
    object[QStringLiteral("fileExtension")] = meta.fileExtension;
    object[QStringLiteral("sizeBytes")] = static_cast<double>(meta.sizeBytes);
    object[QStringLiteral("cachedAt")] = json::dateTimeToJson(meta.cachedAt);
    if (meta.lastAccessedAt) object[QStringLiteral("lastAccessedAt")] = json::dateTimeToJson(*meta.lastAccessedAt);
    return object;
}

std::optional<AudioCacheManager::CacheMeta> metaFromJson(const QJsonValue& value)
{
    if (!value.isObject()) return std::nullopt;
    const QJsonObject object = value.toObject();
    AudioCacheManager::CacheMeta meta;
    meta.formatName = json::string(object.value(QStringLiteral("formatName")));
    meta.bitrateKbps = json::optionalInt(object.value(QStringLiteral("bitrateKbps"))).value_or(0);
    meta.fileExtension = json::string(object.value(QStringLiteral("fileExtension")));
    meta.sizeBytes = json::optionalLong(object.value(QStringLiteral("sizeBytes"))).value_or(0);
    meta.cachedAt = json::parseDateTime(object.value(QStringLiteral("cachedAt"))).value_or(QDateTime());
    if (const auto accessed = json::parseDateTime(object.value(QStringLiteral("lastAccessedAt")))) {
        meta.lastAccessedAt = *accessed;
    }
    return meta;
}

const QSet<QString>& cacheExtensionSet()
{
    static const QSet<QString> set = [] {
        QSet<QString> result;
        for (const QString& extension : AudioCacheManager::cacheFileExtensions()) {
            result.insert(extension.toLower());
        }
        return result;
    }();
    return set;
}

bool writeAtomicFile(const QString& path, const QByteArray& data)
{
    const QFileInfo info(path);
    QDir().mkpath(info.absolutePath());
    const QString temporary = path + QStringLiteral(".tmp");
    QFile file(temporary);
    if (!file.open(QIODevice::WriteOnly)) return false;
    if (file.write(data) != data.size()) {
        file.close();
        QFile::remove(temporary);
        return false;
    }
    file.close();
    QFile::remove(path);
    return QFile::rename(temporary, path);
}

} // namespace

const QStringList& AudioCacheManager::cacheFileExtensions()
{
    static const QStringList extensions = {
        QStringLiteral("mp3"),
        QStringLiteral("m4a"),
        QStringLiteral("aac"),
        QStringLiteral("flac"),
        QStringLiteral("opus"),
        QStringLiteral("wav"),
        QStringLiteral("aiff"),
    };
    return extensions;
}

AudioCacheManager& AudioCacheManager::shared()
{
    static AudioCacheManager* instance =
        new AudioCacheManager(QDir(StoragePaths::root()).filePath(QStringLiteral("AudioCache")));
    return *instance;
}

AudioCacheManager::AudioCacheManager(QString cacheDirectory)
    : m_cacheDirectory(std::move(cacheDirectory))
    , m_indexPath(QDir(m_cacheDirectory).filePath(QStringLiteral("index.json")))
    , m_network(new QNetworkAccessManager())
{
    m_indexFlushTimer = new QTimer();
    m_indexFlushTimer->setSingleShot(true);
    QObject::connect(m_indexFlushTimer, &QTimer::timeout, m_indexFlushTimer, [this] { persistIndex(); });
    QDir().mkpath(m_cacheDirectory);
    refreshIndex();
}

AudioCacheManager::~AudioCacheManager()
{
    delete m_indexFlushTimer;
    delete m_network;
}

qint64 AudioCacheManager::totalCacheBytes() const
{
    qint64 total = 0;
    for (auto it = m_index.constBegin(); it != m_index.constEnd(); ++it) total += it.value().sizeBytes;
    return total;
}

QString AudioCacheManager::formattedTotalSize() const
{
    return formatBytes(totalCacheBytes());
}

bool AudioCacheManager::isCacheFile(const QString& path)
{
    const QString name = QFileInfo(path).fileName();
    if (name.startsWith(tempPrefix)) return false;
    const QString extension = QFileInfo(name).suffix().toLower();
    return cacheExtensionSet().contains(extension);
}

QStringList AudioCacheManager::cacheClearDeletionTargets(
    const QStringList& paths, const std::optional<QString>& protectedSongID)
{
    if (!protectedSongID) return paths;
    QStringList targets;
    targets.reserve(paths.size());
    for (const QString& path : paths) {
        if (QFileInfo(path).completeBaseName() != *protectedSongID) targets.append(path);
    }
    return targets;
}

QString AudioCacheManager::extensionFor(
    const std::optional<QString>& contentType, const std::optional<QUrl>& sourceURL)
{
    if (contentType && !contentType->isEmpty()) {
        const QString mediaType = contentType->split(QLatin1Char(';')).first().trimmed().toLower();
        if (mediaType == QLatin1String("audio/mpeg") || mediaType == QLatin1String("audio/mp3"))
            return QStringLiteral("mp3");
        if (mediaType == QLatin1String("audio/mp4") || mediaType == QLatin1String("audio/x-m4a")
            || mediaType == QLatin1String("audio/m4a"))
            return QStringLiteral("m4a");
        if (mediaType == QLatin1String("audio/aac") || mediaType == QLatin1String("audio/aacp"))
            return QStringLiteral("aac");
        if (mediaType == QLatin1String("audio/flac") || mediaType == QLatin1String("audio/x-flac"))
            return QStringLiteral("flac");
        if (mediaType == QLatin1String("audio/opus")) return QStringLiteral("opus");
        if (mediaType == QLatin1String("audio/wav") || mediaType == QLatin1String("audio/x-wav")
            || mediaType == QLatin1String("audio/wave"))
            return QStringLiteral("wav");
        if (mediaType == QLatin1String("audio/aiff") || mediaType == QLatin1String("audio/x-aiff"))
            return QStringLiteral("aiff");
    }
    if (sourceURL) {
        const QString extension = QFileInfo(sourceURL->path()).suffix().toLower();
        if (cacheExtensionSet().contains(extension)) return extension;
    }
    return QStringLiteral("mp3");
}

QString AudioCacheManager::formatBytes(qint64 bytes)
{
    double value = static_cast<double>(qMax<qint64>(0, bytes));
    const QStringList units = {
        QStringLiteral("B"),
        QStringLiteral("KB"),
        QStringLiteral("MB"),
        QStringLiteral("GB"),
        QStringLiteral("TB"),
    };
    int unit = 0;
    while (value >= 1024.0 && unit < units.size() - 1) {
        value /= 1024.0;
        unit += 1;
    }
    if (unit == 0) return QStringLiteral("%1 B").arg(bytes);
    QString text = QString::number(value, 'f', 2);
    while (text.endsWith(QLatin1Char('0'))) text.chop(1);
    if (text.endsWith(QLatin1Char('.'))) text.chop(1);
    return QStringLiteral("%1 %2").arg(text, units[unit]);
}

std::optional<AudioCacheManager::CachedAudio> AudioCacheManager::cachedItem(const QString& songID)
{
    auto it = m_index.constFind(songID);
    if (it == m_index.constEnd()) return std::nullopt;
    if (audioCacheRetentionPolicy::isExpired(it->cachedAt)) return std::nullopt;
    const CacheMeta meta = it.value();
    const QString path = filePathFor(songID, meta);
    if (path.isEmpty() || !QFileInfo::exists(path)) return std::nullopt;
    touchAccess(songID);
    CachedAudio audio;
    audio.url = QUrl::fromLocalFile(path);
    audio.formatName = meta.formatName;
    audio.bitrateKbps = meta.bitrateKbps;
    return audio;
}

std::optional<AudioCacheManager::CacheMeta> AudioCacheManager::meta(const QString& songID) const
{
    auto it = m_index.constFind(songID);
    if (it == m_index.constEnd()) return std::nullopt;
    if (audioCacheRetentionPolicy::isExpired(it->cachedAt)) return std::nullopt;
    return it.value();
}

void AudioCacheManager::cacheInBackground(const QString& songID, const QUrl& sourceURL, double durationSeconds)
{
    if (!m_isEnabled || songID.isEmpty() || sourceURL.isLocalFile()) return;
    if (m_cachedSongIDs.contains(songID) || m_cachingSongIDs.contains(songID)) return;
    if (!hasSufficientDiskSpace()) {
        CTLog::general().warn(QStringLiteral("磁盘空间不足，跳过缓存: %1").arg(songID));
        return;
    }
    if (m_cachedSongIDs.contains(songID) || m_cachingSongIDs.contains(songID)) return;
    m_cachingSongIDs.insert(songID);
    PendingCache job;
    job.songID = songID;
    job.sourceURL = sourceURL;
    job.durationSeconds = durationSeconds;
    job.generation = m_clearGeneration;
    m_pending.enqueue(job);
    if (stateChanged) stateChanged();
    pumpCacheQueue();
}

void AudioCacheManager::clearAll()
{
    m_clearGeneration += 1;
    m_pending.clear();
    m_cachingSongIDs.clear();
    const std::optional<QString> protectedID = m_currentCachedSongID;
    if (protectedID && m_index.contains(*protectedID)) {
        const CacheMeta meta = m_index.value(*protectedID);
        m_index.clear();
        m_index.insert(*protectedID, meta);
        m_cachedSongIDs.clear();
        m_cachedSongIDs.insert(*protectedID);
    } else {
        m_index.clear();
        m_cachedSongIDs.clear();
    }
    QDir dir(m_cacheDirectory);
    QStringList files;
    if (dir.exists()) {
        const QStringList names = dir.entryList(QDir::Files | QDir::Hidden | QDir::System);
        for (const QString& name : names) files.append(dir.filePath(name));
    }
    for (const QString& file : cacheClearDeletionTargets(files, protectedID)) {
        QFile::remove(file);
    }
    persistIndex();
    if (stateChanged) stateChanged();
}

QString AudioCacheManager::filePathFor(const QString& songID, const CacheMeta& meta) const
{
    if (meta.fileExtension.isEmpty()) return QString();
    return QDir(m_cacheDirectory).filePath(songID + QLatin1Char('.') + meta.fileExtension);
}

void AudioCacheManager::refreshIndex()
{
    QHash<QString, CacheMeta> loaded;
    QFile indexFile(m_indexPath);
    if (indexFile.exists()) {
        if (indexFile.open(QIODevice::ReadOnly)) {
            const QJsonDocument document = QJsonDocument::fromJson(indexFile.readAll());
            if (document.isObject()) {
                const QJsonObject object = document.object();
                for (auto it = object.constBegin(); it != object.constEnd(); ++it) {
                    if (auto meta = metaFromJson(it.value())) loaded.insert(it.key(), *meta);
                }
            } else {
                CTLog::general().warn(QStringLiteral("读取音频缓存索引失败: 数据格式异常"));
            }
        } else {
            CTLog::general().warn(QStringLiteral("读取音频缓存索引失败: 无法打开文件"));
        }
    }

    QDir dir(m_cacheDirectory);
    const QStringList listing =
        dir.exists() ? dir.entryList(QDir::Files | QDir::Hidden | QDir::System) : QStringList();
    for (const QString& name : listing) {
        if (name.startsWith(tempPrefix)) QFile::remove(dir.filePath(name));
    }

    m_index.clear();
    for (auto it = loaded.constBegin(); it != loaded.constEnd(); ++it) m_index.insert(it.key(), it.value());

    QSet<QString> present;
    for (const QString& name : listing) {
        const QString file = dir.filePath(name);
        if (!isCacheFile(file)) continue;
        const QString id = QFileInfo(name).completeBaseName();
        if (id.isEmpty()) continue;
        present.insert(id);
        auto it = m_index.find(id);
        if (it != m_index.end()) {
            const QString indexedPath = filePathFor(id, it.value());
            if (!indexedPath.isEmpty() && QFileInfo::exists(indexedPath)) continue;
        }
        m_index.remove(id);
        CacheMeta meta;
        meta.formatName = QFileInfo(name).suffix().toUpper();
        meta.bitrateKbps = DefaultTargetBitrate / 1000;
        meta.fileExtension = QFileInfo(name).suffix().toLower();
        meta.sizeBytes = QFileInfo(file).size();
        meta.cachedAt = QDateTime::currentDateTimeUtc();
        m_index.insert(id, meta);
    }

    const QStringList keys = m_index.keys();
    for (const QString& key : keys) {
        if (!present.contains(key)) m_index.remove(key);
    }
    m_cachedSongIDs.clear();
    for (auto it = m_index.constBegin(); it != m_index.constEnd(); ++it) m_cachedSongIDs.insert(it.key());

    persistIndex();
    purgeExpired();
}

void AudioCacheManager::persistIndex()
{
    m_indexDirty = false;
    QJsonObject root;
    for (auto it = m_index.constBegin(); it != m_index.constEnd(); ++it) {
        root.insert(it.key(), metaToJson(it.value()));
    }
    const QByteArray data = QJsonDocument(root).toJson(QJsonDocument::Compact);
    if (!writeAtomicFile(m_indexPath, data)) {
        CTLog::general().warn(QStringLiteral("写入音频缓存索引失败"));
    }
}

void AudioCacheManager::persistIndexSoon()
{
    if (m_indexDirty) return;
    m_indexDirty = true;
    m_indexFlushTimer->start(indexFlushDelayMs);
}

void AudioCacheManager::pumpCacheQueue()
{
    if (m_isRunning || m_pending.isEmpty()) return;
    m_isRunning = true;
    const PendingCache job = m_pending.dequeue();
    downloadJob(job);
}

void AudioCacheManager::downloadJob(const PendingCache& job)
{
    const QString temp = QDir(m_cacheDirectory)
                             .filePath(tempPrefix + QUuid::createUuid().toString(QUuid::WithoutBraces));
    QNetworkRequest request(job.sourceURL);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(downloadTimeoutMs);
    QNetworkReply* reply = m_network->get(request);
    QObject::connect(reply, &QNetworkReply::finished, reply, [this, job, temp, reply] {
        reply->deleteLater();
        const int statusCode = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        // status 0 = 非 HTTP 协议（data:/qrc 等）；HTTP 请求仍必须是 2xx。
        const bool statusOk = statusCode == 0 ? true : (statusCode >= 200 && statusCode <= 299);
        if (reply->error() != QNetworkReply::NoError || !statusOk) {
            QFile::remove(temp);
            CTLog::general().warn(
                QStringLiteral("音频缓存失败 [%1]: %2")
                    .arg(job.songID, CTLog::sanitize(reply->errorString())));
            finishCacheJob(job);
            return;
        }
        QFile file(temp);
        if (!file.open(QIODevice::WriteOnly)) {
            QFile::remove(temp);
            CTLog::general().warn(QStringLiteral("音频缓存失败 [%1]: 无法写入临时文件").arg(job.songID));
            finishCacheJob(job);
            return;
        }
        const QByteArray payload = reply->readAll();
        const qint64 written = file.write(payload);
        file.close();
        if (written != payload.size()) {
            QFile::remove(temp);
            CTLog::general().warn(QStringLiteral("音频缓存失败 [%1]: 写入不完整").arg(job.songID));
            finishCacheJob(job);
            return;
        }
        const QString contentType = reply->header(QNetworkRequest::ContentTypeHeader).toString();
        const std::optional<QString> mediaType =
            contentType.isEmpty() ? std::nullopt : std::optional<QString>(contentType);
        const QString extension = extensionFor(mediaType, job.sourceURL);
        const QString destination =
            QDir(m_cacheDirectory).filePath(job.songID + QLatin1Char('.') + extension);
        if (QFile::exists(destination)) QFile::remove(destination);
        if (!QFile::rename(temp, destination)) {
            QFile::remove(temp);
            CTLog::general().warn(QStringLiteral("音频缓存失败 [%1]: 无法移动文件").arg(job.songID));
            finishCacheJob(job);
            return;
        }
        commitDownload(job, destination, extension.toUpper(), extension, QFileInfo(destination).size());
        finishCacheJob(job);
    });
}

void AudioCacheManager::commitDownload(const PendingCache& job, const QString& path, const QString& formatName,
    const QString& extension, qint64 sizeBytes)
{
    if (job.generation != m_clearGeneration) {
        QFile::remove(path);
        CTLog::general().info(QStringLiteral("丢弃已过期的缓存结果: %1").arg(job.songID));
        return;
    }
    CacheMeta meta;
    meta.formatName = formatName;
    meta.bitrateKbps = job.durationSeconds > 0
        ? songQualityPolicy::derivedBitrateKbps(sizeBytes, job.durationSeconds).value_or(DefaultTargetBitrate / 1000)
        : DefaultTargetBitrate / 1000;
    meta.fileExtension = extension;
    meta.sizeBytes = sizeBytes;
    meta.cachedAt = QDateTime::currentDateTimeUtc();
    meta.lastAccessedAt = meta.cachedAt;
    m_index[job.songID] = meta;
    m_cachedSongIDs.insert(job.songID);
    persistIndexSoon();
    purgeExpired();
    trimIfNeeded();
    CTLog::general().info(QStringLiteral("音频缓存完成: %1 %2 %3kbps (%4 bytes)")
                              .arg(job.songID, meta.formatName)
                              .arg(meta.bitrateKbps)
                              .arg(meta.sizeBytes));
}

void AudioCacheManager::finishCacheJob(const PendingCache& job)
{
    m_cachingSongIDs.remove(job.songID);
    m_isRunning = false;
    if (stateChanged) stateChanged();
    pumpCacheQueue();
}

void AudioCacheManager::touchAccess(const QString& songID)
{
    auto it = m_index.find(songID);
    if (it == m_index.end()) return;
    const QDateTime now = QDateTime::currentDateTimeUtc();
    const QDateTime last = it->lastAccessedAt.value_or(it->cachedAt);
    if (last.msecsTo(now) < accessTouchIntervalMs) return;
    it->lastAccessedAt = now;
    persistIndexSoon();
}

int AudioCacheManager::purgeExpired()
{
    QHash<QString, QDateTime> cachedAtByID;
    for (auto it = m_index.constBegin(); it != m_index.constEnd(); ++it) {
        cachedAtByID.insert(it.key(), it.value().cachedAt);
    }
    const QSet<QString> expired = audioCacheRetentionPolicy::expiredIDs(cachedAtByID);
    if (expired.isEmpty()) return 0;

    int removed = 0;
    for (const QString& songID : expired) {
        if (m_currentCachedSongID && songID == *m_currentCachedSongID) continue;
        auto it = m_index.constFind(songID);
        const QString path = it != m_index.constEnd() ? filePathFor(songID, it.value()) : QString();
        if (!path.isEmpty()) QFile::remove(path);
        if (m_index.remove(songID)) {
            m_cachedSongIDs.remove(songID);
            removed += 1;
        }
    }
    persistIndex();
    CTLog::general().info(QStringLiteral("音频缓存过期清理: %1 条超过 %2 天")
                              .arg(expired.size())
                              .arg(audioCacheRetentionPolicy::maxAgeSeconds / (24 * 60 * 60)));
    return removed;
}

void AudioCacheManager::trimIfNeeded()
{
    if (totalCacheBytes() <= maxCacheBytes) return;

    struct Entry {
        QString id;
        QString path;
        QDateTime sortKey;
    };
    QList<Entry> entries;
    QDir dir(m_cacheDirectory);
    const QStringList names = dir.entryList(QDir::Files);
    for (const QString& name : names) {
        const QString file = dir.filePath(name);
        if (!isCacheFile(file)) continue;
        const QString id = QFileInfo(name).completeBaseName();
        auto it = m_index.constFind(id);
        if (it == m_index.constEnd()) continue;
        entries.append({id, file, it->lastAccessedAt.value_or(it->cachedAt)});
    }
    std::stable_sort(entries.begin(), entries.end(),
        [](const Entry& left, const Entry& right) { return left.sortKey < right.sortKey; });

    bool changed = false;
    for (const Entry& entry : entries) {
        if (totalCacheBytes() <= maxCacheBytes) break;
        if (m_currentCachedSongID && entry.id == *m_currentCachedSongID) continue;
        QFile::remove(entry.path);
        if (m_index.remove(entry.id)) {
            m_cachedSongIDs.remove(entry.id);
            changed = true;
        }
    }
    if (changed) persistIndex();
}

bool AudioCacheManager::hasSufficientDiskSpace() const
{
    QStorageInfo storage(m_cacheDirectory);
    if (!storage.isValid() || !storage.isReady()) return true;
    return storage.bytesAvailable() > requiredFreeBytes;
}

} // namespace ct
