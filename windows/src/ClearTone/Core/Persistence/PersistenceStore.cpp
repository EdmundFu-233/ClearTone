#include "Core/Persistence/PersistenceStore.h"

#include "Core/Logging/CTLog.h"
#include "Core/Models/JsonHelpers.h"
#include "Core/Models/ModelJson.h"
#include "Core/Persistence/StoragePaths.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>

#include <stdexcept>

namespace ct {

namespace {

const QString settingsPrefix = QStringLiteral("cleartone.persisted.settings");

QJsonArray songsToJson(const QList<Song>& songs)
{
    QJsonArray array;
    for (const Song& song : songs) array.append(toJson(song));
    return array;
}

QList<Song> songsFromJson(const QJsonValue& value)
{
    QList<Song> songs;
    const QJsonArray array = json::array(value);
    for (const QJsonValue& entry : array) {
        if (auto song = songFromJson(entry)) songs.append(std::move(*song));
    }
    return songs;
}

QJsonArray playlistsToJson(const QList<Playlist>& playlists)
{
    QJsonArray array;
    for (const Playlist& playlist : playlists) array.append(toJson(playlist));
    return array;
}

QList<Playlist> playlistsFromJson(const QJsonValue& value)
{
    QList<Playlist> playlists;
    const QJsonArray array = json::array(value);
    for (const QJsonValue& entry : array) {
        if (auto playlist = playlistFromJson(entry)) playlists.append(std::move(*playlist));
    }
    return playlists;
}

QJsonArray stringsToJson(const QStringList& strings)
{
    QJsonArray array;
    for (const QString& value : strings) array.append(value);
    return array;
}

QStringList stringsFromJson(const QJsonValue& value)
{
    QStringList strings;
    const QJsonArray array = json::array(value);
    for (const QJsonValue& entry : array) {
        if (entry.isString()) strings.append(entry.toString());
    }
    return strings;
}

bool writeAtomic(const QString& path, const QByteArray& data)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    const QString temporary = path + QStringLiteral(".tmp");
    QFile file(temporary);
    if (!file.open(QIODevice::WriteOnly)) return false;
    if (file.write(data) != data.size()) {
        file.close();
        return false;
    }
    file.close();
    QFile::remove(path);
    return QFile::rename(temporary, path);
}

} // namespace

PersistenceStore& PersistenceStore::shared()
{
    static PersistenceStore store;
    return store;
}

PersistenceStore::PersistenceStore()
{
    QDir().mkpath(storageRoot());
    purgeOrphanedDemoAudio();
}

QString PersistenceStore::storageRoot() const { return StoragePaths::root(); }

QString PersistenceStore::queuePath() const
{
    return QDir(storageRoot()).filePath(QStringLiteral("queue.json"));
}

QString PersistenceStore::settingsPath() const
{
    return QDir(storageRoot()).filePath(QStringLiteral("settings.json"));
}

void PersistenceStore::purgeOrphanedDemoAudio()
{
    const QString dir = QDir(storageRoot()).filePath(QStringLiteral("DemoAudio"));
    if (!QDir(dir).exists()) return;
    if (QDir(dir).removeRecursively()) {
        CTLog::general().info(QStringLiteral("已清理演示模式遗留的音频目录"));
    } else {
        CTLog::general().error(QStringLiteral("清理演示音频目录失败"));
    }
}

bool PersistenceStore::isNotLegacyDemoSong(const Song& song)
{
    return !song.id.startsWith(QLatin1String("demo-"));
}

void PersistenceStore::saveQueue(const PersistedQueue& queue)
{
    const QByteArray data = QJsonDocument(toJson(queue)).toJson(QJsonDocument::Compact);
    if (!writeAtomic(queuePath(), data)) {
        CTLog::general().error(QStringLiteral("保存队列失败"));
    }
}

std::optional<PersistedQueue> PersistenceStore::loadQueue()
{
    QFile file(queuePath());
    if (!file.exists() || !file.open(QIODevice::ReadOnly)) return std::nullopt;
    const QJsonDocument document = QJsonDocument::fromJson(file.readAll());
    if (!document.isObject()) return std::nullopt;
    auto queue = persistedQueueFromJson(document.object());
    if (!queue) return std::nullopt;
    QList<QueueItem> filtered;
    for (const QueueItem& item : std::as_const(queue->items)) {
        if (isNotLegacyDemoSong(item.song)) filtered.append(item);
    }
    queue->items = filtered;
    return queue;
}

