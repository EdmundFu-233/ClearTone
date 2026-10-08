#include <QtTest>

#include "Core/Search/SearchAssistStore.h"
#include "TestSupport.h"

using namespace ct;
using namespace ct::tests;

namespace {

QList<SearchSuggestion> oneSuggestion(const QString& title)
{
    SearchSuggestion suggestion;
    suggestion.title = title;
    suggestion.targetID = QStringLiteral("1");
    return {suggestion};
}

QList<HotSearchTerm> oneHotTerm(const QString& keyword, int score)
{
    HotSearchTerm term;
    term.keyword = keyword;
    term.score = score;
    return {term};
}

} // namespace

class SearchAssistStoreTests : public QObject {
    Q_OBJECT

private slots:
    void testEmptyKeywordClearsSuggestions();
    void testSuggestionsAreDebounced();
    void testSuggestionFailureIsSilent();
    void testHotTermsAreCachedInStore();
    void testClearSuggestionsResetsState();
    void testRecordSearchPrependsAndDeduplicates();
    void testRecordSearchIsCaseInsensitive();
    void testBlankSearchIsNotRecorded();
    void testHistoryIsCapped();
    void testRemoveAndClearHistory();
    void testHistoryPersists();
    void testCancelledHotTermsLoadDoesNotStickSpinner();
    void testHotTermsFailureIsSurfacedAndRetryable();
    void testRemoveHistoryIsCaseInsensitive();
    void testHistoryIsCappedOnLoad();
};

void SearchAssistStoreTests::testEmptyKeywordClearsSuggestions()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    SearchAssistStore store(&persistence, &source);

    store.querySuggestions(QString());
    QVERIFY(store.suggestions().isEmpty());
    QVERIFY(!store.isLoadingSuggestions());

    store.querySuggestions(QStringLiteral("   "));
    QVERIFY(store.suggestions().isEmpty());
}

void SearchAssistStoreTests::testSuggestionsAreDebounced()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    source.searchSuggestionsHandler = [](const QString&, CancellationToken) {
        return makeReadyTask(oneSuggestion(QStringLiteral("周杰伦")));
    };
    SearchAssistStore store(&persistence, &source);

    for (const QString& partial : {QStringLiteral("周"), QStringLiteral("周杰"), QStringLiteral("周杰伦"),
             QStringLiteral("周杰伦的")}) {
        store.querySuggestions(partial);
    }

    QVERIFY(source.suggestionCalls.isEmpty());
    QVERIFY(store.suggestions().isEmpty());

    QVERIFY2(until([&] {
                 return source.suggestionCalls.size() == 1 && !store.isLoadingSuggestions()
                     && !store.suggestions().isEmpty();
             }),
        "联想节流后未发起请求");

    QCOMPARE(source.suggestionCalls, QStringList{QStringLiteral("周杰伦的")});
    QCOMPARE(store.suggestions().size(), 1);
    QVERIFY(!store.isLoadingSuggestions());
}

void SearchAssistStoreTests::testSuggestionFailureIsSilent()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    source.searchSuggestionsHandler = [](const QString&, CancellationToken) -> Task<QList<SearchSuggestion>> {
        throw MusicException::networkUnavailable();
    };
    SearchAssistStore store(&persistence, &source);

    store.querySuggestions(QStringLiteral("test"));
    QVERIFY2(until([&] { return !source.suggestionCalls.isEmpty() && !store.isLoadingSuggestions(); }),
        "联想失败后 loading 未复位");

    QVERIFY(store.suggestions().isEmpty());
    QVERIFY(!store.isLoadingSuggestions());
}

void SearchAssistStoreTests::testHotTermsAreCachedInStore()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    source.hotSearchTermsHandler = [](CancellationToken) {
        return makeReadyTask(oneHotTerm(QStringLiteral("周杰伦"), 100));
    };
    SearchAssistStore store(&persistence, &source);

    syncWait(store.loadHotTermsAsync());
    syncWait(store.loadHotTermsAsync());

    QCOMPARE(source.hotCallCount, 1);
    QCOMPARE(store.hotTerms().size(), 1);
}

void SearchAssistStoreTests::testClearSuggestionsResetsState()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    source.searchSuggestionsHandler = [](const QString& keyword, CancellationToken) {
        return makeReadyTask(oneSuggestion(keyword));
    };
    SearchAssistStore store(&persistence, &source);

    store.querySuggestions(QStringLiteral("test"));
    store.clearSuggestions();
    QVERIFY(store.suggestions().isEmpty());

    QTest::qWait(600);
    QVERIFY(store.suggestions().isEmpty());
}

