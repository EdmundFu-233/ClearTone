#include <QtTest>

#include "Core/Artist/ArtistProfileSession.h"
#include "TestSupport.h"

using namespace ct;
using namespace ct::tests;

namespace {

Song makeSong(const QString& id)
{
    Song song;
    song.id = id;
    song.title = QStringLiteral("歌%1").arg(id);
    Artist artist;
    artist.id = QStringLiteral("1");
    artist.name = QStringLiteral("测试歌手");
    song.artists.append(artist);
    song.source = SongSource::Netease;
    return song;
}

Album makeAlbum(const QString& id, const QString& name)
{
    Album album;
    album.id = id;
    album.name = name;
    return album;
}

Artist makeArtist(const QString& id, const QString& name)
{
    Artist artist;
    artist.id = id;
    artist.name = name;
    return artist;
}

QStringList songIDs(const QList<Song>& songs)
{
    QStringList ids;
    for (const Song& song : songs) ids.append(song.id);
    return ids;
}

QStringList artistIDs(const QList<Artist>& artists)
{
    QStringList ids;
    for (const Artist& artist : artists) ids.append(artist.id);
    return ids;
}

} // namespace

class ArtistProfileSessionTests : public QObject {
    Q_OBJECT

private slots:
    void testSwitchToArtistClearsEverything();
    void testSwitchToSameArtistIsNoOpButDataContextReloadClears();
    void testSwitchToArtistDoesNotStartLoadingOnItsOwn();
    void testLoadMoreSongsAdvancesOffsetByLoadedCount();
    void testNoMorePagesStopsLoading();
    void testEmptyListDoesNotLoadMore();
    void testLoadMoreFailureKeepsExistingSongs();
    void testSuccessfulPaginationRetryClearsSongsError();
    void testFirstPageFailureSetsError();
    void testDuplicateSongsAcrossPagesAreDeduplicated();
    void testLateResponseFromPreviousArtistIsDiscarded();
    void testLateAlbumPageFromPreviousArtistIsDiscarded();
    void testFollowedInitializesFromAlbumPage();
    void testLaterPagesDoNotClearFollowedState();
    void testSetFollowedUpdatesLocalState();
    void testSimilarArtistsExcludeSelf();
    void testHighlightsFailureIsSilent();
};

void ArtistProfileSessionTests::testSwitchToArtistClearsEverything()
{
    StubArtistProfileProvider provider;
    ArtistSongPage page;
    page.songs.append(makeSong(QStringLiteral("s1")));
    page.total = 1;
    page.hasMore = false;
    provider.enqueueSongPage(page);

    ArtistProfileSession session(QStringLiteral("1"), &provider);
    syncWait(session.loadProfileAsync());
    syncWait(session.loadSongsAsync());
    QVERIFY(!session.songs().isEmpty());

    session.switchTo(QStringLiteral("2"));

    QCOMPARE(session.artistID(), QStringLiteral("2"));
    QVERIFY(!session.profile().has_value());
    QVERIFY(session.songs().isEmpty());
    QVERIFY(session.albums().isEmpty());
    QVERIFY(session.mvs().isEmpty());
    QVERIFY(!session.intro().has_value());
    QVERIFY(session.similarArtists().isEmpty());
}

void ArtistProfileSessionTests::testSwitchToSameArtistIsNoOpButDataContextReloadClears()
{
    StubArtistProfileProvider provider;
    ArtistProfileSession session(QStringLiteral("1"), &provider);
    syncWait(session.loadProfileAsync());
    QVERIFY(session.profile().has_value());

    session.switchTo(QStringLiteral("1"));
    QVERIFY(session.profile().has_value());

    session.reloadForDataContext();
    QVERIFY(!session.profile().has_value());
    QCOMPARE(session.artistID(), QStringLiteral("1"));
}

void ArtistProfileSessionTests::testSwitchToArtistDoesNotStartLoadingOnItsOwn()
{
    StubArtistProfileProvider provider;
    ArtistProfileSession session(QStringLiteral("1"), &provider);

    session.switchTo(QStringLiteral("2"));
    QCOMPARE(session.artistID(), QStringLiteral("2"));
    QVERIFY(!session.profile().has_value());

    syncWait(session.loadProfileAsync());
    QVERIFY(session.profile().has_value());
}

