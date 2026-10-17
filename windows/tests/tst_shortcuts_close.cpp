#include <QtTest>

#include "App/AppState.h"
#include "App/CloseBehaviorPolicy.h"
#include "App/SidebarShortcuts.h"
#include "App/TrayIconManager.h"
#include "Core/Networking/HelperProcessManager.h"
#include "Core/Persistence/AppSettings.h"
#include "Core/Persistence/PersistenceStore.h"
#include "MainWindow.h"

#include <QDir>

using namespace ct;

namespace {

const QList<CloseBehavior> allBehaviors()
{
    return {CloseBehavior::KeepPlaying, CloseBehavior::MinimizeToMenuBar, CloseBehavior::Quit};
}

} // namespace

class ShortcutsCloseTests : public QObject {
    Q_OBJECT

private slots:
    void quitIsTheOnlyBehaviorThatQuitsOnClose();
    void menuBarAlwaysVisibleWinsOverEveryBehaviorAndWindowState();
    void minimizeToMenuBarShowsTrayAtStartupAndWithoutVisibleWindows();
    void keepPlayingShowsTrayAtStartupAndWithoutVisibleWindows();
    void quitShowsTrayWhileWindowVisibleOnlyWithoutAlwaysVisible();
    void closingMainWindowSuspendsUiAndTrayReopensIt();

    void firstNinePagesUseOneThroughNine();
    void tenthPageReusesZeroInsteadOfTen();
    void everySidebarPageHasAKey();
    void outOfRangeIndexReturnsNull();
    void digitKeysAreUniqueSingleCharacters();
};

void ShortcutsCloseTests::quitIsTheOnlyBehaviorThatQuitsOnClose()
{
    for (const CloseBehavior behavior : allBehaviors()) {
        AppSettings settings;
        settings.closeBehavior = behavior;
        QCOMPARE(CloseBehaviorPolicy::shouldQuitOnClose(settings), behavior == CloseBehavior::Quit);
    }
}

void ShortcutsCloseTests::menuBarAlwaysVisibleWinsOverEveryBehaviorAndWindowState()
{
    for (const CloseBehavior behavior : allBehaviors()) {
        for (const bool visible : {true, false}) {
            AppSettings settings;
            settings.closeBehavior = behavior;
            settings.menuBarAlwaysVisible = true;
            QVERIFY(CloseBehaviorPolicy::trayIconShouldBeVisible(settings, visible));
        }
    }
}

void ShortcutsCloseTests::minimizeToMenuBarShowsTrayAtStartupAndWithoutVisibleWindows()
{
    AppSettings settings;
    settings.closeBehavior = CloseBehavior::MinimizeToMenuBar;
    QVERIFY(CloseBehaviorPolicy::trayIconShouldBeVisible(settings, true));
    QVERIFY(CloseBehaviorPolicy::trayIconShouldBeVisible(settings, false));
}

void ShortcutsCloseTests::keepPlayingShowsTrayAtStartupAndWithoutVisibleWindows()
{
    AppSettings settings;
    settings.closeBehavior = CloseBehavior::KeepPlaying;
    QVERIFY(CloseBehaviorPolicy::trayIconShouldBeVisible(settings, true));
    QVERIFY(CloseBehaviorPolicy::trayIconShouldBeVisible(settings, false));
}

void ShortcutsCloseTests::quitShowsTrayWhileWindowVisibleOnlyWithoutAlwaysVisible()
{
    AppSettings settings;
    settings.closeBehavior = CloseBehavior::Quit;
    QVERIFY(CloseBehaviorPolicy::trayIconShouldBeVisible(settings, true));
    QVERIFY(!CloseBehaviorPolicy::trayIconShouldBeVisible(settings, false));
}

void ShortcutsCloseTests::closingMainWindowSuspendsUiAndTrayReopensIt()
{
    const QString emptyHelper = QDir::tempPath() + QStringLiteral("/cleartone-close-no-helper");
    QDir().mkpath(emptyHelper);
    qputenv("CLEARTONE_HELPER_ROOT", emptyHelper.toUtf8());

    AppSettings settings;
    settings.closeBehavior = CloseBehavior::KeepPlaying;
    PersistenceStore::shared().saveSetting(QStringLiteral("appSettings"), settings.toJson());

    MainWindow window;
    TrayIconManager::shared().initialize(&window);
    window.show();
    QTest::qWait(20);
    QVERIFY(!window.isUiSuspended());
    QVERIFY(window.centralWidget() != nullptr);

    window.close();
    QTest::qWait(20);
    QVERIFY(!window.isVisible());
    QVERIFY(window.isUiSuspended());
    QCOMPARE(window.centralWidget(), nullptr);

    TrayIconManager::shared().showMainWindow();
    QTest::qWait(20);
    QVERIFY(window.isVisible());
    QVERIFY(!window.isUiSuspended());
    QVERIFY(window.centralWidget() != nullptr);

    HelperProcessManager::shared().stop();
}

void ShortcutsCloseTests::firstNinePagesUseOneThroughNine()
{
    for (int index = 0; index < 9; ++index) {
        const auto key = SidebarShortcuts::keyForIndex(index);
        QVERIFY(key.has_value());
        QVERIFY(*key == QChar(static_cast<char16_t>(u'1' + index)));
    }
}

void ShortcutsCloseTests::tenthPageReusesZeroInsteadOfTen()
{
    const auto key = SidebarShortcuts::keyForIndex(9);
    QVERIFY(key.has_value());
    QVERIFY(*key == QChar(static_cast<char16_t>(u'0')));
}

void ShortcutsCloseTests::everySidebarPageHasAKey()
{
    const QList<Page> pages = page::sidebarPages();
    QVERIFY(pages.size() >= 10);
    for (int index = 0; index < pages.size(); ++index) {
        QVERIFY(SidebarShortcuts::keyForIndex(index).has_value());
    }
}

void ShortcutsCloseTests::outOfRangeIndexReturnsNull()
{
    QVERIFY(!SidebarShortcuts::keyForIndex(-1).has_value());
    QVERIFY(!SidebarShortcuts::keyForIndex(10).has_value());
    QVERIFY(!SidebarShortcuts::keyForIndex(999).has_value());
}

void ShortcutsCloseTests::digitKeysAreUniqueSingleCharacters()
{
    const QList<QChar>& keys = SidebarShortcuts::DigitKeys;
    QCOMPARE(keys.size(), 10);
    QSet<QChar> distinct;
    for (const QChar& key : keys) {
        QVERIFY(key >= QLatin1Char('0') && key <= QLatin1Char('9'));
        distinct.insert(key);
    }
    QCOMPARE(distinct.size(), keys.size());
}

QTEST_MAIN(ShortcutsCloseTests)
#include "tst_shortcuts_close.moc"
