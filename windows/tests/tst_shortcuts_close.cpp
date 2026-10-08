#include <QtTest>

#include "App/AppState.h"
#include "App/CloseBehaviorPolicy.h"
#include "App/SidebarShortcuts.h"
#include "Core/Persistence/AppSettings.h"

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
    void minimizeToMenuBarShowsTrayOnlyWithoutVisibleWindows();
    void keepPlayingKeepsTrayAvailableWithoutVisibleWindows();
    void quitNeverShowsTrayWithoutAlwaysVisible();

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

void ShortcutsCloseTests::minimizeToMenuBarShowsTrayOnlyWithoutVisibleWindows()
{
    AppSettings settings;
    settings.closeBehavior = CloseBehavior::MinimizeToMenuBar;
    QVERIFY(!CloseBehaviorPolicy::trayIconShouldBeVisible(settings, true));
    QVERIFY(CloseBehaviorPolicy::trayIconShouldBeVisible(settings, false));
}

void ShortcutsCloseTests::keepPlayingKeepsTrayAvailableWithoutVisibleWindows()
{
    AppSettings settings;
    settings.closeBehavior = CloseBehavior::KeepPlaying;
    QVERIFY(!CloseBehaviorPolicy::trayIconShouldBeVisible(settings, true));
    QVERIFY(CloseBehaviorPolicy::trayIconShouldBeVisible(settings, false));
}

void ShortcutsCloseTests::quitNeverShowsTrayWithoutAlwaysVisible()
{
    AppSettings settings;
    settings.closeBehavior = CloseBehavior::Quit;
    QVERIFY(!CloseBehaviorPolicy::trayIconShouldBeVisible(settings, true));
    QVERIFY(!CloseBehaviorPolicy::trayIconShouldBeVisible(settings, false));
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
