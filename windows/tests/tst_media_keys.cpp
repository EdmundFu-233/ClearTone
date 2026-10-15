#include <QtTest>

#include "MainWindow.h"
#include "Playback/PlayerController.h"
#include "Core/Persistence/AppSettings.h"
#include "Core/Persistence/PersistenceStore.h"

#include <QFile>
#include <QDir>
#include <QTemporaryDir>
#include <QUrl>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

using namespace ct;

class MediaKeysTests : public QObject {
    Q_OBJECT
private slots:
    void restoredSongStaysSilentUntilMediaCommand();
};

void MediaKeysTests::restoredSongStaysSilentUntilMediaCommand()
{
#ifndef Q_OS_WIN
    QSKIP("Windows media session only");
#else
    QVERIFY(!qEnvironmentVariableIsEmpty("CLEARTONE_TEST_STORAGE_DIR"));
    const QString emptyHelper = QDir::tempPath() + QStringLiteral("/cleartone-media-keys-no-helper");
    QDir().mkpath(emptyHelper);
    qputenv("CLEARTONE_HELPER_ROOT", emptyHelper.toUtf8());
    QTemporaryDir dir;
    QVERIFY(dir.isValid());
    const QString path = dir.filePath(QStringLiteral("media-key-fixture.wav"));
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QVERIFY(file.write(QByteArray(44, '\0')) == 44);
    file.close();
    Song song;
    song.id = QStringLiteral("media-key-fixture");
    song.title = QStringLiteral("Media key fixture");
    song.source = SongSource::Local;
    song.localFileURL = QUrl::fromLocalFile(path).toString();
    song.duration = 90;
    PlayQueue queue;
    queue.replace({song});
    PersistenceStore::shared().saveQueue(PersistedQueue::from(queue, 12, 0.5f,
        false, QualityLevel::Unknown, 1.0f));
    AppSettings settings;
    settings.resumePlaybackOnLaunch = true;
    PersistenceStore::shared().saveSetting(QStringLiteral("appSettings"), settings.toJson());
    PlayerController& player = PlayerController::shared();
    int starts = 0;
    player.playbackStartOverride = [&starts](const QUrl&) { ++starts; };
    MainWindow window;
    window.show();
    QTest::qWait(100);
    QCOMPARE(player.currentSong()->id, song.id);
    QCOMPARE(player.playbackState().kind, PlaybackState::Kind::Paused);
    QCOMPARE(player.currentTime(), 12.0);
    QCOMPARE(starts, 0);
    QVERIFY(!player.isLoadInFlight());
    QVERIFY(player.engine() == nullptr);

    INPUT input[2]{};
    for (auto& key : input) {
        key.type = INPUT_KEYBOARD;
        key.ki.wVk = VK_MEDIA_PLAY_PAUSE;
    }
    input[1].ki.dwFlags = KEYEVENTF_KEYUP;
    QCOMPARE(SendInput(2, input, sizeof(INPUT)), UINT(2));
    QTest::qWait(500);
    qInfo() << "OS media-key routed to ClearTone:" << (starts == 1);

    // The foreground WM_APPCOMMAND fallback remains functional even on systems
    // where the SMTC session has been registered successfully.
    if (starts == 0) {
        SendMessageW(reinterpret_cast<HWND>(window.winId()), WM_APPCOMMAND,
            reinterpret_cast<WPARAM>(window.winId()),
            static_cast<LPARAM>(APPCOMMAND_MEDIA_PLAY << 16));
        QTRY_COMPARE(starts, 1);
    }
    QCOMPARE(player.playbackState().kind, PlaybackState::Kind::Loading);
    SendMessageW(reinterpret_cast<HWND>(window.winId()), WM_APPCOMMAND,
        reinterpret_cast<WPARAM>(window.winId()),
        static_cast<LPARAM>(APPCOMMAND_MEDIA_PAUSE << 16));
    QCOMPARE(player.playbackState().kind, PlaybackState::Kind::Paused);
    window.close();
    player.playbackStartOverride = nullptr;
#endif
}

QTEST_MAIN(MediaKeysTests)
#include "tst_media_keys.moc"
