#include <QtTest>

#include "Playback/AudioCacheManager.h"
#include "Playback/AudioCacheRetentionPolicy.h"
#include "TestSupport.h"

#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QUrl>

using namespace ct;
using namespace ct::tests;

namespace {

using CacheMeta = AudioCacheManager::CacheMeta;

constexpr qint64 mb = 1024LL * 1024LL;

QUrl probeURL()
{
    return QUrl(QStringLiteral("data:audio/mpeg;base64,")
        + QString::fromLatin1(QByteArray("ct-probe").toBase64()));
}

QString writeCacheFile(const QString& directory, const QString& fileName,
    const QByteArray& contents = QByteArray("ct-data"))
{
    const QString path = QDir(directory).filePath(fileName);
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly)) return QString();
    file.write(contents);
    file.close();
    return path;
}

void writeIndex(const QString& directory, const QHash<QString, CacheMeta>& metas)
{
    QJsonObject root;
    for (auto iterator = metas.constBegin(); iterator != metas.constEnd(); ++iterator) {
        const CacheMeta& meta = iterator.value();
        QJsonObject object;
        object[QStringLiteral("formatName")] = meta.formatName;
        object[QStringLiteral("bitrateKbps")] = meta.bitrateKbps;
        object[QStringLiteral("fileExtension")] = meta.fileExtension;
        object[QStringLiteral("sizeBytes")] = static_cast<double>(meta.sizeBytes);
        object[QStringLiteral("cachedAt")] = meta.cachedAt.toString(Qt::ISODateWithMs);
        if (meta.lastAccessedAt) {
            object[QStringLiteral("lastAccessedAt")] =
                meta.lastAccessedAt->toString(Qt::ISODateWithMs);
        }
        root.insert(iterator.key(), object);
    }
    QFile file(QDir(directory).filePath(QStringLiteral("index.json")));
    if (!file.open(QIODevice::WriteOnly)) return;
    file.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
    file.close();
}

CacheMeta fakeMeta(qint64 sizeBytes, const QDateTime& cachedAt,
    const std::optional<QDateTime>& lastAccessedAt = std::nullopt)
{
    CacheMeta meta;
    meta.formatName = QStringLiteral("MP3");
    meta.bitrateKbps = 128;
    meta.fileExtension = QStringLiteral("mp3");
    meta.sizeBytes = sizeBytes;
    meta.cachedAt = cachedAt;
    meta.lastAccessedAt = lastAccessedAt;
    return meta;
}

// 通过一次真实下载（data: URL）触发 commitDownload -> purgeExpired/trimIfNeeded。
bool triggerCacheCommit(AudioCacheManager& manager, const QString& songID)
{
    manager.cacheInBackground(songID, probeURL(), 0);
    if (!until([&] { return !manager.cachingSongIDs().contains(songID); })) return false;
    return manager.cachedSongIDs().contains(songID);
}

// C# 测试里的 Store 复刻：sweep 的过期选择用生产策略，保护分支在这里复刻
// （真实的 purgeExpired 只在构造与下载完成时触发，构造时还无法设置当前播放）。
struct SweepReplica {
    QHash<QString, QDateTime> index;
    std::optional<QString> currentCachedSongID;

    QSet<QString> purgeExpired(const QDateTime& now)
    {
        const QSet<QString> expired = audioCacheRetentionPolicy::expiredIDs(
            index, now, audioCacheRetentionPolicy::maxAge());
        QSet<QString> removed;
        for (const QString& id : expired) {
            if (currentCachedSongID && id == *currentCachedSongID) continue;
            if (index.remove(id) > 0) removed.insert(id);
        }
        return removed;
    }
};

} // namespace

class AudioCachePolicyTests : public QObject {
    Q_OBJECT

private slots:
    void testEvictionUsesLastAccessedNotCachedAt();
    void testFallsBackToCachedAtWhenNeverAccessed();
    void testTrimDeletesOldestUntilUnderLimit();
    void testTrimNeverDeletesCurrentlyPlayingCache();
    void testClearGenerationInvalidatesInFlightResults();
    void testInFlightResultCommitsWhenNoClearHappened();
    void testTempFilesAreNotIndexedOrCounted();
    void testCacheFileFilterFollowsPlatformExtension();
    void testIndexRecoversEntriesForOrphanFiles();
    void testRecoveredOrphanStartsFreshForRetention();
    void testTargetBitrateIs128kbps();
    void testRetentionIsExactlySevenDays();
    void testExpiryIsMeasuredFromCachedAtNotLastAccess();
    void testFutureTimestampIsNotExpired();
    void testExpiredIDsSelectsOnlyOverdueEntries();
    void testExpirySweepRunsEvenWhenUnderCapacity();
    void testExpirySweepProtectsCurrentlyPlayingFile();
    void testCapacityEvictionStillAppliesToUnexpiredEntries();
    void testClearAllKeepsCurrentlyPlayingFile();
};

