#include <QtTest>

#include "Core/Async.h"
#include "Core/Logging/CTLog.h"
#include "Core/Models/MusicError.h"
#include "Core/Networking/HTTPClient.h"

#include <QNetworkReply>

using namespace ct;

namespace {

Task<void> waitForCancel(CancellationToken ct)
{
    co_await Delay(10, ct);
}

} // namespace

class ErrorSanitizationTests : public QObject {
    Q_OBJECT

private slots:
    void testJSONShapedCredentialsAreRedacted();
    void testQueryShapedCredentialsAreRedacted();
    void testCookieHeaderIsRedacted();
    void testBearerTokenValueWithSpacesIsFullyRedacted();
    void testPreviouslyMissedKeysAreCovered();
    void testNormalMessagesAndLookalikeWordsAreUntouched();
    void testNetworkErrorsMapToStableChineseMessages();
    void testURLErrorMappingDistinguishesHelperBackedPlatforms();
    void testCancellationIsNotSwallowedIntoUnknownError();
    void testMusicErrorPassesThrough();
    void testUnknownErrorDoesNotLeakLocalizedDescription();
    void testRetryableClassification();
    void testUserFacingMessageIsSanitized();
    void testErrorProtocolUserMessagePrefersMusicErrorText();
    void testRequestTimeoutIsNeutralAndRetryable();
};

void ErrorSanitizationTests::testJSONShapedCredentialsAreRedacted()
{
    const QString output =
        CTLog::sanitize(QStringLiteral("{\"MUSIC_U\":\"abc123def\",\"MUSIC_A\":\"99887766\"}"));
    QVERIFY(!output.contains(QStringLiteral("abc123def")));
    QVERIFY(!output.contains(QStringLiteral("99887766")));
    QVERIFY(output.contains(QStringLiteral("MUSIC_U")));
}

void ErrorSanitizationTests::testQueryShapedCredentialsAreRedacted()
{
    const QString output = CTLog::sanitize(QStringLiteral("MUSIC_U=1a2b3c4d5e&other=keep"));
    QVERIFY(!output.contains(QStringLiteral("1a2b3c4d5e")));
    QVERIFY(output.contains(QStringLiteral("other=keep")));
}

void ErrorSanitizationTests::testCookieHeaderIsRedacted()
{
    const QString output = CTLog::sanitize(QStringLiteral("Cookie: MUSIC_U=xyz; __csrf=qqq; MTgI4.json"));
    QVERIFY(!output.contains(QStringLiteral("xyz")));
    QVERIFY(!output.contains(QStringLiteral("qqq")));
    QVERIFY(output.contains(QStringLiteral("MTgI4.json")));
}

void ErrorSanitizationTests::testBearerTokenValueWithSpacesIsFullyRedacted()
{
    const QString jwt = QStringLiteral("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdef");
    const QString output = CTLog::sanitize(QStringLiteral("authorization=Bearer %1").arg(jwt));
    QVERIFY(!output.contains(jwt));
    QVERIFY(!output.contains(QStringLiteral("Bearer eyJ")));
}

void ErrorSanitizationTests::testPreviouslyMissedKeysAreCovered()
{
    const QStringList keys = {QStringLiteral("MUSIC_A"), QStringLiteral("MUSIC_R"),
        QStringLiteral("__remember_me"), QStringLiteral("NMTID"), QStringLiteral("password"),
        QStringLiteral("secret")};
    for (const QString& key : keys) {
        const QString output = CTLog::sanitize(QStringLiteral("%1=s3cr3t-value").arg(key));
        QVERIFY2(!output.contains(QStringLiteral("s3cr3t-value")), qPrintable(key));
    }
}

void ErrorSanitizationTests::testNormalMessagesAndLookalikeWordsAreUntouched()
{
    const QString message = QStringLiteral("加载歌单失败：接口错误 (400)：参数不对");
    QCOMPARE(CTLog::sanitize(message), message);

    const QStringList lookalikes = {QStringLiteral("cacheKey=abc"), QStringLiteral("monkey=def"),
        QStringLiteral("hotkey=1"), QStringLiteral("keyboard=zzz")};
    for (const QString& lookalike : lookalikes) {
        QCOMPARE(CTLog::sanitize(lookalike), lookalike);
    }
}

