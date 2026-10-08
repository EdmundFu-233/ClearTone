#include <QtTest>

#include "Core/Models/MusicModels.h"
#include "Core/Persistence/AppSettings.h"
#include "Core/Persistence/PersistenceStore.h"
#include "Playback/PlayQueue.h"

#include <QDir>
#include <QJsonDocument>
#include <QJsonObject>

#include <cmath>
#include <limits>

using namespace ct;

namespace {

Song makeSong(const QString& id)
{
    Song song;
    song.id = id;
    song.title = QStringLiteral("歌-%1").arg(id);
    song.artists.append(Artist{QStringLiteral("a%1").arg(id), QStringLiteral("人"), std::nullopt, {}});
    song.source = SongSource::Netease;
    return song;
}

PersistedQueue makeQueue(const QStringList& itemIDs, double currentTime = 0)
{
    PersistedQueue queue;
    for (const QString& id : itemIDs) {
        QueueItem item;
        item.song = makeSong(id);
        queue.items.append(item);
    }
    queue.currentIndex = itemIDs.isEmpty() ? -1 : 0;
    queue.mode = PlayMode::Sequential;
    queue.currentTime = currentTime;
    queue.volume = 0.8f;
    queue.isMuted = false;
    queue.requestedQuality = QualityLevel::ExHigh;
    return queue;
}

QStringList queueIDs(const std::optional<PersistedQueue>& queue)
{
    QStringList ids;
    if (!queue) return ids;
    for (const QueueItem& item : queue->items) ids.append(item.song.id);
    return ids;
}

QStringList recentIDs(const QList<Song>& songs)
{
    QStringList ids;
    for (const Song& song : songs) ids.append(song.id);
    return ids;
}

AppSettings decodeSettings(const QString& json)
{
    return AppSettings::fromJson(QJsonDocument::fromJson(json.toUtf8()).object());
}

} // namespace

class PersistenceTests : public QObject {
    Q_OBJECT

private slots:
    void initTestCase();
    void init();
    void cleanup();

    void testQueueOnlyScheduleIsActuallyPersisted();
    void testRecentOnlyScheduleIsActuallyPersisted();
    void testQueueAndRecentCanBeScheduledIndependently();
    void testEmptyQueueIsPersisted();
    void testRepeatedQueueOnlySchedulesAllReachDisk();
    void testPersistAndFlushWritesSnapshotGivenAsArgument();
    void testPersistAndFlushWithNilArgumentsKeepsExistingData();
    void testStorageRootHonoursTestOverride();
    void testTestAudioDirectoryIsIsolatedToo();
    void testNaNSnapshotIsStillWritten();
    void testNaNSnapshotDoesNotWedgeLaterWrites();
    void testSettingWithNonFiniteFloatKeepsOtherFields();

    void nonFiniteLyricOffsetKeepsOtherFields();
    void missingKeysFallBackToDefaults();
    void explicitQualityIsNotOverriddenByNewDefaults();
    void legacyChineseQualityValueStillLoads();
};

void PersistenceTests::initTestCase()
{
    if (qEnvironmentVariableIsEmpty("CLEARTONE_TEST_STORAGE_DIR")) {
        const QString dir = QDir::temp().filePath(
            QStringLiteral("cleartone-tests-persistence-%1").arg(QCoreApplication::applicationPid()));
        qputenv("CLEARTONE_TEST_STORAGE_DIR", dir.toUtf8());
    }
}

void PersistenceTests::init()
{
    PersistenceWriter::shared().reset();
}

void PersistenceTests::cleanup()
{
    PersistenceWriter::shared().reset();
}

void PersistenceTests::testQueueOnlyScheduleIsActuallyPersisted()
{
    PersistenceWriter& writer = PersistenceWriter::shared();
    writer.schedule(makeQueue({QStringLiteral("1"), QStringLiteral("2"), QStringLiteral("3")}, 42));
    writer.flushNow();

    const auto loaded = PersistenceStore::shared().loadQueue();
    QVERIFY(loaded.has_value());
    QCOMPARE(queueIDs(loaded), QStringList({QStringLiteral("1"), QStringLiteral("2"), QStringLiteral("3")}));
    QVERIFY(std::abs(loaded->currentTime - 42) < 1e-3);
}

