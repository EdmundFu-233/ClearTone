#include <QtTest>

#include "Core/Security/CredentialStore.h"
#include "Core/Security/NeteaseCookieNormalizer.h"
#include "Providers/Netease/NeteaseProvider.h"

using namespace ct;

namespace {

const QStringList realWorldParts()
{
    return {
        QStringLiteral("MUSIC_R_T=1439570921116"),
        QStringLiteral("Max-Age=2147483647"),
        QStringLiteral("Expires=Mon, 18 Oct 2094 00:19:44 GMT"),
        QStringLiteral("Path=/openapi/clientlog"),
        QStringLiteral("MUSIC_A_T=1439570921113"),
        QStringLiteral("__csrf=b3e16df935cbc74e23017ffc0e6ea12c"),
        QStringLiteral("MUSIC_U=005BA38F62CFF322CC7F662320D503E7CE5BBC41"),
        QStringLiteral("MUSIC_SNS="),
        QStringLiteral("Max-Age=0"),
    };
}

const QString realWorldSample()
{
    return realWorldParts().join(QStringLiteral("; "));
}

} // namespace

class NeteaseCookieNormalizerTests : public QObject {
    Q_OBJECT

private slots:
    void testDropsCookieAttributes();
    void testKeepsRealCredentials();
    void testDropsEmptyValues();
    void testDeduplicatesRepeatedNames();
    void testRealWorldCookieShrinksToSixEntries();
    void testValueContainingEqualsIsPreserved();
    void testAlreadyNormalizedInputIsUnchanged();
    void testNormalizeIsIdempotent();
    void testEmptyAndGarbageInputProduceEmptyString();
    void testAttributeNamesAreCaseInsensitive();
    void testLoadLoginCookieDoesNotRecurseInForever();
};

void NeteaseCookieNormalizerTests::testDropsCookieAttributes()
{
    const QString result = NeteaseCookieNormalizer::normalize(realWorldSample());
    const QStringList attributes = {
        QStringLiteral("Expires="), QStringLiteral("Max-Age="), QStringLiteral("Path=")};
    for (const QString& attribute : attributes) {
        QVERIFY2(!result.contains(attribute), qPrintable(attribute));
    }
}

void NeteaseCookieNormalizerTests::testKeepsRealCredentials()
{
    const QString result = NeteaseCookieNormalizer::normalize(realWorldSample());
    QVERIFY(result.contains(QStringLiteral("__csrf=b3e16df935cbc74e23017ffc0e6ea12c")));
    QVERIFY(result.contains(QStringLiteral("MUSIC_U=005BA38F62CFF322CC7F662320D503E7CE5BBC41")));
}

void NeteaseCookieNormalizerTests::testDropsEmptyValues()
{
    const QString result = NeteaseCookieNormalizer::normalize(realWorldSample());
    QVERIFY(!result.contains(QStringLiteral("MUSIC_SNS")));
}

void NeteaseCookieNormalizerTests::testDeduplicatesRepeatedNames()
{
    const QString raw =
        QStringLiteral("MUSIC_R_U=AAAA; MUSIC_U=BBBB; Path=/x; MUSIC_R_U=CCCC");
    const QString result = NeteaseCookieNormalizer::normalize(raw);
    QCOMPARE(result, QStringLiteral("MUSIC_R_U=AAAA; MUSIC_U=BBBB"));
}

