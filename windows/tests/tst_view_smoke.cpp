#include <QtTest>

#include "App/AppState.h"
#include "Features/Shared/PageFactory.h"

#include <QDir>

using namespace ct;

namespace {

QList<Page> allPages()
{
    return {
        Page::Discover,
        Page::Search,
        Page::TopList,
        Page::Radio,
        Page::PersonalFM,
        Page::MyMusic,
        Page::Liked,
        Page::Local,
        Page::Recent,
        Page::Messages,
        Page::Profile,
        Page::PlaylistDetail,
        Page::RadioDetail,
        Page::AlbumDetail,
        Page::ArtistDetail,
        Page::SongComments,
        Page::Settings,
    };
}

QList<OverlayKind> allOverlays()
{
    return {
        OverlayKind::NowPlaying,
        OverlayKind::Queue,
        OverlayKind::Login,
    };
}

} // namespace

class ViewSmokeTests : public QObject {
    Q_OBJECT

private slots:
    void initTestCase();
    void everyPageHasARegisteredView();
    void everyOverlayHasARegisteredView();
    void everyViewConstructs();
};

void ViewSmokeTests::initTestCase()
{
    // 让辅助进程查找快速失败，避免视图构造触发的请求真的联网或起 Node。
    const QString helperDir =
        QDir(QDir::tempPath()).filePath(QStringLiteral("cleartone-smoke-helper-missing"));
    QDir().mkpath(helperDir);
    qputenv("CLEARTONE_HELPER_ROOT", helperDir.toUtf8());
    qputenv("CLEARTONE_HELPER_NODE", QByteArray("/nonexistent/node"));
}

void ViewSmokeTests::everyPageHasARegisteredView()
{
    const QList<Page> registered = PageFactory::registeredPages();
    for (Page page : allPages()) {
        QVERIFY2(registered.contains(page),
            qPrintable(QStringLiteral("page %1 (%2)")
                           .arg(static_cast<int>(page))
                           .arg(page::displayName(page))));
    }
}

void ViewSmokeTests::everyOverlayHasARegisteredView()
{
    const QList<OverlayKind> registered = PageFactory::registeredOverlays();
    for (OverlayKind kind : allOverlays()) {
        QVERIFY2(registered.contains(kind), qPrintable(QString::number(static_cast<int>(kind))));
    }
}

void ViewSmokeTests::everyViewConstructs()
{
    for (Page page : allPages()) {
        QWidget* widget = PageFactory::resolve(page);
        QVERIFY2(widget != nullptr, qPrintable(page::displayName(page)));
        PageFactory::invalidate(page);
    }
    for (OverlayKind kind : allOverlays()) {
        QWidget* widget = PageFactory::resolveOverlay(kind);
        QVERIFY(widget != nullptr);
        PageFactory::invalidateOverlay(kind);
    }
    QTest::qWait(50);
}

QTEST_MAIN(ViewSmokeTests)
#include "tst_view_smoke.moc"