void SearchAssistStoreTests::testRecordSearchPrependsAndDeduplicates()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    SearchAssistStore store(&persistence, &source);

    store.recordSearch(QStringLiteral("周杰伦"));
    store.recordSearch(QStringLiteral("林俊杰"));
    QCOMPARE(store.history(),
        QStringList({QStringLiteral("林俊杰"), QStringLiteral("周杰伦")}));

    store.recordSearch(QStringLiteral("周杰伦"));
    QCOMPARE(store.history(),
        QStringList({QStringLiteral("周杰伦"), QStringLiteral("林俊杰")}));
}

void SearchAssistStoreTests::testRecordSearchIsCaseInsensitive()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    SearchAssistStore store(&persistence, &source);

    store.recordSearch(QStringLiteral("Adele"));
    store.recordSearch(QStringLiteral("adele"));

    QCOMPARE(store.history().size(), 1);
    QCOMPARE(store.history().at(0), QStringLiteral("adele"));
}

void SearchAssistStoreTests::testBlankSearchIsNotRecorded()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    SearchAssistStore store(&persistence, &source);

    store.recordSearch(QString());
    store.recordSearch(QStringLiteral("   \n "));

    QVERIFY(store.history().isEmpty());
}

void SearchAssistStoreTests::testHistoryIsCapped()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    SearchAssistStore store(&persistence, &source);

    for (int index = 0; index < 40; ++index) {
        store.recordSearch(QStringLiteral("词%1").arg(index));
    }

    QCOMPARE(store.history().size(), 20);
    QCOMPARE(store.history().at(0), QStringLiteral("词39"));
}

void SearchAssistStoreTests::testRemoveAndClearHistory()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    SearchAssistStore store(&persistence, &source);

    store.recordSearch(QStringLiteral("A"));
    store.recordSearch(QStringLiteral("B"));
    store.removeHistory(QStringLiteral("A"));
    QCOMPARE(store.history(), QStringList{QStringLiteral("B")});

    store.clearHistory();
    QVERIFY(store.history().isEmpty());
}

void SearchAssistStoreTests::testHistoryPersists()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    SearchAssistStore store(&persistence, &source);
    store.recordSearch(QStringLiteral("持久化测试"));

    SearchAssistStore reloaded(&persistence, &source);

    QCOMPARE(reloaded.history(), QStringList{QStringLiteral("持久化测试")});
}

void SearchAssistStoreTests::testCancelledHotTermsLoadDoesNotStickSpinner()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    source.hotSearchTermsHandler = [](CancellationToken ct) -> Task<QList<HotSearchTerm>> {
        co_await Delay(0, ct);
        co_return oneHotTerm(QStringLiteral("周杰伦"), 100);
    };
    SearchAssistStore store(&persistence, &source);

    CancellationTokenSource cts;
    cts.cancel();
    syncWait(store.loadHotTermsAsync(cts.token()));

    QVERIFY(!store.isLoadingHot());

    syncWait(store.loadHotTermsAsync());
    QCOMPARE(source.hotCallCount, 2);
    QCOMPARE(store.hotTerms().size(), 1);
}

void SearchAssistStoreTests::testHotTermsFailureIsSurfacedAndRetryable()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    auto failing = std::make_shared<bool>(true);
    source.hotSearchTermsHandler = [failing](CancellationToken) -> Task<QList<HotSearchTerm>> {
        if (*failing) throw MusicException::networkUnavailable();
        co_return oneHotTerm(QStringLiteral("重试"), 1);
    };
    SearchAssistStore store(&persistence, &source);

    syncWait(store.loadHotTermsAsync());
    QVERIFY(store.hotError().has_value());
    QVERIFY(!store.isLoadingHot());

    *failing = false;
    syncWait(store.loadHotTermsAsync());
    QVERIFY(!store.hotError().has_value());
    QCOMPARE(store.hotTerms().size(), 1);
}

void SearchAssistStoreTests::testRemoveHistoryIsCaseInsensitive()
{
    InMemorySearchAssistPersistence persistence;
    StubSocialProvider source;
    SearchAssistStore store(&persistence, &source);

    store.recordSearch(QStringLiteral("周杰伦"));
    store.removeHistory(QStringLiteral("周杰伦"));
    QVERIFY(store.history().isEmpty());

    store.recordSearch(QStringLiteral("Adele"));
    store.removeHistory(QStringLiteral("adele"));
    QVERIFY(store.history().isEmpty());
}

void SearchAssistStoreTests::testHistoryIsCappedOnLoad()
{
    InMemorySearchAssistPersistence persistence;
    for (int index = 0; index < 40; ++index) {
        persistence.storedHistory.append(QStringLiteral("旧词%1").arg(index));
    }
    StubSocialProvider source;

    SearchAssistStore store(&persistence, &source);

    QCOMPARE(store.history().size(), 20);
    QCOMPARE(store.history().at(0), QStringLiteral("旧词0"));
    QCOMPARE(store.history().at(19), QStringLiteral("旧词19"));
}

QTEST_MAIN(SearchAssistStoreTests)
#include "tst_search_assist.moc"