void NeteaseCookieNormalizerTests::testRealWorldCookieShrinksToSixEntries()
{
    const QStringList parts = {
        QStringLiteral("MUSIC_R_T=1"), QStringLiteral("Max-Age=2147483647"),
        QStringLiteral("Expires=Mon, 18 Oct 2094 00:19:44 GMT"), QStringLiteral("Path=/openapi/clientlog"),
        QStringLiteral("MUSIC_A_T=2"), QStringLiteral("Max-Age=2147483647"),
        QStringLiteral("Expires=Mon, 18 Oct 2094 00:19:44 GMT"), QStringLiteral("Path=/eapi/clientlog"),
        QStringLiteral("MUSIC_R_U=R"), QStringLiteral("Max-Age=15552000"),
        QStringLiteral("Expires=Sun, 28 Mar 2027 21:05:37 GMT"),
        QStringLiteral("Path=/eapi/login/token/refresh"),
        QStringLiteral("__csrf=CSRF"), QStringLiteral("Max-Age=1296010"),
        QStringLiteral("Expires=Wed, 14 Oct 2026 21:05:47 GMT"), QStringLiteral("Path=/"),
        QStringLiteral("MUSIC_R_U=R"), QStringLiteral("Max-Age=15552000"),
        QStringLiteral("Expires=Sun, 28 Mar 2027 21:05:37 GMT"),
        QStringLiteral("Path=/api/login/token/refresh"),
        QStringLiteral("MUSIC_U=U"), QStringLiteral("Max-Age=15552000"),
        QStringLiteral("Expires=Sun, 28 Mar 2027 21:05:37 GMT"), QStringLiteral("Path=/"),
        QStringLiteral("MUSIC_SNS="), QStringLiteral("Max-Age=0"),
        QStringLiteral("Expires=Tue, 29 Sep 2026 21:05:37 GMT"), QStringLiteral("Path=/"),
    };
    const QString result = NeteaseCookieNormalizer::normalize(parts.join(QStringLiteral("; ")));
    const QStringList pairs =
        result.split(QStringLiteral(";"), Qt::SkipEmptyParts);
    QCOMPARE(pairs.size(), 5);
    QCOMPARE(result,
        QStringLiteral("MUSIC_R_T=1; MUSIC_A_T=2; MUSIC_R_U=R; __csrf=CSRF; MUSIC_U=U"));
}

void NeteaseCookieNormalizerTests::testValueContainingEqualsIsPreserved()
{
    QCOMPARE(NeteaseCookieNormalizer::normalize(QStringLiteral("TOKEN=a=b=c; X=1")),
        QStringLiteral("TOKEN=a=b=c; X=1"));
}

void NeteaseCookieNormalizerTests::testAlreadyNormalizedInputIsUnchanged()
{
    const QString clean = QStringLiteral("MUSIC_U=U; __csrf=C");
    QCOMPARE(NeteaseCookieNormalizer::normalize(clean), clean);
}

void NeteaseCookieNormalizerTests::testNormalizeIsIdempotent()
{
    const QString once = NeteaseCookieNormalizer::normalize(realWorldSample());
    const QString twice = NeteaseCookieNormalizer::normalize(once);
    QCOMPARE(twice, once);
}

void NeteaseCookieNormalizerTests::testEmptyAndGarbageInputProduceEmptyString()
{
    QCOMPARE(NeteaseCookieNormalizer::normalize(QString()), QString());
    QCOMPARE(NeteaseCookieNormalizer::normalize(QStringLiteral("   ")), QString());
    QCOMPARE(NeteaseCookieNormalizer::normalize(QStringLiteral(";;;")), QString());
    QCOMPARE(NeteaseCookieNormalizer::normalize(QStringLiteral("no-equals-sign")), QString());
}

void NeteaseCookieNormalizerTests::testAttributeNamesAreCaseInsensitive()
{
    const QString result =
        NeteaseCookieNormalizer::normalize(QStringLiteral("A=1; expires=x; MAX-AGE=1; Path=/; b=2"));
    QCOMPARE(result, QStringLiteral("A=1; b=2"));
}

void NeteaseCookieNormalizerTests::testLoadLoginCookieDoesNotRecurseInForever()
{
    CredentialStore::shared().remove(CredentialKey::NeteaseCookie);
    CredentialStore::shared().save(
        QStringLiteral("MUSIC_U=U; Path=/; Max-Age=1; Expires=Mon, 18 Oct 2094 00:19:44 GMT; __csrf=C"),
        CredentialKey::NeteaseCookie);

    const auto cookie = NeteaseProvider::loadLoginCookie();
    QVERIFY(cookie.has_value());
    QCOMPARE(*cookie, QStringLiteral("MUSIC_U=U; __csrf=C"));
    QVERIFY(!cookie->contains(QStringLiteral("Expires=")));
    QVERIFY(!cookie->contains(QStringLiteral("Path=")));
    QVERIFY(!cookie->contains(QStringLiteral("Max-Age=")));

    CredentialStore::shared().remove(CredentialKey::NeteaseCookie);
    QVERIFY(!NeteaseProvider::loadLoginCookie().has_value());
}

QTEST_MAIN(NeteaseCookieNormalizerTests)
#include "tst_cookie_normalizer.moc"
