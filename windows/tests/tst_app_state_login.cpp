#include <QtTest>

#include "App/AppState.h"
#include "Core/Persistence/PersistenceStore.h"
#include "Core/Security/CredentialStore.h"
#include "Providers/Netease/NeteaseProvider.h"
#include "TestSupport.h"

using namespace ct;
using namespace ct::tests;

namespace {

AccountInfo makeAccount()
{
    AccountInfo account;
    account.userID = QStringLiteral("86080189");
    account.nickname = QStringLiteral("测试");
    return account;
}

Song makeSong(const QString& id)
{
    Song song;
    song.id = id;
    song.title = QStringLiteral("歌-") + id;
    song.source = SongSource::Netease;
    return song;
}

Playlist makePlaylist(const QString& id)
{
    Playlist playlist;
    playlist.id = id;
    playlist.name = QStringLiteral("我喜欢的音乐");
    playlist.source = SongSource::Netease;
    return playlist;
}

void raiseSessionExpired()
{
    NeteaseProvider& provider = NeteaseProvider::shared();
    if (provider.sessionExpired) provider.sessionExpired();
}

void resetUserState()
{
    CredentialStore::shared().remove(CredentialKey::NeteaseCookie);
    CredentialStore::shared().remove(CredentialKey::NeteaseUserID);
    PersistenceStore::shared().clearCachedAccount();
    PersistenceStore::shared().clearCachedLikedSongs();
    PersistenceStore::shared().clearCachedUserPlaylists();
}

bool containsPlaylist(const QList<Playlist>& playlists, const QString& id)
{
    for (const Playlist& playlist : playlists) {
        if (playlist.id == id) return true;
    }
    return false;
}

} // namespace

class AppStateLoginTests : public QObject {
    Q_OBJECT

private slots:
    void init() { resetUserState(); }
    void cleanup() { resetUserState(); }

    void testDidLoginLoadsLibraryData();
    void testRestoreLoginStateLoadsLibraryData();
    void testRestoreWithoutAccountLoadsNothing();
    void testNotLoggedInDoesNotFetchLibrary();
    void testApplyAccountResetsNeedsReLogin();
    void testReLoginAfterSessionExpiryClearsNeedsReLogin();
    void testSessionExpiryDropsPreviousAccountPlaylists();
    void testPerformLogoutClearsUserPlaylists();
    void testDataContextKeyChangeIsBroadcastOnLoginAndLogout();
};

void AppStateLoginTests::testDidLoginLoadsLibraryData()
{
    int likedIDCalls = 0;
    int likedSongCalls = 0;
    int playlistCalls = 0;
    StubMusicProvider provider;
    provider.likedSongIDsHandler = [&likedIDCalls](CancellationToken) -> Task<QStringList> {
        likedIDCalls += 1;
        co_return QStringList{QStringLiteral("s1")};
    };
    provider.likedSongsHandler = [&likedSongCalls](CancellationToken) -> Task<QList<Song>> {
        likedSongCalls += 1;
        co_return QList<Song>{makeSong(QStringLiteral("s1"))};
    };
    provider.userPlaylistsHandler = [&playlistCalls](CancellationToken) -> Task<QList<Playlist>> {
        playlistCalls += 1;
        co_return QList<Playlist>{makePlaylist(QStringLiteral("p1"))};
    };
    AppState state(&provider);

    syncWait(state.didLogin(makeAccount()));

    QVERIFY(state.isLoggedIn());
    QCOMPARE(likedIDCalls, 1);
    QCOMPARE(likedSongCalls, 1);
    QCOMPARE(playlistCalls, 1);
    QVERIFY(state.isLiked(QStringLiteral("s1")));
    QVERIFY(containsPlaylist(state.userPlaylists(), QStringLiteral("p1")));
}

void AppStateLoginTests::testRestoreLoginStateLoadsLibraryData()
{
    CredentialStore::shared().save(QStringLiteral("MUSIC_U=unit-test"), CredentialKey::NeteaseCookie);
    int likedIDCalls = 0;
    int playlistCalls = 0;
    StubMusicProvider provider;
    provider.accountInfoHandler = [](CancellationToken) -> Task<std::optional<AccountInfo>> {
        co_return makeAccount();
    };
    provider.likedSongIDsHandler = [&likedIDCalls](CancellationToken) -> Task<QStringList> {
        likedIDCalls += 1;
        co_return QStringList{QStringLiteral("s1")};
    };
    provider.userPlaylistsHandler = [&playlistCalls](CancellationToken) -> Task<QList<Playlist>> {
        playlistCalls += 1;
        co_return QList<Playlist>{makePlaylist(QStringLiteral("p1"))};
    };
    AppState state(&provider);

    syncWait(state.restoreLoginState());

    QVERIFY(state.isLoggedIn());
    QCOMPARE(likedIDCalls, 1);
    QCOMPARE(playlistCalls, 1);
}

void AppStateLoginTests::testRestoreWithoutAccountLoadsNothing()
{
    int likedIDCalls = 0;
    int playlistCalls = 0;
    StubMusicProvider provider;
    provider.likedSongIDsHandler = [&likedIDCalls](CancellationToken) -> Task<QStringList> {
        likedIDCalls += 1;
        co_return QStringList{QStringLiteral("s1")};
    };
    provider.userPlaylistsHandler = [&playlistCalls](CancellationToken) -> Task<QList<Playlist>> {
        playlistCalls += 1;
        co_return QList<Playlist>{makePlaylist(QStringLiteral("p1"))};
    };
    AppState state(&provider);

    syncWait(state.restoreLoginState());

    QVERIFY(!state.isLoggedIn());
    QCOMPARE(likedIDCalls, 0);
    QCOMPARE(playlistCalls, 0);
}