void ErrorSanitizationTests::testNetworkErrorsMapToStableChineseMessages()
{
    QCOMPARE(mapReplyError(QNetworkReply::HostNotFoundError, 0, false).kind(),
        MusicErrorKind::NetworkUnavailable);
    QCOMPARE(mapReplyError(QNetworkReply::UnknownNetworkError, 0, false).kind(),
        MusicErrorKind::NetworkUnavailable);
    const MusicException timeout = mapReplyError(QNetworkReply::TimeoutError, 0, true);
    QCOMPARE(timeout.kind(), MusicErrorKind::HelperProcessTimeout);
    QCOMPARE(timeout.message(), QStringLiteral("本地服务响应超时"));

    // C++ 平台分岔：直连（非本地辅助进程）的超时是 RequestTimeout。
    QCOMPARE(mapReplyError(QNetworkReply::TimeoutError, 0, false).kind(),
        MusicErrorKind::RequestTimeout);
}

void ErrorSanitizationTests::testURLErrorMappingDistinguishesHelperBackedPlatforms()
{
    QSKIP("Apple-only: URLError/helperBacked platform split does not exist on Windows; "
          "HttpRequestException/SocketException mapping is covered instead");
}

void ErrorSanitizationTests::testCancellationIsNotSwallowedIntoUnknownError()
{
    CancellationTokenSource source;
    source.cancel();
    try {
        syncWait(waitForCancel(source.token()));
        QFAIL("expected MusicException");
    } catch (const MusicException& error) {
        QCOMPARE(error.kind(), MusicErrorKind::Cancelled);
    }
}

void ErrorSanitizationTests::testMusicErrorPassesThrough()
{
    QVERIFY(MusicException::rateLimited() == MusicException::rateLimited());
    QVERIFY(MusicException::apiError(400, QStringLiteral("x"))
        == MusicException::apiError(400, QStringLiteral("x")));
    QVERIFY(MusicException::apiError(400, QStringLiteral("x"))
        != MusicException::apiError(400, QStringLiteral("y")));
}

void ErrorSanitizationTests::testUnknownErrorDoesNotLeakLocalizedDescription()
{
    const MusicException mapped = mapReplyError(QNetworkReply::UnknownServerError, 0, false);
    QCOMPARE(mapped.kind(), MusicErrorKind::Unknown);
    QVERIFY(!mapped.message().contains(QStringLiteral("couldn")));
}

void ErrorSanitizationTests::testRetryableClassification()
{
    QVERIFY(MusicException::networkUnavailable().isRetryable());
    QVERIFY(MusicException::rateLimited().isRetryable());
    QVERIFY(MusicException::apiError(502, QString()).isRetryable());
    QVERIFY(MusicException::apiError(429, QString()).isRetryable());
    QVERIFY(!MusicException::apiError(400, QString()).isRetryable());
    QVERIFY(!MusicException::notLoggedIn().isRetryable());
    QVERIFY(!MusicException::cancelled().isRetryable());
}

void ErrorSanitizationTests::testUserFacingMessageIsSanitized()
{
    const MusicException error =
        MusicException::apiError(400, QStringLiteral("invalid cookie {\"MUSIC_U\":\"leaked-token\"}"));
    QVERIFY(!error.userFacingMessage().contains(QStringLiteral("leaked-token")));
}

void ErrorSanitizationTests::testErrorProtocolUserMessagePrefersMusicErrorText()
{
    const MusicException error = MusicException::notLoggedIn();
    QCOMPARE(error.userFacingMessage(), error.message());
    QVERIFY(!error.userFacingMessage().isEmpty());
}

void ErrorSanitizationTests::testRequestTimeoutIsNeutralAndRetryable()
{
    QCOMPARE(MusicException::requestTimeout().message(), QStringLiteral("请求超时，请稍后重试"));
    QVERIFY(MusicException::requestTimeout().isRetryable());
    QCOMPARE(MusicException::requestTimeout().userFacingMessage(),
        QStringLiteral("请求超时，请稍后重试"));
}

QTEST_MAIN(ErrorSanitizationTests)
#include "tst_error_sanitization.moc"
