#include <QtTest>

#include "Core/Search/SearchSession.h"
#include "TestSupport.h"

using namespace ct;
using namespace ct::tests;

namespace {

Song makeSong(const QString& id)
{
    Song song;
    song.id = id;
    song.title = QStringLiteral("歌-%1").arg(id);
    Artist artist;
    artist.id = QStringLiteral("a1");
    artist.name = QStringLiteral("Artist");
    song.artists.append(artist);
    song.source = SongSource::Netease;
    return song;
}

QStringList songIDs(const SearchResult& result)
{
    QStringList ids;
    for (const Song& song : result.songs) ids.append(song.id);
    return ids;
}

QStringList albumIDs(const SearchResult& result)
{
    QStringList ids;
    for (const Album& album : result.albums) ids.append(album.id);
    return ids;
}

int countFor(const SearchResult& result, SearchType type)
{
    switch (type) {
    case SearchType::Song:
        return int(result.songs.size());
    case SearchType::Artist:
        return int(result.artists.size());
    case SearchType::Album:
        return int(result.albums.size());
    case SearchType::Playlist:
        return int(result.playlists.size());
    }
    return 0;
}

} // namespace

class SearchSessionTests : public QObject {
    Q_OBJECT

private slots:
    void testPaginationUsesCommittedQueryNotDraft();
    void testPaginationUsesCommittedType();
    void testDisplayTypeFollowsCommittedType();
    void testResetDiscardsInFlightSearch();
    void testResetDiscardsInFlightPagination();
    void testLoadMoreIsNoopAfterReset();
    void testStaleSearchResponseIsDiscarded();
    void testCancelInFlightDiscardsUncommittedSearch();
    void testCancelInFlightKeepsSettledResult();
    void testRetryRerunsCommittedQuery();
    void testRefreshDataContextPrefersDraft();
    void testRefreshDataContextFallsBackToCommittedQuery();
    void testRefreshDataContextWithoutResultsIsNoop();
    void testSubmitIgnoresBlankDraft();
    void testSubmitTrimsWhitespace();

    void testAllFourTypesPaginate();
    void testNonSongTypesWereTheRegression();
    void testNoPaginationWhenHasMoreIsFalse();
    void testPaginationUsesCommittedQueryNotDraftOnPageTwo();
    void testPaginationLockDropsConcurrentSecondCall();
    void testIsEmptyRequiresAllFourEmpty();
    void testResetClearsResultAndBlocksPagination();
    void testNewSearchInvalidatesPreviousResult();
    void testDisplayTypeFollowsCommittedQuery();
    void testCancelInFlightRollsBackInFlightPage();
    void testPaginationFailureKeepsResultAndSurfacesError();
    void testFailedNewSearchDoesNotLeaveStaleResult();
};

void SearchSessionTests::testPaginationUsesCommittedQueryNotDraft()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 2;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");

    session.setDraftQuery(QStringLiteral("B"));
    session.loadMore();
    QVERIFY2(until([&] { return session.result().has_value() && session.result()->songs.size() == 2; }),
        "分页结果没有追加进来");

    QCOMPARE(provider.searchCalls.size(), 2);
    QCOMPARE(provider.searchCalls.at(0).query, QStringLiteral("A"));
    QCOMPARE(provider.searchCalls.at(0).page, 1);
    QCOMPARE(provider.searchCalls.at(1).query, QStringLiteral("A"));
    QCOMPARE(provider.searchCalls.at(1).page, 2);
    QCOMPARE(session.activeQuery().value_or(QString()), QStringLiteral("A"));
    QCOMPARE(songIDs(*session.result()), QStringList({QStringLiteral("A-p1"), QStringLiteral("A-p2")}));
}

void SearchSessionTests::testPaginationUsesCommittedType()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 2;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Album);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");

    session.loadMore();
    QVERIFY2(until([&] { return provider.searchCalls.size() == 2; }), "分页未发出");

    QCOMPARE(provider.searchCalls.at(0).type, SearchType::Album);
    QCOMPARE(provider.searchCalls.at(1).type, SearchType::Album);
    QCOMPARE(session.displayType(), SearchType::Album);
}

void SearchSessionTests::testDisplayTypeFollowsCommittedType()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 2;
    SearchSession session(&provider);
    QCOMPARE(session.displayType(), SearchType::Song);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Playlist);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");
    QCOMPARE(session.displayType(), SearchType::Playlist);

    session.reset();
    QCOMPARE(session.displayType(), SearchType::Song);
}