void ArtistProfileSessionTests::testLoadMoreSongsAdvancesOffsetByLoadedCount()
{
    StubArtistProfileProvider provider;
    ArtistSongPage first;
    first.songs = {makeSong(QStringLiteral("s0")), makeSong(QStringLiteral("s1")),
        makeSong(QStringLiteral("s2"))};
    first.total = 9;
    first.hasMore = true;
    provider.enqueueSongPage(first);

    ArtistSongPage second;
    second.songs = {makeSong(QStringLiteral("s3")), makeSong(QStringLiteral("s4")),
        makeSong(QStringLiteral("s5"))};
    second.total = 9;
    second.hasMore = false;
    provider.enqueueSongPage(second);

    ArtistProfileSession session(QStringLiteral("1"), &provider);

    syncWait(session.loadSongsAsync());
    QCOMPARE(provider.requestedSongOffsets, QList<int>{0});
    QCOMPARE(session.songs().size(), 3);
    QCOMPARE(session.songsTotal(), 9);

    syncWait(session.loadMoreSongsAsync());
    QCOMPARE(provider.requestedSongOffsets, QList<int>({0, 3}));
    QCOMPARE(songIDs(session.songs()),
        QStringList({QStringLiteral("s0"), QStringLiteral("s1"), QStringLiteral("s2"),
            QStringLiteral("s3"), QStringLiteral("s4"), QStringLiteral("s5")}));
}

void ArtistProfileSessionTests::testNoMorePagesStopsLoading()
{
    StubArtistProfileProvider provider;
    ArtistSongPage page;
    page.songs.append(makeSong(QStringLiteral("s0")));
    page.total = 1;
    page.hasMore = false;
    provider.enqueueSongPage(page);

    ArtistProfileSession session(QStringLiteral("1"), &provider);

    syncWait(session.loadSongsAsync());
    QVERIFY(!session.canLoadMoreSongs());

    syncWait(session.loadMoreSongsAsync());
    QCOMPARE(provider.requestedSongOffsets, QList<int>{0});
}

void ArtistProfileSessionTests::testEmptyListDoesNotLoadMore()
{
    StubArtistProfileProvider provider;
    ArtistSongPage page;
    page.hasMore = true;
    provider.enqueueSongPage(page);

    ArtistProfileSession session(QStringLiteral("1"), &provider);

    syncWait(session.loadSongsAsync());
    QVERIFY(!session.canLoadMoreSongs());

    syncWait(session.loadMoreSongsAsync());
    QCOMPARE(provider.requestedSongOffsets, QList<int>{0});
}

void ArtistProfileSessionTests::testLoadMoreFailureKeepsExistingSongs()
{
    StubArtistProfileProvider provider;
    ArtistSongPage page;
    page.songs.append(makeSong(QStringLiteral("s0")));
    page.total = 99;
    page.hasMore = true;
    provider.enqueueSongPage(page);

    ArtistProfileSession session(QStringLiteral("1"), &provider);
    syncWait(session.loadSongsAsync());

    provider.failNextSongPage = true;
    syncWait(session.loadMoreSongsAsync());

    QCOMPARE(songIDs(session.songs()), QStringList{QStringLiteral("s0")});
    QVERIFY(session.songsError().has_value());
    QVERIFY(session.canLoadMoreSongs());
}

void ArtistProfileSessionTests::testSuccessfulPaginationRetryClearsSongsError()
{
    StubArtistProfileProvider provider;
    ArtistSongPage first;
    first.songs.append(makeSong(QStringLiteral("s0")));
    first.total = 9;
    first.hasMore = true;
    provider.enqueueSongPage(first);

    ArtistSongPage second;
    second.songs.append(makeSong(QStringLiteral("s1")));
    second.total = 9;
    second.hasMore = false;
    provider.enqueueSongPage(second);

    ArtistProfileSession session(QStringLiteral("1"), &provider);
    syncWait(session.loadSongsAsync());

    provider.failNextSongPage = true;
    syncWait(session.loadMoreSongsAsync());
    QVERIFY(session.songsError().has_value());

    syncWait(session.loadMoreSongsAsync());
    QVERIFY(!session.songsError().has_value());
    QCOMPARE(songIDs(session.songs()), QStringList({QStringLiteral("s0"), QStringLiteral("s1")}));
}

void ArtistProfileSessionTests::testFirstPageFailureSetsError()
{
    StubArtistProfileProvider provider;
    provider.failProfile = true;
    ArtistProfileSession session(QStringLiteral("1"), &provider);

    syncWait(session.loadProfileAsync());

    QVERIFY(session.profileError().has_value());
    QVERIFY(!session.profile().has_value());
}

