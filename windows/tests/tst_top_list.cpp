#include <QtTest>

#include "Core/Discover/TopListSession.h"
#include "TestSupport.h"

#include <memory>
#include <vector>

using namespace ct;
using namespace ct::tests;

namespace {

TopList makeList(const QString& id, const QString& name = QStringLiteral("飙升榜"))
{
    TopList list;
    list.id = id;
    list.name = name;
    list.trackCount = 100;
    return list;
}

QStringList listIDs(const QList<TopList>& lists)
{
    QStringList ids;
    for (const TopList& list : lists) ids.append(list.id);
    return ids;
}

} // namespace

class TopListSessionTests : public QObject {
    Q_OBJECT

private slots:
    void testLoadPopulatesLists();
    void testFailureKeepsExistingListsAndSurfacesError();
    void testCancelledLoadResetsLoading();
    void testLateResponseFromOlderLoadIsDiscarded();
};

void TopListSessionTests::testLoadPopulatesLists()
{
    StubSocialProvider source;
    source.topListsHandler = [](CancellationToken) {
        return makeReadyTask(
            QList<TopList>{makeList(QStringLiteral("19723756"), QStringLiteral("飙升榜")),
                makeList(QStringLiteral("3779629"))});
    };
    TopListSession session(&source);

    syncWait(session.loadAsync());

    QCOMPARE(listIDs(session.lists()),
        QStringList({QStringLiteral("19723756"), QStringLiteral("3779629")}));
    QVERIFY(!session.errorMessage().has_value());
    QVERIFY(!session.isLoading());
}

void TopListSessionTests::testFailureKeepsExistingListsAndSurfacesError()
{
    StubSocialProvider source;
    auto failing = std::make_shared<bool>(false);
    source.topListsHandler = [failing](CancellationToken) -> Task<QList<TopList>> {
        if (*failing) throw MusicException::networkUnavailable();
        co_return QList<TopList>{makeList(QStringLiteral("1"))};
    };
    TopListSession session(&source);
    syncWait(session.loadAsync());
    QCOMPARE(session.lists().size(), 1);

    *failing = true;
    syncWait(session.loadAsync());

    QCOMPARE(listIDs(session.lists()), QStringList{QStringLiteral("1")});
    QVERIFY(session.errorMessage().has_value());
    QVERIFY(!session.isLoading());
}

void TopListSessionTests::testCancelledLoadResetsLoading()
{
    StubSocialProvider source;
    source.topListsHandler = [](CancellationToken ct) -> Task<QList<TopList>> {
        co_await Delay(60000, ct);
        co_return QList<TopList>{};
    };
    TopListSession session(&source);

    CancellationTokenSource cts;
    auto task = session.loadAsync(cts.token());
    task.start();
    QVERIFY(session.isLoading());

    cts.cancel();
    QVERIFY2(until([&] { return task.isDone(); }), "取消后加载未结束");

    QVERIFY(!session.isLoading());
}

void TopListSessionTests::testLateResponseFromOlderLoadIsDiscarded()
{
    std::vector<std::shared_ptr<TestGate>> gates{std::make_shared<TestGate>(),
        std::make_shared<TestGate>()};
    auto current = std::make_shared<QList<TopList>>();
    current->append(makeList(QStringLiteral("old")));
    auto calls = std::make_shared<int>(0);

    StubSocialProvider source;
    source.topListsHandler = [gates, current, calls](CancellationToken) -> Task<QList<TopList>> {
        const int index = (*calls)++;
        co_await *gates[index];
        co_return *current;
    };
    TopListSession session(&source);

    auto first = session.loadAsync();
    first.start();
    QVERIFY2(until([&] { return source.topListCallCount == 1; }), "第一次请求未发出");
    auto second = session.loadAsync();
    second.start();
    QVERIFY2(until([&] { return source.topListCallCount == 2; }), "第二次请求未发出");

    *current = QList<TopList>{makeList(QStringLiteral("new"))};
    gates[1]->open();
    QVERIFY2(until([&] { return second.isDone(); }), "第二次请求未完成");
    QCOMPARE(listIDs(session.lists()), QStringList{QStringLiteral("new")});

    *current = QList<TopList>{makeList(QStringLiteral("old"))};
    gates[0]->open();
    QVERIFY2(until([&] { return first.isDone(); }), "第一次请求未完成");

    QCOMPARE(listIDs(session.lists()), QStringList{QStringLiteral("new")});
    QVERIFY(!session.isLoading());
}

QTEST_MAIN(TopListSessionTests)
#include "tst_top_list.moc"