void SearchSessionTests::testResetDiscardsInFlightSearch()
{
    auto gate = std::make_shared<TestGate>();
    StubMusicProvider provider;
    provider.searchHandler = [gate](QString query, SearchType type, int page, int,
                                  CancellationToken) -> Task<SearchResult> {
        co_await *gate;
        co_return StubMusicProvider::page(query, type, page, false);
    };
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Song);
    QVERIFY(session.isLoading());
    QVERIFY(!session.result().has_value());

    session.reset();
    QVERIFY(!session.result().has_value());
    QVERIFY(!session.isLoading());
    QCOMPARE(session.draftQuery(), QString());

    gate->open();
    QTest::qWait(200);

    QVERIFY(!session.result().has_value());
    QVERIFY(!session.isLoading());
    QVERIFY(!session.errorMessage().has_value());
    QVERIFY(!session.activeQuery().has_value());
}

void SearchSessionTests::testResetDiscardsInFlightPagination()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 3;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");

    auto gate = std::make_shared<TestGate>();
    provider.searchHandler = [gate](QString query, SearchType type, int page, int,
                                  CancellationToken) -> Task<SearchResult> {
        co_await *gate;
        co_return StubMusicProvider::page(query, type, page, false);
    };

    session.loadMore();
    QTest::qWait(50);
    session.reset();
    gate->open();
    QTest::qWait(200);

    QVERIFY(!session.result().has_value());
    QCOMPARE(session.currentPage(), 1);
}

void SearchSessionTests::testLoadMoreIsNoopAfterReset()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 3;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");
    const int before = int(provider.searchCalls.size());

    session.reset();
    session.loadMore();
    QTest::qWait(100);

    QCOMPARE(int(provider.searchCalls.size()), before);
}

void SearchSessionTests::testStaleSearchResponseIsDiscarded()
{
    auto gateA = std::make_shared<TestGate>();
    auto gateB = std::make_shared<TestGate>();
    StubMusicProvider provider;
    provider.searchHandler = [gateA, gateB](QString query, SearchType type, int page, int,
                                   CancellationToken) -> Task<SearchResult> {
        if (query == QStringLiteral("A")) {
            co_await *gateA;
        } else {
            co_await *gateB;
        }
        co_return StubMusicProvider::page(query, type, page, false);
    };
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Song);
    session.setDraftQuery(QStringLiteral("B"));
    session.submit(SearchType::Song);

    gateB->open();
    QVERIFY2(until([&] { return session.result().has_value(); }), "后发搜索未完成");
    QCOMPARE(songIDs(*session.result()), QStringList{QStringLiteral("B-p1")});

    gateA->open();
    QTest::qWait(200);

    QCOMPARE(songIDs(*session.result()), QStringList{QStringLiteral("B-p1")});
    QCOMPARE(session.activeQuery().value_or(QString()), QStringLiteral("B"));
}

void SearchSessionTests::testCancelInFlightDiscardsUncommittedSearch()
{
    auto gate = std::make_shared<TestGate>();
    StubMusicProvider provider;
    provider.searchTotalPages = 2;
    provider.searchHandler = [gate](QString query, SearchType type, int page, int,
                                  CancellationToken) -> Task<SearchResult> {
        if (query == QStringLiteral("B")) co_await *gate;
        co_return StubMusicProvider::page(query, type, page, false);
    };
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");

    session.setDraftQuery(QStringLiteral("B"));
    session.submit(SearchType::Song);
    QVERIFY(session.isLoading());

    session.cancelInFlight();
    QVERIFY(!session.isLoading());
    QVERIFY(!session.result().has_value());
    QVERIFY(!session.activeQuery().has_value());

    gate->open();
    QTest::qWait(200);
    QVERIFY(!session.result().has_value());
}

void SearchSessionTests::testCancelInFlightKeepsSettledResult()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 2;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");
    QVERIFY(!session.isLoading());

    session.cancelInFlight();

    QCOMPARE(songIDs(*session.result()), QStringList{QStringLiteral("A-p1")});
    QCOMPARE(session.activeQuery().value_or(QString()), QStringLiteral("A"));
    QVERIFY(!session.isLoading());
}