void ArtistProfileSessionTests::testDuplicateSongsAcrossPagesAreDeduplicated()
{
    StubArtistProfileProvider provider;
    ArtistSongPage first;
    first.songs = {makeSong(QStringLiteral("a")), makeSong(QStringLiteral("b"))};
    first.total = 3;
    first.hasMore = true;
    provider.enqueueSongPage(first);

    ArtistSongPage second;
    second.songs = {makeSong(QStringLiteral("a")), makeSong(QStringLiteral("c"))};
    second.total = 3;
    second.hasMore = false;
    provider.enqueueSongPage(second);

    ArtistProfileSession session(QStringLiteral("1"), &provider);

    syncWait(session.loadSongsAsync());
    syncWait(session.loadMoreSongsAsync());

    QCOMPARE(songIDs(session.songs()),
        QStringList({QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c")}));
}

void ArtistProfileSessionTests::testLateResponseFromPreviousArtistIsDiscarded()
{
    auto gate = std::make_shared<TestGate>();
    StubArtistProfileProvider provider;
    provider.songGate = gate;
    ArtistSongPage page;
    page.songs.append(makeSong(QStringLiteral("old")));
    page.hasMore = false;
    provider.enqueueSongPage(page);

    ArtistProfileSession session(QStringLiteral("1"), &provider);

    auto task = session.loadSongsAsync();
    task.start();
    QVERIFY2(until([&] { return provider.requestedSongOffsets.size() == 1; }), "歌曲请求未发出");

    session.switchTo(QStringLiteral("2"));
    gate->open();
    QVERIFY2(until([&] { return task.isDone(); }), "歌曲请求未结束");

    QVERIFY(session.songs().isEmpty());
    QVERIFY(!session.songsError().has_value());
}

void ArtistProfileSessionTests::testLateAlbumPageFromPreviousArtistIsDiscarded()
{
    auto gate = std::make_shared<TestGate>();
    StubArtistProfileProvider provider;
    provider.albumGate = gate;
    ArtistAlbumPage page;
    page.albums.append(makeAlbum(QStringLiteral("1"), QStringLiteral("A")));
    page.isFollowed = true;
    page.hasMore = false;
    provider.enqueueAlbumPage(page);

    ArtistProfileSession session(QStringLiteral("1"), &provider);

    auto task = session.loadAlbumsAsync();
    task.start();
    QVERIFY2(until([&] { return provider.requestedAlbumOffsets.size() == 1; }), "专辑请求未发出");

    session.switchTo(QStringLiteral("2"));
    gate->open();
    QVERIFY2(until([&] { return task.isDone(); }), "专辑请求未结束");

    QVERIFY(session.albums().isEmpty());
    QVERIFY(!session.isFollowed().has_value());
}

void ArtistProfileSessionTests::testFollowedInitializesFromAlbumPage()
{
    StubArtistProfileProvider provider;
    ArtistAlbumPage page;
    page.albums.append(makeAlbum(QStringLiteral("1"), QStringLiteral("A")));
    page.isFollowed = true;
    page.hasMore = false;
    provider.enqueueAlbumPage(page);

    ArtistProfileSession session(QStringLiteral("1"), &provider);

    syncWait(session.loadAlbumsAsync());

    QVERIFY(session.isFollowed().has_value());
    QVERIFY(*session.isFollowed());
}

void ArtistProfileSessionTests::testLaterPagesDoNotClearFollowedState()
{
    StubArtistProfileProvider provider;
    ArtistAlbumPage first;
    first.albums.append(makeAlbum(QStringLiteral("1"), QStringLiteral("A")));
    first.isFollowed = true;
    first.hasMore = true;
    provider.enqueueAlbumPage(first);

    ArtistAlbumPage second;
    second.albums.append(makeAlbum(QStringLiteral("2"), QStringLiteral("B")));
    second.isFollowed = std::nullopt;
    second.hasMore = false;
    provider.enqueueAlbumPage(second);

    ArtistProfileSession session(QStringLiteral("1"), &provider);

    syncWait(session.loadAlbumsAsync());
    syncWait(session.loadMoreAlbumsAsync());

    QVERIFY(session.isFollowed().has_value());
    QVERIFY(*session.isFollowed());
}

void ArtistProfileSessionTests::testSetFollowedUpdatesLocalState()
{
    StubArtistProfileProvider provider;
    ArtistProfileSession session(QStringLiteral("1"), &provider);

    session.setFollowed(true);

    QVERIFY(session.isFollowed().value_or(false));
}

void ArtistProfileSessionTests::testSimilarArtistsExcludeSelf()
{
    StubArtistProfileProvider provider;
    provider.similarArtists = {makeArtist(QStringLiteral("1"), QStringLiteral("自己")),
        makeArtist(QStringLiteral("2"), QStringLiteral("相似甲")),
        makeArtist(QStringLiteral("3"), QStringLiteral("相似乙"))};
    ArtistProfileSession session(QStringLiteral("1"), &provider);

    syncWait(session.loadHighlightsAsync());

    QCOMPARE(artistIDs(session.similarArtists()),
        QStringList({QStringLiteral("2"), QStringLiteral("3")}));
}

void ArtistProfileSessionTests::testHighlightsFailureIsSilent()
{
    StubArtistProfileProvider provider;
    provider.failHighlights = true;
    ArtistProfileSession session(QStringLiteral("1"), &provider);

    syncWait(session.loadHighlightsAsync());

    QVERIFY(session.hotSongs().isEmpty());
    QVERIFY(session.similarArtists().isEmpty());
    QVERIFY(!session.isLoadingHighlights());
    QVERIFY(!session.profileError().has_value());
}

QTEST_MAIN(ArtistProfileSessionTests)
#include "tst_artist_profile.moc"