void AudioCachePolicyTests::testEvictionUsesLastAccessedNotCachedAt()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QDateTime t0 = QDateTime::currentDateTimeUtc().addSecs(-5000);

    writeCacheFile(directory.path(), QStringLiteral("old-but-favorite.mp3"));
    writeCacheFile(directory.path(), QStringLiteral("mid.mp3"));
    writeCacheFile(directory.path(), QStringLiteral("newest.mp3"));
    QHash<QString, CacheMeta> index;
    index[QStringLiteral("old-but-favorite")] =
        fakeMeta(600 * mb, t0, t0.addSecs(4000));
    index[QStringLiteral("mid")] = fakeMeta(600 * mb, t0.addSecs(10), t0.addSecs(10));
    index[QStringLiteral("newest")] = fakeMeta(600 * mb, t0.addSecs(20), t0.addSecs(20));
    writeIndex(directory.path(), index);

    AudioCacheManager manager(directory.path());
    QCOMPARE(manager.cachedSongIDs().size(), 3);
    QVERIFY(triggerCacheCommit(manager, QStringLiteral("trigger")));

    QVERIFY(!manager.cachedSongIDs().contains(QStringLiteral("mid")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("old-but-favorite")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("newest")));
    QVERIFY(QFile::exists(QDir(directory.path()).filePath(QStringLiteral("old-but-favorite.mp3"))));
    QVERIFY(!QFile::exists(QDir(directory.path()).filePath(QStringLiteral("mid.mp3"))));
}

void AudioCachePolicyTests::testFallsBackToCachedAtWhenNeverAccessed()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QDateTime t0 = QDateTime::currentDateTimeUtc().addSecs(-6000);

    writeCacheFile(directory.path(), QStringLiteral("a.mp3"));
    writeCacheFile(directory.path(), QStringLiteral("b.mp3"));
    writeCacheFile(directory.path(), QStringLiteral("c.mp3"));
    QHash<QString, CacheMeta> index;
    index[QStringLiteral("a")] = fakeMeta(500 * mb, t0);
    index[QStringLiteral("b")] = fakeMeta(500 * mb, t0.addSecs(5));
    index[QStringLiteral("c")] = fakeMeta(500 * mb, t0.addSecs(10));
    writeIndex(directory.path(), index);

    AudioCacheManager manager(directory.path());
    QVERIFY(triggerCacheCommit(manager, QStringLiteral("trigger")));

    QVERIFY(!manager.cachedSongIDs().contains(QStringLiteral("a")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("b")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("c")));
}

void AudioCachePolicyTests::testTrimDeletesOldestUntilUnderLimit()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QDateTime t0 = QDateTime::currentDateTimeUtc().addSecs(-6000);

    QHash<QString, CacheMeta> index;
    for (int position = 0; position < 5; ++position) {
        const QString id = QStringLiteral("s%1").arg(position);
        writeCacheFile(directory.path(), id + QStringLiteral(".mp3"));
        index[id] = fakeMeta(400 * mb, t0.addSecs(position));
    }
    writeIndex(directory.path(), index);

    AudioCacheManager manager(directory.path());
    QCOMPARE(manager.cachedSongIDs().size(), 5);
    QVERIFY(triggerCacheCommit(manager, QStringLiteral("trigger")));

    QVERIFY(!manager.cachedSongIDs().contains(QStringLiteral("s0")));
    QVERIFY(!manager.cachedSongIDs().contains(QStringLiteral("s1")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("s2")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("s3")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("s4")));
}

