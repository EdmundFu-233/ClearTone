#include <QtTest>

#include "Core/Models/MusicError.h"
#include "Core/Networking/SessionExpiryGuard.h"

using namespace ct;

class SessionExpiryGuardTests : public QObject {
    Q_OBJECT

private slots:
    void testSingleRejectionNeverDeclaresExpiry();
    void testSecondRejectionAsksForProbe();
    void testProbeSucceedingKeepsSessionAlive();
    void testProbeFailingDeclaresExpiry();
    void testProbeResetsSuspicionCount();
    void testResetClearsSuspicionAndProbing();
    void testProbeInFlightSuppressesFurtherProbes();
    void testThresholdIsTwo();
    void testHelperAuthFailureIsDistinctFromSessionExpiry();
    void testRiskRejectionMessageDoesNotTellUserToRelogin();
};

void SessionExpiryGuardTests::testSingleRejectionNeverDeclaresExpiry()
{
    SessionExpiryGuard guard;
    QCOMPARE(guard.noteRejection(), SessionGuardDecision::Ignore);
    QCOMPARE(guard.suspicionCount(), 1);
}

void SessionExpiryGuardTests::testSecondRejectionAsksForProbe()
{
    SessionExpiryGuard guard;
    guard.noteRejection();
    QCOMPARE(guard.noteRejection(), SessionGuardDecision::ProbeSession);
    QVERIFY(guard.isProbing());
}

void SessionExpiryGuardTests::testProbeSucceedingKeepsSessionAlive()
{
    SessionExpiryGuard guard;
    guard.noteRejection();
    guard.noteRejection();
    QCOMPARE(guard.resolveProbe(true), SessionGuardDecision::SessionAlive);
}

void SessionExpiryGuardTests::testProbeFailingDeclaresExpiry()
{
    SessionExpiryGuard guard;
    guard.noteRejection();
    guard.noteRejection();
    QCOMPARE(guard.resolveProbe(false), SessionGuardDecision::SessionExpired);
}

void SessionExpiryGuardTests::testProbeResetsSuspicionCount()
{
    SessionExpiryGuard guard;
    guard.noteRejection();
    guard.noteRejection();
    guard.resolveProbe(true);
    QCOMPARE(guard.suspicionCount(), 0);
    QVERIFY(!guard.isProbing());
    QCOMPARE(guard.noteRejection(), SessionGuardDecision::Ignore);
}

void SessionExpiryGuardTests::testResetClearsSuspicionAndProbing()
{
    SessionExpiryGuard guard;
    guard.noteRejection();
    guard.noteRejection();
    QVERIFY(guard.isProbing());
    guard.reset();
    QCOMPARE(guard.suspicionCount(), 0);
    QVERIFY(!guard.isProbing());
}

void SessionExpiryGuardTests::testProbeInFlightSuppressesFurtherProbes()
{
    SessionExpiryGuard guard;
    guard.noteRejection();
    guard.noteRejection();
    QVERIFY(guard.isProbing());
    QCOMPARE(guard.noteRejection(), SessionGuardDecision::Ignore);
    QCOMPARE(guard.suspicionCount(), 3);
}

void SessionExpiryGuardTests::testThresholdIsTwo()
{
    QCOMPARE(SessionExpiryGuard::suspicionThreshold, 2);
    QVERIFY(SessionExpiryGuard::suspicionThreshold > 1);
}

void SessionExpiryGuardTests::testHelperAuthFailureIsDistinctFromSessionExpiry()
{
    QVERIFY(MusicException::sessionExpired() != MusicException::helperAuthFailed());
    QVERIFY(!MusicException::helperAuthFailed().isRetryable());
}

void SessionExpiryGuardTests::testRiskRejectionMessageDoesNotTellUserToRelogin()
{
    const MusicException error =
        MusicException::apiError(301, QStringLiteral("网易云拒绝了这次请求（可能被风控），稍后重试"));
    QVERIFY(!error.userFacingMessage().contains(QStringLiteral("重新登录")));
    QVERIFY(error.userFacingMessage().contains(QStringLiteral("风控")));
}

QTEST_MAIN(SessionExpiryGuardTests)
#include "tst_session_guard.moc"
