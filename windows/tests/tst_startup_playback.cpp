#include <QtTest>

#include "Core/Persistence/AppSettings.h"
#include "Core/Persistence/PersistenceStore.h"
#include "Playback/PlayQueue.h"
#include "Playback/PlayerController.h"

using namespace ct;

class StartupPlaybackTests : public QObject {
    Q_OBJECT

private slots:
    void restoredSongWaitsForUserAction();
};

void StartupPlaybackTests::restoredSongWaitsForUserAction()
{
    QVERIFY(!qEnvironmentVariableIsEmpty("CLEARTONE_TEST_STORAGE_DIR"));
    Song song;
    song.id = QStringLiteral("restored-song");
    song.title = QStringLiteral("Only play on request");
    song.duration = 180;
    PlayQueue queue;
    queue.replace({song});
    PersistenceStore::shared().saveQueue(PersistedQueue::from(
        queue, 42, 0.5f, false, QualityLevel::ExHigh, 1.0f));
    AppSettings settings;
    settings.resumePlaybackOnLaunch = true;
    PersistenceStore::shared().saveSetting(QStringLiteral("appSettings"), settings.toJson());

    PlayerController& player = PlayerController::shared();
    QVERIFY(player.currentSong());
    QCOMPARE(player.currentSong()->id, song.id);
    QCOMPARE(player.currentTime(), 42.0);
    QCOMPARE(player.playbackState().kind, PlaybackState::Kind::Paused);
    QVERIFY(!player.isLoadInFlight());
    QVERIFY(player.engine() == nullptr);
    QCoreApplication::processEvents();
    QVERIFY(!player.isLoadInFlight());

    // 恢复 VIP 账号或切换默认音质不得让静止恢复态的歌曲自动开始加载或播放。
    player.setAccountIsVIP(true);
    player.setRequestedQuality(QualityLevel::Lossless);
    QCoreApplication::processEvents();
    QCOMPARE(player.playbackState().kind, PlaybackState::Kind::Paused);
    QVERIFY(!player.isLoadInFlight());
    QVERIFY(player.engine() == nullptr);
}

QTEST_GUILESS_MAIN(StartupPlaybackTests)
#include "tst_startup_playback.moc"