void SearchSessionTests::testRetryRerunsCommittedQuery()
{
    auto remainingFailures = std::make_shared<int>(1);
    StubMusicProvider provider;
    provider.searchTotalPages = 2;
    provider.searchHandler = [remainingFailures](QString query, SearchType type, int page, int,
                                    CancellationToken) -> Task<SearchResult> {
        if (*remainingFailures > 0) {
            *remainingFailures = 0;
            throw MusicException::networkUnavailable();
        }
        co_return StubMusicProvider::page(query, type, page, false);
    };
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.errorMessage().has_value(); }), "失败未暴露");

    session.setDraftQuery(QStringLiteral("B"));
    session.retry(SearchType::Song);
    QVERIFY2(until([&] { return session.result().has_value(); }), "重试未完成");

    QCOMPARE(provider.searchCalls.size(), 2);
    QCOMPARE(provider.searchCalls.at(0).query, QStringLiteral("A"));
    QCOMPARE(provider.searchCalls.at(0).page, 1);
    QCOMPARE(provider.searchCalls.at(1).query, QStringLiteral("A"));
    QCOMPARE(provider.searchCalls.at(1).page, 1);
}

void SearchSessionTests::testRefreshDataContextPrefersDraft()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 2;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");

    session.setDraftQuery(QStringLiteral("B"));
    session.refreshDataContext(SearchType::Album);
    QVERIFY2(until([&] { return provider.searchCalls.size() == 2; }), "重搜未发出");

    QCOMPARE(provider.searchCalls.at(0).query, QStringLiteral("A"));
    QCOMPARE(provider.searchCalls.at(0).type, SearchType::Song);
    QCOMPARE(provider.searchCalls.at(0).page, 1);
    QCOMPARE(provider.searchCalls.at(1).query, QStringLiteral("B"));
    QCOMPARE(provider.searchCalls.at(1).type, SearchType::Album);
    QCOMPARE(provider.searchCalls.at(1).page, 1);
}

void SearchSessionTests::testRefreshDataContextFallsBackToCommittedQuery()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 2;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");

    session.setDraftQuery(QString());
    session.refreshDataContext(SearchType::Song);
    QVERIFY2(until([&] { return provider.searchCalls.size() == 2; }), "重搜未发出");

    QCOMPARE(provider.searchCalls.at(1).query, QStringLiteral("A"));
    QCOMPARE(provider.searchCalls.at(1).type, SearchType::Song);
    QCOMPARE(provider.searchCalls.at(1).page, 1);
}

void SearchSessionTests::testRefreshDataContextWithoutResultsIsNoop()
{
    StubMusicProvider provider;
    SearchSession session(&provider);

    session.refreshDataContext(SearchType::Song);
    QTest::qWait(100);

    QVERIFY(provider.searchCalls.isEmpty());
}

void SearchSessionTests::testSubmitIgnoresBlankDraft()
{
    StubMusicProvider provider;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("   "));
    session.submit(SearchType::Song);
    QTest::qWait(100);

    QVERIFY(provider.searchCalls.isEmpty());
    QVERIFY(!session.isLoading());
    QVERIFY(!session.result().has_value());
}

void SearchSessionTests::testSubmitTrimsWhitespace()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 2;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("  周杰伦 "));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");

    QCOMPARE(provider.searchCalls.size(), 1);
    QCOMPARE(provider.searchCalls.at(0).query, QStringLiteral("周杰伦"));
    QCOMPARE(provider.searchCalls.at(0).page, 1);
    QCOMPARE(session.activeQuery().value_or(QString()), QStringLiteral("周杰伦"));
}

void SearchSessionTests::testAllFourTypesPaginate()
{
    for (SearchType type : {SearchType::Song, SearchType::Artist, SearchType::Album, SearchType::Playlist}) {
        StubMusicProvider provider;
        provider.searchTotalPages = 3;
        SearchSession session(&provider);

        session.setDraftQuery(QStringLiteral("周杰伦"));
        session.submit(type);
        QVERIFY2(until([&] { return !session.isLoading(); }), "首搜未完成");
        QCOMPARE(provider.searchCalls.size(), 1);

        session.loadMore();
        QVERIFY2(until([&] {
                     return session.result().has_value() && countFor(*session.result(), type) == 2;
                 }),
            "没有请求第 2 页");
        QCOMPARE(provider.searchCalls.size(), 2);
    }
}