void AudioCachePolicyTests::testTrimNeverDeletesCurrentlyPlayingCache()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QDateTime t0 = QDateTime::currentDateTimeUtc().addSecs(-6000);

    QHash<QString, CacheMeta> index;
    index[QStringLiteral("playing")] = fakeMeta(400 * mb, t0);
    index[QStringLiteral("x")] = fakeMeta(400 * mb, t0.addSecs(1));
    index[QStringLiteral("y")] = fakeMeta(400 * mb, t0.addSecs(2));
    index[QStringLiteral("z")] = fakeMeta(400 * mb, t0.addSecs(3));
    for (auto iterator = index.constBegin(); iterator != index.constEnd(); ++iterator) {
        writeCacheFile(directory.path(), iterator.key() + QStringLiteral(".mp3"));
    }
    writeIndex(directory.path(), index);

    AudioCacheManager manager(directory.path());
    manager.setCurrentCachedSong(QStringLiteral("playing"));
    QVERIFY(triggerCacheCommit(manager, QStringLiteral("trigger")));

    QVERIFY(!manager.cachedSongIDs().contains(QStringLiteral("x")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("playing")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("y")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("z")));
    QVERIFY(QFile::exists(QDir(directory.path()).filePath(QStringLiteral("playing.mp3"))));
}

void AudioCachePolicyTests::testClearGenerationInvalidatesInFlightResults()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    AudioCacheManager manager(directory.path());

    manager.cacheInBackground(QStringLiteral("gen-song"), probeURL(), 0);
    manager.clearAll();
    QTest::qWait(200);

    QVERIFY(!manager.cachedSongIDs().contains(QStringLiteral("gen-song")));
    const QStringList leftovers =
        QDir(directory.path()).entryList(QStringList{QStringLiteral("gen-song.*")}, QDir::Files);
    QVERIFY(leftovers.isEmpty());
}

void AudioCachePolicyTests::testInFlightResultCommitsWhenNoClearHappened()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    AudioCacheManager manager(directory.path());

    QVERIFY(triggerCacheCommit(manager, QStringLiteral("ok-song")));

    const auto meta = manager.meta(QStringLiteral("ok-song"));
    QVERIFY(meta.has_value());
    QCOMPARE(meta->formatName, QStringLiteral("MP3"));
    QCOMPARE(meta->fileExtension, QStringLiteral("mp3"));
    QCOMPARE(meta->bitrateKbps, 128);
    QVERIFY(QFile::exists(QDir(directory.path()).filePath(QStringLiteral("ok-song.mp3"))));
}

void AudioCachePolicyTests::testTempFilesAreNotIndexedOrCounted()
{
    QVERIFY(!AudioCacheManager::isCacheFile(QStringLiteral("/cache/tmp-ABC.mp3")));
    QVERIFY(AudioCacheManager::isCacheFile(QStringLiteral("/cache/12345.mp3")));
    QVERIFY(!AudioCacheManager::isCacheFile(QStringLiteral("/cache/index.json")));

    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    writeCacheFile(directory.path(), QStringLiteral("tmp-ABC.mp3"));
    writeCacheFile(directory.path(), QStringLiteral("67890.mp3"));

    AudioCacheManager manager(directory.path());

    QVERIFY(!QFile::exists(QDir(directory.path()).filePath(QStringLiteral("tmp-ABC.mp3"))));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("67890")));
    QVERIFY(!manager.cachedSongIDs().contains(QStringLiteral("tmp-ABC")));
}

void AudioCachePolicyTests::testCacheFileFilterFollowsPlatformExtension()
{
    for (const QString& extension : AudioCacheManager::cacheFileExtensions()) {
        QVERIFY2(AudioCacheManager::isCacheFile(QStringLiteral("/cache/12345.") + extension),
            qPrintable(extension));
    }
    QVERIFY(AudioCacheManager::isCacheFile(QStringLiteral("/cache/12345.m4a")));
    QVERIFY(!AudioCacheManager::isCacheFile(QStringLiteral("/cache/12345.caf")));
    QVERIFY(!AudioCacheManager::isCacheFile(QStringLiteral("/cache/tmp-ABC.mp3")));
    QVERIFY(!AudioCacheManager::isCacheFile(QStringLiteral("/cache/index.json")));
}

