#include <QtTest>

#include "App/AppState.h"
#include "Core/Persistence/PersistenceStore.h"
#include "Features/Shared/AddToPlaylistDialog.h"
#include "TestSupport.h"

#include <QComboBox>
#include <QLabel>
#include <QPointer>
#include <QPushButton>

using namespace ct;
using namespace ct::tests;

namespace {

class PlaylistProvider : public StubMusicProvider {
public:
    QList<Playlist> playlists;
    TestGate* gate = nullptr;
    Task<QList<Playlist>> fetchUserPlaylists(CancellationToken) override
    {
        if (gate) co_await *gate;
        co_return playlists;
    }
};

class PlaylistSocial : public StubSocialProvider {
public:
    int calls = 0;
    QString playlistID;
    QStringList songIDs;
    TestGate* gate = nullptr;
    bool fail = false;
    Task<void> addSongsToPlaylist(const QString& id, const QStringList& songs, CancellationToken) override
    {
        ++calls;
        playlistID = id;
        songIDs = songs;
        if (gate) co_await *gate;
        if (fail) throw MusicException::unknown(QStringLiteral("测试添加失败"));
    }
};

Playlist playlist(QString id, bool subscribed = false)
{
    Playlist item;
    item.id = id;
    item.name = QStringLiteral("歌单 %1").arg(id);
    item.isSubscribed = subscribed;
    return item;
}

Song song()
{
    Song item;
    item.id = QStringLiteral("song-at-click");
    item.title = QStringLiteral("要添加的歌曲");
    item.source = SongSource::Netease;
    return item;
}

void login(AppState& app, QString user = QStringLiteral("user-a"))
{
    AccountInfo account;
    account.userID = user;
    app.applyAccount(account);
}

} // namespace

class AddToPlaylistTests : public QObject {
    Q_OBJECT

private slots:
    void pickerExcludesSubscribedPlaylistsAndSendsSelectedSong()
    {
        PlaylistProvider provider;
        provider.playlists = {playlist("owned"), playlist("subscribed", true), playlist("second")};
        PlaylistSocial social;
        AppState app(&provider, &social);
        login(app);
        QPointer<AddToPlaylistDialog> dialog = new AddToPlaylistDialog(song(), nullptr, &app);
        dialog->open();
        auto* picker = dialog->findChild<QComboBox*>(QStringLiteral("ctPlaylistPicker"));
        auto* confirm = dialog->findChild<QPushButton*>(QStringLiteral("ctConfirmAddToPlaylist"));
        QVERIFY(picker);
        QVERIFY(confirm);
        QTRY_VERIFY(confirm->isEnabled());
        QCOMPARE(picker->count(), 2);
        picker->setCurrentIndex(1);
        confirm->click();
        QTRY_COMPARE(social.calls, 1);
        QCOMPARE(social.playlistID, QStringLiteral("second"));
        QCOMPARE(social.songIDs, QStringList{QStringLiteral("song-at-click")});
        QTRY_VERIFY(dialog.isNull());
    }

    void pendingWriteCannotBeRepeatedAndFailureCanBeRetried()
    {
        PlaylistProvider provider;
        provider.playlists = {playlist("owned")};
        PlaylistSocial social;
        TestGate gate;
        social.gate = &gate;
        social.fail = true;
        AppState app(&provider, &social);
        login(app);
        QPointer<AddToPlaylistDialog> dialog = new AddToPlaylistDialog(song(), nullptr, &app);
        dialog->open();
        auto* confirm = dialog->findChild<QPushButton*>(QStringLiteral("ctConfirmAddToPlaylist"));
        QTRY_VERIFY(confirm->isEnabled());
        confirm->click();
        QTRY_COMPARE(social.calls, 1);
        QVERIFY(!confirm->isEnabled());
        confirm->click();
        QCOMPARE(social.calls, 1);
        gate.open();
        QTRY_VERIFY(confirm->isEnabled());
        bool displaysError = false;
        for (auto* label : dialog->findChildren<QLabel*>())
            displaysError |= label->text().contains(QStringLiteral("测试添加失败"));
        QVERIFY(displaysError);
        social.gate = nullptr;
        social.fail = false;
        confirm->click();
        QTRY_VERIFY(dialog.isNull());
        QCOMPARE(social.calls, 2);
    }

    void accountChangeInvalidatesPendingPicker()
    {
        PlaylistProvider provider;
        provider.playlists = {playlist("old-account")};
        TestGate gate;
        provider.gate = &gate;
        PlaylistSocial social;
        AppState app(&provider, &social);
        login(app);
        QPointer<AddToPlaylistDialog> dialog = new AddToPlaylistDialog(song(), nullptr, &app);
        dialog->open();
        login(app, QStringLiteral("user-b"));
        gate.open();
        QTest::qWait(30);
        auto* confirm = dialog->findChild<QPushButton*>(QStringLiteral("ctConfirmAddToPlaylist"));
        QVERIFY(!confirm->isEnabled());
        confirm->click();
        QCOMPARE(social.calls, 0);
        delete dialog;
    }

    void closingPickerDuringLoadIsSafe()
    {
        PlaylistProvider provider;
        TestGate gate;
        provider.gate = &gate;
        PlaylistSocial social;
        AppState app(&provider, &social);
        login(app);
        auto* dialog = new AddToPlaylistDialog(song(), nullptr, &app);
        delete dialog;
        gate.open();
        QTest::qWait(30);
        QCOMPARE(social.calls, 0);
    }
};

QTEST_MAIN(AddToPlaylistTests)
#include "tst_add_to_playlist.moc"