void PersistenceStore::clearQueue()
{
    QFile::remove(queuePath());
    PersistenceWriter::shared().reset();
}

QJsonObject& PersistenceStore::settingsFile()
{
    if (m_settingsLoaded) return m_settingsCache;
    m_settingsLoaded = true;
    QFile file(settingsPath());
    if (file.exists() && file.open(QIODevice::ReadOnly)) {
        const QJsonDocument document = QJsonDocument::fromJson(file.readAll());
        if (document.isObject()) m_settingsCache = document.object();
    }
    return m_settingsCache;
}

void PersistenceStore::persistSettingsFile()
{
    const QByteArray data = QJsonDocument(m_settingsCache).toJson(QJsonDocument::Compact);
    if (!writeAtomic(settingsPath(), data)) {
        CTLog::general().error(QStringLiteral("写入设置文件失败"));
    }
}

void PersistenceStore::saveSetting(const QString& key, const QJsonValue& value)
{
    auto& settings = settingsFile();
    settings[key] = value;
    persistSettingsFile();
}

QJsonValue PersistenceStore::loadSetting(const QString& key)
{
    const auto& settings = settingsFile();
    const auto iterator = settings.constFind(key);
    if (iterator == settings.constEnd()) return QJsonValue(QJsonValue::Undefined);
    return *iterator;
}

void PersistenceStore::removeSetting(const QString& key)
{
    auto& settings = settingsFile();
    if (settings.contains(key)) {
        settings.remove(key);
        persistSettingsFile();
    }
}

QString PersistenceStore::settingKeyFor(const QString& key) const
{
    return settingsPrefix + QLatin1Char('.') + key;
}

void PersistenceStore::saveCachedAccount(const AccountInfo& account)
{
    saveSetting(QStringLiteral("cachedAccount"), toJson(account));
}

std::optional<AccountInfo> PersistenceStore::loadCachedAccount()
{
    return accountFromJson(loadSetting(QStringLiteral("cachedAccount")));
}

void PersistenceStore::clearCachedAccount()
{
    removeSetting(QStringLiteral("cachedAccount"));
}

void PersistenceStore::saveCachedLikedSongs(const QList<Song>& songs)
{
    saveSetting(QStringLiteral("cachedLikedSongs"), songsToJson(songs));
}

QList<Song> PersistenceStore::loadCachedLikedSongs()
{
    QList<Song> songs = songsFromJson(loadSetting(QStringLiteral("cachedLikedSongs")));
    QList<Song> filtered;
    for (const Song& song : std::as_const(songs)) {
        if (isNotLegacyDemoSong(song)) filtered.append(song);
    }
    return filtered;
}

void PersistenceStore::saveCachedLikedSongIDs(const QStringList& ids)
{
    saveSetting(QStringLiteral("cachedLikedSongIDs"), stringsToJson(ids));
}

QStringList PersistenceStore::loadCachedLikedSongIDs()
{
    return stringsFromJson(loadSetting(QStringLiteral("cachedLikedSongIDs")));
}

void PersistenceStore::clearCachedLikedSongs()
{
    removeSetting(QStringLiteral("cachedLikedSongs"));
    removeSetting(QStringLiteral("cachedLikedSongIDs"));
}

void PersistenceStore::saveCachedUserPlaylists(const QList<Playlist>& playlists)
{
    saveSetting(QStringLiteral("cachedUserPlaylists"), playlistsToJson(playlists));
}

QList<Playlist> PersistenceStore::loadCachedUserPlaylists()
{
    return playlistsFromJson(loadSetting(QStringLiteral("cachedUserPlaylists")));
}

void PersistenceStore::clearCachedUserPlaylists()
{
    removeSetting(QStringLiteral("cachedUserPlaylists"));
}

void PersistenceStore::saveLocalLibrary(const QStringList& paths)
{
    saveSetting(QStringLiteral("localLibrary"), stringsToJson(paths));
}

QStringList PersistenceStore::loadLocalLibrary()
{
    return stringsFromJson(loadSetting(QStringLiteral("localLibrary")));
}

void PersistenceStore::saveRecentSongs(const QList<Song>& songs)
{
    saveSetting(QStringLiteral("recentSongs"), songsToJson(songs));
}