void PersistenceTests::testRecentOnlyScheduleIsActuallyPersisted()
{
    PersistenceWriter& writer = PersistenceWriter::shared();
    writer.scheduleRecent({makeSong(QStringLiteral("r1")), makeSong(QStringLiteral("r2"))});
    writer.flushNow();

    const QList<Song> loaded = PersistenceStore::shared().loadRecentSongs();
    QCOMPARE(recentIDs(loaded), QStringList({QStringLiteral("r1"), QStringLiteral("r2")}));
}

void PersistenceTests::testQueueAndRecentCanBeScheduledIndependently()
{
    PersistenceWriter& writer = PersistenceWriter::shared();
    writer.scheduleRecent({makeSong(QStringLiteral("only-recent"))});
    writer.flushNow();
    QCOMPARE(recentIDs(PersistenceStore::shared().loadRecentSongs()),
        QStringList({QStringLiteral("only-recent")}));

    writer.schedule(makeQueue({QStringLiteral("q1")}));
    writer.flushNow();
    QCOMPARE(queueIDs(PersistenceStore::shared().loadQueue()), QStringList({QStringLiteral("q1")}));
    QCOMPARE(recentIDs(PersistenceStore::shared().loadRecentSongs()),
        QStringList({QStringLiteral("only-recent")}));
}

void PersistenceTests::testEmptyQueueIsPersisted()
{
    PersistenceWriter& writer = PersistenceWriter::shared();
    writer.schedule(makeQueue({QStringLiteral("stale")}));
    writer.flushNow();
    QCOMPARE(PersistenceStore::shared().loadQueue()->items.size(), 1);

    writer.schedule(makeQueue({}));
    writer.flushNow();
    const auto loaded = PersistenceStore::shared().loadQueue();
    QVERIFY(loaded.has_value());
    QVERIFY(loaded->items.isEmpty());
    QCOMPARE(loaded->currentIndex, -1);
}

void PersistenceTests::testRepeatedQueueOnlySchedulesAllReachDisk()
{
    PersistenceWriter& writer = PersistenceWriter::shared();
    for (int round = 1; round <= 3; ++round) {
        QStringList ids;
        for (int index = 1; index <= round; ++index) ids.append(QString::number(index));
        writer.schedule(makeQueue(ids));
        writer.flushNow();
    }
    const auto loaded = PersistenceStore::shared().loadQueue();
    QVERIFY(loaded.has_value());
    QCOMPARE(loaded->items.size(), 3);
}

void PersistenceTests::testPersistAndFlushWritesSnapshotGivenAsArgument()
{
    PersistenceWriter::shared().persistAndFlush(
        makeQueue({QStringLiteral("quit-1")}), QList<Song>{makeSong(QStringLiteral("quit-recent"))});
    QCOMPARE(queueIDs(PersistenceStore::shared().loadQueue()), QStringList({QStringLiteral("quit-1")}));
    QCOMPARE(recentIDs(PersistenceStore::shared().loadRecentSongs()),
        QStringList({QStringLiteral("quit-recent")}));
}

void PersistenceTests::testPersistAndFlushWithNilArgumentsKeepsExistingData()
{
    PersistenceWriter& writer = PersistenceWriter::shared();
    writer.persistAndFlush(
        makeQueue({QStringLiteral("keep")}), QList<Song>{makeSong(QStringLiteral("keep-recent"))});
    writer.persistAndFlush(std::nullopt, std::nullopt);
    QCOMPARE(queueIDs(PersistenceStore::shared().loadQueue()), QStringList({QStringLiteral("keep")}));
    QCOMPARE(recentIDs(PersistenceStore::shared().loadRecentSongs()),
        QStringList({QStringLiteral("keep-recent")}));
}

void PersistenceTests::testStorageRootHonoursTestOverride()
{
    const QString expected = qEnvironmentVariable("CLEARTONE_TEST_STORAGE_DIR");
    QVERIFY(!expected.isEmpty());
    QCOMPARE(PersistenceStore::shared().storageRoot(), expected);
}