void AudioCachePolicyTests::testIndexRecoversEntriesForOrphanFiles()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QByteArray payload("orphan-bytes");
    QVERIFY(!writeCacheFile(directory.path(), QStringLiteral("12345.mp3"), payload).isEmpty());

    AudioCacheManager manager(directory.path());

    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("12345")));
    const auto meta = manager.meta(QStringLiteral("12345"));
    QVERIFY(meta.has_value());
    QCOMPARE(meta->formatName, QStringLiteral("MP3"));
    QCOMPARE(meta->fileExtension, QStringLiteral("mp3"));
    QCOMPARE(meta->bitrateKbps, 128);
    QCOMPARE(meta->sizeBytes, static_cast<qint64>(payload.size()));
}

void AudioCachePolicyTests::testRecoveredOrphanStartsFreshForRetention()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    writeCacheFile(directory.path(), QStringLiteral("54321.mp3"));
    AudioCacheManager manager(directory.path());

    const auto meta = manager.meta(QStringLiteral("54321"));
    QVERIFY(meta.has_value());
    const QDateTime now = QDateTime::currentDateTimeUtc();
    QVERIFY(!audioCacheRetentionPolicy::isExpired(
        meta->cachedAt, now, audioCacheRetentionPolicy::maxAge()));
    QVERIFY(!audioCacheRetentionPolicy::isExpired(now, now, audioCacheRetentionPolicy::maxAge()));
}

void AudioCachePolicyTests::testTargetBitrateIs128kbps()
{
    QCOMPARE(AudioCacheManager::DefaultTargetBitrate, 128000);
    QCOMPARE(AudioCacheManager::DefaultTargetBitrate % 1000, 0);
}

void AudioCachePolicyTests::testRetentionIsExactlySevenDays()
{
    const QDateTime now = QDateTime::currentDateTimeUtc();
    QCOMPARE(audioCacheRetentionPolicy::maxAgeSeconds, static_cast<qint64>(7 * 24 * 60 * 60));
    QVERIFY(!audioCacheRetentionPolicy::isExpired(now, now, audioCacheRetentionPolicy::maxAge()));
    QVERIFY(!audioCacheRetentionPolicy::isExpired(
        now.addSecs(-6 * 24 * 60 * 60), now, audioCacheRetentionPolicy::maxAge()));
    QVERIFY(audioCacheRetentionPolicy::isExpired(
        now.addSecs(-8 * 24 * 60 * 60), now, audioCacheRetentionPolicy::maxAge()));
    QVERIFY(audioCacheRetentionPolicy::isExpired(
        now.addSecs(-audioCacheRetentionPolicy::maxAgeSeconds), now,
        audioCacheRetentionPolicy::maxAge()));
}

void AudioCachePolicyTests::testExpiryIsMeasuredFromCachedAtNotLastAccess()
{
    const QDateTime now = QDateTime::currentDateTimeUtc();
    const QDateTime old = now.addSecs(-10 * 24 * 60 * 60);
    const QDateTime justListened = now.addSecs(-60);
    QVERIFY(audioCacheRetentionPolicy::isExpired(old, now, audioCacheRetentionPolicy::maxAge()));
    QVERIFY(
        !audioCacheRetentionPolicy::isExpired(justListened, now, audioCacheRetentionPolicy::maxAge()));
}

void AudioCachePolicyTests::testFutureTimestampIsNotExpired()
{
    const QDateTime now = QDateTime::currentDateTimeUtc();
    QVERIFY(!audioCacheRetentionPolicy::isExpired(
        now.addSecs(60 * 60), now, audioCacheRetentionPolicy::maxAge()));
}

void AudioCachePolicyTests::testExpiredIDsSelectsOnlyOverdueEntries()
{
    const QDateTime now = QDateTime::currentDateTimeUtc();
    QHash<QString, QDateTime> byAge;
    byAge[QStringLiteral("fresh")] = now.addSecs(-3600);
    byAge[QStringLiteral("almost")] = now.addSecs(static_cast<qint64>(-6.9 * 24 * 60 * 60));
    byAge[QStringLiteral("stale")] = now.addSecs(static_cast<qint64>(-7.1 * 24 * 60 * 60));
    byAge[QStringLiteral("ancient")] = now.addSecs(-30LL * 24 * 60 * 60);

    const QSet<QString> result =
        audioCacheRetentionPolicy::expiredIDs(byAge, now, audioCacheRetentionPolicy::maxAge());
    QStringList sorted(result.begin(), result.end());
    sorted.sort();
    QCOMPARE(sorted, QStringList({QStringLiteral("ancient"), QStringLiteral("stale")}));
}

