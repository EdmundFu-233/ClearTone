#include <QtTest>

#include "Rendering/InFlightGate.h"

#include <thread>
#include <vector>

using namespace ct;

class InFlightGateTests : public QObject {
    Q_OBJECT

private slots:
    void testAcquireSucceedsUntilFull();
    void testReleaseUnblocksSubsequentFrames();
    void testReleaseNeverGoesNegative();
    void testConcurrentAcquireNeverExceedsMax();
    void testBalancedTrafficAlwaysReturnsToZero();
};

void InFlightGateTests::testAcquireSucceedsUntilFull()
{
    InFlightGate gate(2);
    QVERIFY(gate.tryAcquire());
    QVERIFY(gate.tryAcquire());
    QVERIFY(!gate.tryAcquire());
    QVERIFY(gate.isFull());
}

void InFlightGateTests::testReleaseUnblocksSubsequentFrames()
{
    InFlightGate gate(2);
    gate.tryAcquire();
    gate.tryAcquire();
    QVERIFY(!gate.tryAcquire());

    gate.release();
    QVERIFY(!gate.isFull());
    QVERIFY(gate.tryAcquire());
}

void InFlightGateTests::testReleaseNeverGoesNegative()
{
    InFlightGate gate(2);
    gate.release();
    gate.release();
    QCOMPARE(gate.inFlight(), 0);
    QVERIFY(gate.tryAcquire());
    QCOMPARE(gate.inFlight(), 1);
}

void InFlightGateTests::testConcurrentAcquireNeverExceedsMax()
{
    InFlightGate gate(2);

    std::vector<std::thread> workers;
    workers.reserve(16);
    for (int worker = 0; worker < 16; ++worker) {
        workers.emplace_back([&gate] {
            for (int iteration = 0; iteration < 500; ++iteration) gate.tryAcquire();
        });
    }
    for (std::thread& worker : workers) worker.join();

    QCOMPARE(gate.inFlight(), gate.maxInFlight());
    gate.release();
    gate.release();
    QCOMPARE(gate.inFlight(), 0);
    QVERIFY(gate.tryAcquire());
}

void InFlightGateTests::testBalancedTrafficAlwaysReturnsToZero()
{
    InFlightGate gate(4);

    std::vector<std::thread> workers;
    workers.reserve(8);
    for (int worker = 0; worker < 8; ++worker) {
        workers.emplace_back([&gate] {
            for (int iteration = 0; iteration < 1000; ++iteration) {
                if (gate.tryAcquire()) gate.release();
            }
        });
    }
    for (std::thread& worker : workers) worker.join();

    QCOMPARE(gate.inFlight(), 0);
    QVERIFY(gate.tryAcquire());
}

QTEST_MAIN(InFlightGateTests)
#include "tst_inflight_gate.moc"