void PersistenceTests::testTestAudioDirectoryIsIsolatedToo()
{
    QSKIP("Windows source has no DemoAudioGenerator.directory equivalent");
}

void PersistenceTests::testNaNSnapshotIsStillWritten()
{
    PersistenceWriter& writer = PersistenceWriter::shared();
    writer.schedule(makeQueue({QStringLiteral("sentinel")}, 7));
    writer.flushNow();
    const auto sentinel = PersistenceStore::shared().loadQueue();
    QVERIFY(sentinel.has_value());
    QCOMPARE(queueIDs(sentinel), QStringList({QStringLiteral("sentinel")}));

    writer.schedule(makeQueue({QStringLiteral("1"), QStringLiteral("2")},
        std::numeric_limits<double>::quiet_NaN()));
    writer.flushNow();

    const auto loaded = PersistenceStore::shared().loadQueue();
    QVERIFY(loaded.has_value());
    QCOMPARE(queueIDs(loaded), QStringList({QStringLiteral("1"), QStringLiteral("2")}));
    QVERIFY(std::isnan(loaded->currentTime));
    QVERIFY(std::abs(loaded->volume - 0.8f) < 1e-3);
}

void PersistenceTests::testNaNSnapshotDoesNotWedgeLaterWrites()
{
    PersistenceWriter& writer = PersistenceWriter::shared();
    writer.schedule(makeQueue({QStringLiteral("bad")}, std::numeric_limits<double>::quiet_NaN()));
    writer.flushNow();
    writer.schedule(makeQueue({QStringLiteral("good")}, 42));
    writer.flushNow();

    const auto loaded = PersistenceStore::shared().loadQueue();
    QVERIFY(loaded.has_value());
    QCOMPARE(queueIDs(loaded), QStringList({QStringLiteral("good")}));
    QVERIFY(std::abs(loaded->currentTime - 42) < 1e-3);
}

void PersistenceTests::testSettingWithNonFiniteFloatKeepsOtherFields()
{
    const QString key = QStringLiteral("nanProbe");
    AppSettings settings;
    settings.lyricOffset = std::numeric_limits<double>::quiet_NaN();
    settings.themeMode = CTThemeMode::Dark;
    PersistenceStore::shared().saveSetting(key, QJsonValue(settings.toJson()));

    const AppSettings loaded =
        AppSettings::fromJson(PersistenceStore::shared().loadSetting(key).toObject());
    QCOMPARE(loaded.themeMode, CTThemeMode::Dark);
    QVERIFY(std::isnan(loaded.lyricOffset));
    PersistenceStore::shared().removeSetting(key);
}

void PersistenceTests::nonFiniteLyricOffsetKeepsOtherFields()
{
    AppSettings settings;
    settings.lyricOffset = std::numeric_limits<double>::quiet_NaN();
    settings.audioCacheEnabled = false;
    settings.preferredQuality = QualityLevel::Lossless;

    const AppSettings restored = AppSettings::fromJson(settings.toJson());
    QVERIFY(std::isnan(restored.lyricOffset));
    QVERIFY(!restored.audioCacheEnabled);
    QCOMPARE(restored.preferredQuality, QualityLevel::Lossless);
}

void PersistenceTests::missingKeysFallBackToDefaults()
{
    const AppSettings restored = decodeSettings(QStringLiteral("{}"));
    QCOMPARE(restored.preferredQuality, QualityLevel::Unknown);
    QVERIFY(restored.audioCacheEnabled);
    QCOMPARE(restored.themeMode, CTThemeMode::System);
}

void PersistenceTests::explicitQualityIsNotOverriddenByNewDefaults()
{
    const AppSettings restored = decodeSettings(QStringLiteral("{\"preferredQuality\":\"exHigh\"}"));
    QCOMPARE(restored.preferredQuality, QualityLevel::ExHigh);
}

void PersistenceTests::legacyChineseQualityValueStillLoads()
{
    const AppSettings restored = decodeSettings(QStringLiteral("{\"preferredQuality\":\"无损\"}"));
    QCOMPARE(restored.preferredQuality, QualityLevel::Lossless);
}

QTEST_MAIN(PersistenceTests)
#include "tst_persistence.moc"