void AudioCachePolicyTests::testExpirySweepRunsEvenWhenUnderCapacity()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QDateTime now = QDateTime::currentDateTimeUtc();

    writeCacheFile(directory.path(), QStringLiteral("stale.mp3"));
    writeCacheFile(directory.path(), QStringLiteral("fresh.mp3"));
    QHash<QString, CacheMeta> index;
    index[QStringLiteral("stale")] =
        fakeMeta(1000, now.addSecs(-9 * 24 * 60 * 60), now.addSecs(-9 * 24 * 60 * 60));
    index[QStringLiteral("fresh")] = fakeMeta(1000, now.addSecs(-60));
    writeIndex(directory.path(), index);

    AudioCacheManager manager(directory.path());

    QCOMPARE(manager.cachedSongIDs().size(), 1);
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("fresh")));
    QVERIFY(!QFile::exists(QDir(directory.path()).filePath(QStringLiteral("stale.mp3"))));
    QVERIFY(QFile::exists(QDir(directory.path()).filePath(QStringLiteral("fresh.mp3"))));
}

void AudioCachePolicyTests::testExpirySweepProtectsCurrentlyPlayingFile()
{
    const QDateTime now = QDateTime::currentDateTimeUtc();
    SweepReplica store;
    store.index[QStringLiteral("playing")] = now.addSecs(-9 * 24 * 60 * 60);
    store.currentCachedSongID = QStringLiteral("playing");

    QVERIFY(store.purgeExpired(now).isEmpty());
    QVERIFY(store.index.contains(QStringLiteral("playing")));

    store.currentCachedSongID.reset();
    QCOMPARE(store.purgeExpired(now).size(), 1);
    QVERIFY(!store.index.contains(QStringLiteral("playing")));
}

void AudioCachePolicyTests::testCapacityEvictionStillAppliesToUnexpiredEntries()
{
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QDateTime now = QDateTime::currentDateTimeUtc();

    QHash<QString, CacheMeta> index;
    for (int position = 0; position < 5; ++position) {
        const QString id = QStringLiteral("s%1").arg(position);
        writeCacheFile(directory.path(), id + QStringLiteral(".mp3"));
        index[id] = fakeMeta(400 * mb, now.addSecs(-position));
    }
    writeIndex(directory.path(), index);

    AudioCacheManager manager(directory.path());
    QCOMPARE(manager.cachedSongIDs().size(), 5);
    QVERIFY(triggerCacheCommit(manager, QStringLiteral("trigger")));

    QVERIFY(!manager.cachedSongIDs().contains(QStringLiteral("s4")));
    QVERIFY(!manager.cachedSongIDs().contains(QStringLiteral("s3")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("s2")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("s1")));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("s0")));
}

void AudioCachePolicyTests::testClearAllKeepsCurrentlyPlayingFile()
{
    const QStringList paths = {
        QStringLiteral("/cache/playing.mp3"),
        QStringLiteral("/cache/other.mp3"),
        QStringLiteral("/cache/index.json"),
    };
    const QStringList protectedTargets = AudioCacheManager::cacheClearDeletionTargets(
        paths, std::optional<QString>(QStringLiteral("playing")));
    QVERIFY(!protectedTargets.contains(QStringLiteral("/cache/playing.mp3")));
    QStringList sortedTargets = protectedTargets;
    sortedTargets.sort();
    QCOMPARE(sortedTargets,
        QStringList({QStringLiteral("/cache/index.json"), QStringLiteral("/cache/other.mp3")}));
    QCOMPARE(AudioCacheManager::cacheClearDeletionTargets(paths, std::nullopt), paths);

    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const QString playingPath = writeCacheFile(directory.path(), QStringLiteral("playing.mp3"));
    const QString otherPath = writeCacheFile(directory.path(), QStringLiteral("other.mp3"));
    AudioCacheManager manager(directory.path());
    manager.setCurrentCachedSong(QStringLiteral("playing"));

    manager.clearAll();

    QVERIFY(QFile::exists(playingPath));
    QVERIFY(!QFile::exists(otherPath));
    QVERIFY(manager.cachedSongIDs().contains(QStringLiteral("playing")));
    QVERIFY(!manager.cachedSongIDs().contains(QStringLiteral("other")));
}

QTEST_MAIN(AudioCachePolicyTests)
#include "tst_audio_cache_policy.moc"