void SearchSessionTests::testNonSongTypesWereTheRegression()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 3;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("test"));
    session.submit(SearchType::Album);
    QVERIFY2(until([&] { return !session.isLoading(); }), "首搜未完成");

    session.loadMore();
    QVERIFY2(until([&] { return session.result().has_value() && session.result()->albums.size() == 2; }),
        "专辑第 2 页未追加");

    QCOMPARE(albumIDs(*session.result()), QStringList({QStringLiteral("test-p1"), QStringLiteral("test-p2")}));
    QVERIFY(session.result()->songs.isEmpty());
    QVERIFY(session.result()->artists.isEmpty());
    QVERIFY(session.result()->playlists.isEmpty());
}

void SearchSessionTests::testNoPaginationWhenHasMoreIsFalse()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 1;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("test"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return !session.isLoading(); }), "首搜未完成");

    QVERIFY(session.result().has_value());
    QVERIFY(!session.result()->hasMore);
    session.loadMore();
    QTest::qWait(50);
    QCOMPARE(provider.searchCalls.size(), 1);
}

void SearchSessionTests::testPaginationUsesCommittedQueryNotDraftOnPageTwo()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 3;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("原始词"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return !session.isLoading(); }), "首搜未完成");

    session.setDraftQuery(QStringLiteral("改过的词"));
    session.loadMore();
    QVERIFY2(until([&] { return provider.searchCalls.size() == 2; }), "分页未发出");

    QCOMPARE(provider.searchCalls.at(1).query, QStringLiteral("原始词"));
    QCOMPARE(session.activeQuery().value_or(QString()), QStringLiteral("原始词"));
    QCOMPARE(session.result()->songs.size(), 2);
}

void SearchSessionTests::testPaginationLockDropsConcurrentSecondCall()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 5;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("test"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return !session.isLoading(); }), "首搜未完成");

    session.loadMore();
    session.loadMore();
    QTest::qWait(120);

    QCOMPARE(provider.searchCalls.size(), 2);
    QCOMPARE(provider.searchCalls.at(0).page, 1);
    QCOMPARE(provider.searchCalls.at(1).page, 2);
    QCOMPARE(session.result()->songs.size(), 2);

    session.loadMore();
    QVERIFY2(until([&] { return session.result().has_value() && session.result()->songs.size() == 3; }),
        "第 3 页未追加");
    QCOMPARE(provider.searchCalls.size(), 3);
    QCOMPARE(provider.searchCalls.at(2).page, 3);
}

void SearchSessionTests::testIsEmptyRequiresAllFourEmpty()
{
    SearchResult result;
    QVERIFY(result.isEmpty());

    result = SearchResult{};
    Album album;
    album.id = QStringLiteral("1");
    album.name = QStringLiteral("A");
    result.albums.append(album);
    QVERIFY(!result.isEmpty());

    result = SearchResult{};
    Artist artist;
    artist.id = QStringLiteral("1");
    artist.name = QStringLiteral("A");
    result.artists.append(artist);
    QVERIFY(!result.isEmpty());

    result = SearchResult{};
    Playlist playlist;
    playlist.id = QStringLiteral("1");
    playlist.name = QStringLiteral("P");
    playlist.source = SongSource::Netease;
    result.playlists.append(playlist);
    QVERIFY(!result.isEmpty());

    result = SearchResult{};
    result.songs.append(makeSong(QStringLiteral("1")));
    QVERIFY(!result.isEmpty());
}

void SearchSessionTests::testResetClearsResultAndBlocksPagination()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 5;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("test"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");

    session.reset();
    QVERIFY(!session.result().has_value());
    QCOMPARE(session.draftQuery(), QString());
    QVERIFY(!session.hasActiveQuery());

    session.loadMore();
    QTest::qWait(50);
    QCOMPARE(provider.searchCalls.size(), 1);
}

void SearchSessionTests::testNewSearchInvalidatesPreviousResult()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 3;
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");

    session.setDraftQuery(QStringLiteral("B"));
    session.submit(SearchType::Artist);
    QVERIFY2(until([&] { return session.result().has_value() && session.result()->artists.size() == 1; }),
        "新搜索未生效");

    QCOMPARE(session.activeQuery().value_or(QString()), QStringLiteral("B"));
    QCOMPARE(session.displayType(), SearchType::Artist);
    QVERIFY(session.result()->songs.isEmpty());
    QCOMPARE(session.result()->artists.size(), 1);
}