QList<Song> PersistenceStore::loadRecentSongs()
{
    QList<Song> songs = songsFromJson(loadSetting(QStringLiteral("recentSongs")));
    QList<Song> filtered;
    for (const Song& song : std::as_const(songs)) {
        if (isNotLegacyDemoSong(song)) filtered.append(song);
    }
    return filtered;
}

PersistenceWriter& PersistenceWriter::shared()
{
    static PersistenceWriter* instance = new PersistenceWriter();
    return *instance;
}

PersistenceWriter::PersistenceWriter(QObject* parent)
    : QObject(parent)
{
    m_flushTimer = new QTimer(this);
    m_flushTimer->setSingleShot(true);
    connect(m_flushTimer, &QTimer::timeout, this, [this] { writePending(); });
}

void PersistenceWriter::schedule(const PersistedQueue& queue)
{
    m_pendingQueue = queue;
    scheduleFlushLocked();
}

void PersistenceWriter::scheduleRecent(const QList<Song>& songs)
{
    m_pendingRecent = songs;
    scheduleFlushLocked();
}

void PersistenceWriter::flushNow()
{
    m_flushTimer->stop();
    writePending();
}

void PersistenceWriter::persistAndFlush(
    const std::optional<PersistedQueue>& queue, const std::optional<QList<Song>>& recent)
{
    if (queue) m_pendingQueue = queue;
    if (recent) m_pendingRecent = recent;
    flushNow();
}

void PersistenceWriter::reset()
{
    m_flushTimer->stop();
    m_pendingQueue.reset();
    m_pendingRecent.reset();
    m_consecutiveWriteFailures = 0;
}

void PersistenceWriter::scheduleFlushLocked()
{
    if (m_flushTimer->isActive()) return;
    m_flushTimer->start(debounceMs);
}

void PersistenceWriter::writePending()
{
    auto queue = m_pendingQueue;
    auto recent = m_pendingRecent;
    m_pendingQueue.reset();
    m_pendingRecent.reset();

    bool firstError = false;
    if (queue) {
        try {
            writeQueueSnapshot(*queue);
        } catch (const std::exception& error) {
            CTLog::general().warn(QStringLiteral("写入队列失败: %1").arg(QString::fromUtf8(error.what())));
            m_pendingQueue = queue;
            firstError = true;
        }
    }
    if (recent) {
        try {
            writeRecentSnapshot(*recent);
        } catch (const std::exception& error) {
            CTLog::general().warn(QStringLiteral("写入最近播放失败: %1").arg(QString::fromUtf8(error.what())));
            m_pendingRecent = recent;
            firstError = true;
        }
    }

    if (firstError) {
        m_consecutiveWriteFailures += 1;
        const bool hasPending = m_pendingQueue.has_value() || m_pendingRecent.has_value();
        if (m_consecutiveWriteFailures <= maxAutoRetries && hasPending) {
            scheduleFlushLocked();
        }
    } else {
        m_consecutiveWriteFailures = 0;
    }
}

void PersistenceWriter::writeQueueSnapshot(const PersistedQueue& queue)
{
    if (queueWriteOverride) {
        queueWriteOverride(queue);
        return;
    }
    const QByteArray data = QJsonDocument(toJson(queue)).toJson(QJsonDocument::Compact);
    if (data.size() > maxBytes) {
        CTLog::general().warn(
            QStringLiteral("队列快照 %1 字节超过上限 %2，跳过落盘").arg(data.size()).arg(maxBytes));
        return;
    }
    if (!writeAtomic(PersistenceStore::shared().storageRoot() + QStringLiteral("/queue.json"), data)) {
        throw std::runtime_error("write queue failed");
    }
}

void PersistenceWriter::writeRecentSnapshot(const QList<Song>& recent)
{
    if (recentWriteOverride) {
        recentWriteOverride(recent);
        return;
    }
    QJsonArray array;
    for (const Song& song : recent) array.append(toJson(song));
    const QByteArray data = QJsonDocument(array).toJson(QJsonDocument::Compact);
    if (data.size() > maxBytes) {
        CTLog::general().warn(
            QStringLiteral("最近播放快照 %1 字节超过上限 %2，跳过落盘").arg(data.size()).arg(maxBytes));
        return;
    }
    PersistenceStore::shared().saveRecentSongs(recent);
}

} // namespace ct
