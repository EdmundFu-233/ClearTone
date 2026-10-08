#include <QtTest>

#include "Core/Async.h"

using namespace ct;

namespace {

struct TimerAwaitable {
    int ms = 0;

    bool await_ready() const noexcept { return ms <= 0; }

    void await_suspend(std::coroutine_handle<> handle) const
    {
        QTimer::singleShot(ms, [handle] { detail::resumeOnLoop(handle); });
    }

    void await_resume() const noexcept {}
};

Task<int> delayedInt(int ms, int value)
{
    co_await TimerAwaitable{ms};
    co_return value;
}

Task<void> delayedFlag(int ms, bool* flag)
{
    co_await TimerAwaitable{ms};
    *flag = true;
}

Task<void> delayedThrow(int ms)
{
    co_await TimerAwaitable{ms};
    throw MusicException(MusicErrorKind::RateLimited);
}

Task<int> chain()
{
    const int first = co_await delayedInt(10, 20);
    const int second = co_await delayedInt(10, first + 22);
    co_return second;
}

struct ImmediateStarter {
    static Awaitable<int> make(int value)
    {
        return Awaitable<int>{[value](Callback<int> callback) {
            callback(Result<int>::success(value));
        }};
    }
};

Task<int> awaitImmediate(int value)
{
    const int result = co_await ImmediateStarter::make(value);
    co_await TimerAwaitable{5};
    co_return result * 2;
}

Task<int> awaitFailure()
{
    Awaitable<int> awaitable{[&](Callback<int> callback) {
        callback(Result<int>::failure(MusicException(MusicErrorKind::NotLoggedIn)));
    }};
    co_return co_await awaitable;
}

} // namespace

class AsyncTests : public QObject {
    Q_OBJECT

private slots:
    void resultCarriesValueOrError();
    void readyTaskCompletesWithSyncWait();
    void chainedTaskCompletesAsynchronously();
    void awaitableBridgesCallbackStyle();
    void awaitFailureRethrowsMusicException();
    void cancellationCallbacksFireOnce();
    void detachedTaskSurvivesDroppedHandle();
    void detachedFailingTaskDoesNotCrash();
};

void AsyncTests::resultCarriesValueOrError()
{
    auto ok = Result<QString>::success(QStringLiteral("hello"));
    QVERIFY(ok.isSuccess());
    QCOMPARE(ok.value(), QStringLiteral("hello"));

    auto failed = Result<QString>::failure(MusicException::rateLimited());
    QVERIFY(failed.isFailure());
    QCOMPARE(failed.error().kind(), MusicErrorKind::RateLimited);
    QVERIFY(failed.error().isRetryable());
}

void AsyncTests::readyTaskCompletesWithSyncWait()
{
    QCOMPARE(syncWait(makeReadyTask<int>(7)), 7);
}

void AsyncTests::chainedTaskCompletesAsynchronously()
{
    QCOMPARE(syncWait(chain()), 42);
}

void AsyncTests::awaitableBridgesCallbackStyle()
{
    QCOMPARE(syncWait(awaitImmediate(21)), 42);
}

void AsyncTests::awaitFailureRethrowsMusicException()
{
    try {
        syncWait(awaitFailure());
        QFAIL("expected MusicException");
    } catch (const MusicException& error) {
        QCOMPARE(error.kind(), MusicErrorKind::NotLoggedIn);
    }
}

void AsyncTests::cancellationCallbacksFireOnce()
{
    CancellationTokenSource source;
    const auto token = source.token();
    QVERIFY(!token.isCancellationRequested());

    int fired = 0;
    const int id = token.registerCallback([&] { ++fired; });
    QVERIFY(id > 0);

    source.cancel();
    QVERIFY(source.isCancellationRequested());
    QCOMPARE(fired, 1);

    int late = 0;
    token.registerCallback([&] { ++late; });
    QCOMPARE(late, 1);

    token.unregisterCallback(id);
    source.cancel();
    QCOMPARE(fired, 1);
}

void AsyncTests::detachedTaskSurvivesDroppedHandle()
{
    bool finished = false;
    detach(delayedFlag(15, &finished));
    QTest::qWait(80);
    QVERIFY(finished);
}

void AsyncTests::detachedFailingTaskDoesNotCrash()
{
    detach(delayedThrow(5));
    QTest::qWait(30);
    QVERIFY(true);
}

QTEST_MAIN(AsyncTests)
#include "tst_async.moc"
