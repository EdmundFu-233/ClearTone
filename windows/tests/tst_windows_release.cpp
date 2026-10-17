#include <QtTest>

#include "Core/Updates/WindowsRelease.h"

using namespace ct;

class WindowsReleaseTests : public QObject {
    Q_OBJECT

private slots:
    void comparesStableVersions();
    void acceptsOnlyWindowsAssetFromGithub();
};

void WindowsReleaseTests::comparesStableVersions()
{
    QVERIFY(updates::isNewer(QStringLiteral("v1.1.0"), QStringLiteral("1.0.9")));
    QVERIFY(updates::isNewer(QStringLiteral("v26.1"), QStringLiteral("1.0.4")));
    QVERIFY(!updates::isNewer(QStringLiteral("v26.1.0"), QStringLiteral("26.1")));
    QVERIFY(!updates::isNewer(QStringLiteral("v1.0.3"), QStringLiteral("1.0.3")));
    QVERIFY(!updates::isNewer(QStringLiteral("v26.1-rc1"), QStringLiteral("1.0.4")));
    QVERIFY(!updates::isNewer(QStringLiteral("v1.0.3-rc1"), QStringLiteral("1.0.2")));
}

void WindowsReleaseTests::acceptsOnlyWindowsAssetFromGithub()
{
    auto release = updates::parseLatestRelease(R"({"tag_name":"v1.0.4","assets":[
        {"name":"ClearTone-win-x86.zip","browser_download_url":"https://github.com/EdmundFu-233/ClearTone/releases/download/v1.0.4/ClearTone-win-x86.zip"},
        {"name":"ClearTone-win-x64.zip","browser_download_url":"https://github.com/EdmundFu-233/ClearTone/releases/download/v1.0.4/ClearTone-win-x64.zip"}]})");
    QVERIFY(release);
    QCOMPARE(release->version, QStringLiteral("v1.0.4"));
    QVERIFY(release->downloadUrl.isValid());

    release = updates::parseLatestRelease(R"({"tag_name":"v1.0.4","assets":[
        {"name":"ClearTone-win-x64.zip","browser_download_url":"https://evil.example/download.zip"}]})");
    QVERIFY(release);
    QVERIFY(release->downloadUrl.isEmpty());
    QVERIFY(!updates::parseLatestRelease(R"({"tag_name":"v1.0.4-rc1","assets":[]})"));

    release = updates::parseLatestRelease(R"({"tag_name":"v26.1","assets":[
        {"name":"ClearTone-win-x64.zip","browser_download_url":"https://github.com/EdmundFu-233/ClearTone/releases/download/v26.1/ClearTone-win-x64.zip"},
        {"name":"ClearTone-win-arm64.zip","browser_download_url":"https://github.com/EdmundFu-233/ClearTone/releases/download/v26.1/ClearTone-win-arm64.zip"}]})");
    QVERIFY(release);
    QCOMPARE(release->version, QStringLiteral("v26.1"));
#if defined(Q_PROCESSOR_ARM_64)
    QCOMPARE(release->downloadUrl.fileName(), QStringLiteral("ClearTone-win-arm64.zip"));
#else
    QCOMPARE(release->downloadUrl.fileName(), QStringLiteral("ClearTone-win-x64.zip"));
#endif
    release = updates::parseLatestRelease(R"({"tag_name":"v26.1","assets":[
        {"name":"ClearTone-win-x64.zip","browser_download_url":"https://github.com/EdmundFu-233/ClearTone/releases/download/v1.0.4/ClearTone-win-x64.zip"},
        {"name":"ClearTone-win-arm64.zip","browser_download_url":"https://github.com/EdmundFu-233/ClearTone/releases/download/v1.0.4/ClearTone-win-arm64.zip"}]})");
    QVERIFY(release);
    QVERIFY(release->downloadUrl.isEmpty());
}

QTEST_GUILESS_MAIN(WindowsReleaseTests)
#include "tst_windows_release.moc"