void AppStateLoginTests::testNotLoggedInDoesNotFetchLibrary()
{
    int likedIDCalls = 0;
    int likedSongCalls = 0;
    int playlistCalls = 0;
    StubMusicProvider provider;
    provider.likedSongIDsHandler = [&likedIDCalls](CancellationToken) -> Task<QStringList> {
        likedIDCalls += 1;
        co_return QStringList{QStringLiteral("s1")};
    };
    provider.likedSongsHandler = [&likedSongCalls](CancellationToken) -> Task<QList<Song>> {
        likedSongCalls += 1;
        co_return QList<Song>{makeSong(QStringLiteral("s1"))};
    };
    provider.userPlaylistsHandler = [&playlistCalls](CancellationToken) -> Task<QList<Playlist>> {
        playlistCalls += 1;
        co_return QList<Playlist>{makePlaylist(QStringLiteral("p1"))};
    };
    AppState state(&provider);

    syncWait(state.loadLikedSongs());
    syncWait(state.loadUserPlaylists());

    QCOMPARE(likedIDCalls, 0);
    QCOMPARE(likedSongCalls, 0);
    QCOMPARE(playlistCalls, 0);
    QVERIFY(!state.isLoggedIn());
}

void AppStateLoginTests::testApplyAccountResetsNeedsReLogin()
{
    StubMusicProvider provider;
    AppState state(&provider);
    state.setNeedsReLogin(true);

    state.applyAccount(makeAccount());

    QVERIFY(!state.needsReLogin());
    QVERIFY(state.isLoggedIn());
    QVERIFY(state.canPerformWrite());
}

void AppStateLoginTests::testReLoginAfterSessionExpiryClearsNeedsReLogin()
{
    StubMusicProvider provider;
    AppState state(&provider);
    syncWait(state.didLogin(makeAccount()));
    QVERIFY(state.canPerformWrite());

    raiseSessionExpired();

    QVERIFY(state.needsReLogin());
    QVERIFY(!state.isLoggedIn());
    QVERIFY(!state.canPerformWrite());

    syncWait(state.didLogin(makeAccount()));

    QVERIFY(!state.needsReLogin());
    QVERIFY(state.canPerformWrite());
}

void AppStateLoginTests::testSessionExpiryDropsPreviousAccountPlaylists()
{
    StubMusicProvider provider;
    provider.userPlaylistsHandler = [](CancellationToken) -> Task<QList<Playlist>> {
        co_return QList<Playlist>{makePlaylist(QStringLiteral("p1"))};
    };
    AppState state(&provider);
    syncWait(state.didLogin(makeAccount()));
    QCOMPARE(state.userPlaylists().size(), 1);
    QCOMPARE(state.userPlaylists().first().id, QStringLiteral("p1"));

    raiseSessionExpired();

    QVERIFY(state.needsReLogin());
    QVERIFY(state.userPlaylists().isEmpty());
}

void AppStateLoginTests::testPerformLogoutClearsUserPlaylists()
{
    int logoutCalls = 0;
    StubMusicProvider provider;
    provider.userPlaylistsHandler = [](CancellationToken) -> Task<QList<Playlist>> {
        co_return QList<Playlist>{makePlaylist(QStringLiteral("p1"))};
    };
    provider.logoutHandler = [&logoutCalls](CancellationToken) -> Task<void> {
        logoutCalls += 1;
        co_return;
    };
    AppState state(&provider);
    syncWait(state.didLogin(makeAccount()));
    QCOMPARE(state.userPlaylists().size(), 1);

    syncWait(state.performLogout());

    QCOMPARE(logoutCalls, 1);
    QVERIFY(!state.isLoggedIn());
    QVERIFY(state.userPlaylists().isEmpty());
}

void AppStateLoginTests::testDataContextKeyChangeIsBroadcastOnLoginAndLogout()
{
    StubMusicProvider provider;
    AppState state(&provider);
    int changedCount = 0;
    int dataContextCount = 0;
    state.changed.subscribe([&changedCount] { changedCount += 1; });
    state.dataContextChanged.subscribe([&dataContextCount] { dataContextCount += 1; });

    const QString before = state.dataContextKey();
    const int generationBefore = state.currentAccountGeneration();
    AccountInfo account;
    account.userID = QStringLiteral("42");
    account.nickname = QStringLiteral("tester");

    state.applyAccount(account);

    QVERIFY(changedCount > 0);
    QVERIFY(dataContextCount > 0);
    QVERIFY(state.dataContextKey() != before);
    QVERIFY(state.currentAccountGeneration() != generationBefore);

    changedCount = 0;
    dataContextCount = 0;
    const QString afterLogin = state.dataContextKey();
    syncWait(state.performLogout());

    QVERIFY(changedCount > 0);
    QVERIFY(dataContextCount > 0);
    QVERIFY(state.dataContextKey() != afterLogin);
    QVERIFY(!state.isLoggedIn());
}

QTEST_MAIN(AppStateLoginTests)
#include "tst_app_state_login.moc"