void SearchSessionTests::testDisplayTypeFollowsCommittedQuery()
{
    StubMusicProvider provider;
    provider.searchTotalPages = 1;
    SearchSession session(&provider);
    QCOMPARE(session.displayType(), SearchType::Song);

    session.setDraftQuery(QStringLiteral("test"));
    session.submit(SearchType::Album);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");
    QCOMPARE(session.displayType(), SearchType::Album);

    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.displayType() == SearchType::Song; }), "displayType 未跟随");
    QCOMPARE(session.displayType(), SearchType::Song);
}

void SearchSessionTests::testCancelInFlightRollsBackInFlightPage()
{
    auto hangPage2 = std::make_shared<bool>(true);
    StubMusicProvider provider;
    provider.searchTotalPages = 5;
    provider.searchHandler = [hangPage2](QString query, SearchType type, int page, int,
                                   CancellationToken ct) -> Task<SearchResult> {
        if (page == 2 && *hangPage2) co_await Delay(60000, ct);
        co_return StubMusicProvider::page(query, type, page, page < 5);
    };
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("test"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return !session.isLoading(); }), "首搜未完成");
    QCOMPARE(session.currentPage(), 1);

    session.loadMore();
    QVERIFY(session.isLoadingMore());
    QCOMPARE(session.currentPage(), 2);
    QTest::qWait(30);

    session.cancelInFlight();

    QVERIFY(!session.isLoadingMore());
    QCOMPARE(session.currentPage(), 1);

    *hangPage2 = false;
    session.loadMore();
    QVERIFY2(until([&] { return provider.searchCalls.size() >= 3; }), "取消后再次翻页未发出");
    QCOMPARE(provider.searchCalls.last().page, 2);
}

void SearchSessionTests::testPaginationFailureKeepsResultAndSurfacesError()
{
    auto failPage2 = std::make_shared<bool>(true);
    StubMusicProvider provider;
    provider.searchTotalPages = 5;
    provider.searchHandler = [failPage2](QString query, SearchType type, int page, int,
                                   CancellationToken) -> Task<SearchResult> {
        if (page == 2 && *failPage2) throw MusicException::networkUnavailable();
        co_return StubMusicProvider::page(query, type, page, page < 5);
    };
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("test"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return !session.isLoading(); }), "首搜未完成");
    const int before = int(session.result()->songs.size());

    session.loadMore();
    QVERIFY2(until([&] { return session.paginationError().has_value(); }), "分页错误未暴露");

    QVERIFY(!session.errorMessage().has_value());
    QVERIFY(session.result().has_value());
    QCOMPARE(int(session.result()->songs.size()), before);
    QCOMPARE(session.currentPage(), 1);
    QVERIFY(!session.isLoadingMore());

    *failPage2 = false;
    session.loadMore();
    QVERIFY2(until([&] {
                 return session.result().has_value()
                     && session.result()->songs.size() == before + 1;
             }),
        "重试未成功");
    QVERIFY(!session.paginationError().has_value());
}

void SearchSessionTests::testFailedNewSearchDoesNotLeaveStaleResult()
{
    auto failB = std::make_shared<bool>(true);
    StubMusicProvider provider;
    provider.searchTotalPages = 3;
    provider.searchHandler = [failB](QString query, SearchType type, int page, int,
                                CancellationToken) -> Task<SearchResult> {
        if (query == QStringLiteral("B") && *failB) throw MusicException::networkUnavailable();
        co_return StubMusicProvider::page(query, type, page, page < 3);
    };
    SearchSession session(&provider);

    session.setDraftQuery(QStringLiteral("A"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] { return session.result().has_value(); }), "首搜未完成");
    const int callsAfterA = int(provider.searchCalls.size());

    session.setDraftQuery(QStringLiteral("B"));
    session.submit(SearchType::Song);
    QVERIFY2(until([&] {
                 return !session.isLoading() && session.errorMessage().has_value();
             }),
        "失败查询未结束");

    QVERIFY(!session.result().has_value());
    QCOMPARE(int(provider.searchCalls.size()), callsAfterA + 1);

    session.loadMore();
    QTest::qWait(50);
    QCOMPARE(int(provider.searchCalls.size()), callsAfterA + 1);
}

QTEST_MAIN(SearchSessionTests)
#include "tst_search_session.moc"
