#include <QtTest>
#include <QComboBox>
#include <QDir>
#include <QFontDatabase>
#include <QLineEdit>
#include <QListWidget>
#include <QRawFont>
#include <QScrollArea>
#include <QSlider>
#include <QStackedWidget>
#include <QStyleFactory>
#include <QVBoxLayout>
#include "App/AppState.h"
#include "Core/Networking/HelperProcessManager.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "DesignSystem/FlowLayout.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "MainWindow.h"

using namespace ct;

class GuiLayoutTests : public QObject {
    Q_OBJECT
private:
    std::unique_ptr<MainWindow> m_window;
    void capture(const QString& name, QWidget* widget)
    {
        const QString directory = qEnvironmentVariable("CT_GUI_SCREENSHOTS");
        if (directory.isEmpty()) return;
        QDir().mkpath(directory);
        QVERIFY(widget->grab().save(QDir(directory).filePath(name + QStringLiteral(".png"))));
    }
private slots:
    void initTestCase()
    {
        QVERIFY(!qEnvironmentVariableIsEmpty("CLEARTONE_TEST_STORAGE_DIR"));
        const auto missing = QDir::tempPath() + QStringLiteral("/cleartone-gui-helper-empty");
        QDir().mkpath(missing);
        qputenv("CLEARTONE_HELPER_ROOT", missing.toUtf8());
        qputenv("CLEARTONE_HELPER_NODE", "/nonexistent/node");
        QApplication::setStyle(QStyleFactory::create("Fusion"));
        AppState::shared().switchToTopLevel(Page::Recent);
        m_window = std::make_unique<MainWindow>();
        m_window->show();
        QTest::qWait(40);
    }
    void iconsDoNotRequireWindowsFonts()
    {
        CTTheme::apply(CTThemeMode::Light);
        QVERIFY(QFontDatabase::families().contains(QStringLiteral("lucide")));
        const auto font = QRawFont::fromFont(QFont(QStringLiteral("lucide"), 20));
        for (Page page : page::sidebarPages()) {
            const auto glyphs = font.glyphIndexesForString(page::glyph(page));
            QCOMPARE(glyphs.size(), 1);
            QVERIFY(glyphs.first() != 0);
        }
        QVERIFY(!CTTheme::icon(page::glyph(Page::Search)).isNull());
    }
    void cardsReflowWithoutHorizontalClipping()
    {
        QList<QWidget*> cards;
        for (int i = 0; i < 12; ++i) {
            Playlist playlist;
            playlist.name = QStringLiteral("这是需要被省略而不能撑开布局的长歌单名称 %1").arg(i);
            cards.append(ui::playlistCard(playlist, [](const Playlist&) {}));
        }
        std::unique_ptr<QWidget> grid(ui::cardGrid(cards));
        grid->show();
        for (int width : {420, 620, 920}) {
            grid->resize(width, grid->layout()->heightForWidth(width));
            QTest::qWait(10);
            for (QWidget* card : cards) {
                QVERIFY(grid->rect().contains(card->geometry()));
                auto* cover = card->findChild<CoverImage*>();
                QVERIFY(cover);
                QCOMPARE(cover->width(), cover->height());
                QVERIFY(card->width() >= 144 && card->width() <= 216);
                for (QWidget* other : cards)
                    if (card != other) QVERIFY(!card->geometry().intersects(other->geometry()));
            }
            capture(QStringLiteral("grid-%1").arg(width), grid.get());
        }
        QVERIFY(grid->layout()->heightForWidth(420) > grid->layout()->heightForWidth(920));
    }
    void detailHeadersReserveSpaceForSongs()
    {
        auto* info = new QWidget();
        auto* infoLayout = new QVBoxLayout(info);
        infoLayout->setContentsMargins(0, 0, 0, 0);
        infoLayout->addWidget(ui::titleElidedLabel(QStringLiteral("非常长的歌单名称，用于验证详情页不会撑开窗口"), 26, true));
        infoLayout->addWidget(ui::secondaryElidedLabel(QString(300, QChar(0x97f3))));
        auto* actions = new QWidget(info);
        auto* flow = new FlowLayout(actions, 8);
        for (const auto& title : {QStringLiteral("播放全部"), QStringLiteral("添加到队列"),
                 QStringLiteral("收藏歌单"), QStringLiteral("重命名"), QStringLiteral("删除歌单")})
            flow->addWidget(ui::ghostButton(title));
        infoLayout->addWidget(actions);
        std::unique_ptr<QWidget> header(ui::detailHeader(std::nullopt, info));
        header->show();
        for (int width : {560, 720, 1000}) {
            header->resize(width, header->layout()->heightForWidth(width));
            QTest::qWait(20);
            QVERIFY(header->height() <= 230);
            for (QPushButton* button : actions->findChildren<QPushButton*>())
                QVERIFY(actions->rect().contains(button->geometry()));
            capture(QStringLiteral("detail-header-%1").arg(width), header.get());
        }
    }
    void longTitlesRemainLiteralAndRecoverOnResize()
    {
        ui::ElidedLabel label(QStringLiteral("<b>超长标题 & artist</b> — 这是完整标题"));
        label.resize(90, 28);
        label.show();
        QTest::qWait(10);
        QCOMPARE(label.textFormat(), Qt::PlainText);
        QVERIFY(label.text() != label.fullText());
        QCOMPARE(label.toolTip(), label.fullText());
        label.resize(800, 28);
        QTest::qWait(10);
        QCOMPARE(label.text(), label.fullText());
    }
    void cardsAreKeyboardOperable()
    {
        m_window->activateWindow();
        ui::CardButton card(m_window.get());
        int clicks = 0;
        card.onClicked = [&clicks] { ++clicks; };
        card.show();
        card.setFocus();
        QTRY_VERIFY(card.hasFocus());
        QTest::keyClick(&card, Qt::Key_Return);
        QTest::keyClick(&card, Qt::Key_Space);
        QCOMPARE(clicks, 2);
    }
    void playerBarFitsAtMinimumWindowSize()
    {
        m_window->resize(900, 560);
        QTest::qWait(20);
        QCOMPARE(m_window->size(), QSize(900, 560));
        auto* bar = m_window->findChild<QWidget*>(QStringLiteral("ctPlayerBar"));
        auto* progress = m_window->findChild<QSlider*>(QStringLiteral("ctProgress"));
        QVERIFY(bar);
        QCOMPARE(bar->height(), 88);
        auto* play = m_window->findChild<QPushButton*>(QStringLiteral("ctPrimaryPlay"));
        QCOMPARE(play->size(), QSize(42, 42));
        auto* sidebar = m_window->findChild<QWidget*>(QStringLiteral("ctSidebar"));
        QCOMPARE(sidebar->width(), 184);
        QVERIFY(progress);
        QVERIFY(progress->width() >= 140);
        for (QPushButton* button : bar->findChildren<QPushButton*>()) {
            if (!button->isVisible()) continue;
            const QRect position(button->mapTo(bar, QPoint()), button->size());
            QVERIFY2(bar->rect().contains(position), qPrintable(button->toolTip()));
        }
        capture(QStringLiteral("recent-900-light"), m_window.get());
    }
    void groupedNavigationStillOpensTheCorrectPage()
    {
        m_window->activateWindow();
        auto* navigation = m_window->findChild<QListWidget*>(QStringLiteral("ctNavigation"));
        QVERIFY(navigation);
        for (int row = 0; row < navigation->count(); ++row) {
            auto* item = navigation->item(row);
            if (!item->data(Qt::UserRole).isValid()) continue;
            navigation->setCurrentRow(row);
            QCOMPARE(AppState::shared().currentPage(), static_cast<Page>(item->data(Qt::UserRole).toInt()));
        }
        QTest::keyClick(m_window.get(), Qt::Key_F, Qt::ControlModifier);
        auto* stack = m_window->findChild<QStackedWidget*>();
        auto* edit = stack->currentWidget()->findChild<QLineEdit*>();
        QVERIFY(edit);
        QTRY_VERIFY(edit->hasFocus());
        QCOMPARE(m_window->size(), QSize(900, 560));
        capture(QStringLiteral("search-assist-900"), m_window.get());
    }
    void themesUpdateExistingPagesWithoutLosingInput()
    {
        AppState::shared().switchToTopLevel(Page::Search);
        auto* stack = m_window->findChild<QStackedWidget*>();
        auto* edit = stack->currentWidget()->findChild<QLineEdit*>();
        QVERIFY(edit);
        edit->setText(QStringLiteral("未提交的搜索词"));
        for (auto mode : {CTThemeMode::Dark, CTThemeMode::Light, CTThemeMode::Dark}) {
            CTTheme::apply(mode);
            QTest::qWait(10);
            QCOMPARE(CTColors::isDark(), mode == CTThemeMode::Dark);
            QCOMPARE(qApp->palette().color(QPalette::Window), CTColors::background());
            QCOMPARE(edit->text(), QStringLiteral("未提交的搜索词"));
            QVERIFY(stack->currentWidget()->styleSheet().contains(CTColors::background().name()));
            capture(mode == CTThemeMode::Dark ? QStringLiteral("search-900-dark") : QStringLiteral("search-900-light"), m_window.get());
        }
    }
    void songRowsFitLongMetadata()
    {
        SongListView list;
        QList<Song> songs;
        for (int i = 0; i < 8; ++i) {
            Song song;
            song.id = QString::number(i);
            song.title = QStringLiteral("一首有很长名字的音乐 / A very long song title — Live version");
            song.duration = 215;
            song.artists.append(Artist{QStringLiteral("1"), QStringLiteral("一位有很长名字的歌手 Artist"), std::nullopt, {}});
            song.isPlayable = i != 2;
            if (!song.isPlayable) song.unavailableReason = QStringLiteral("当前音源不可播放，请尝试其他歌曲");
            songs.append(song);
        }
        list.setSongs(songs);
        list.resize(430, 360);
        list.show();
        QTest::qWait(20);
        auto* viewport = list.listWidget()->viewport();
        for (auto* label : list.findChildren<ui::ElidedLabel*>()) {
            if (label->mapTo(viewport, QPoint()).y() >= viewport->height()) continue;
            QVERIFY(label->width() > 0);
            QVERIFY(label->mapTo(viewport, QPoint()).x() + label->width() <= viewport->width());
        }
        capture(QStringLiteral("songs-long-titles"), &list);
        list.resize(430, list.contentHeight());
        QTest::qWait(20);
        const QRect last = list.listWidget()->visualItemRect(list.listWidget()->item(songs.size() - 1));
        QVERIFY(list.listWidget()->viewport()->rect().contains(last));
    }
    void overlaysAndPagesFitCompactWindow()
    {
        m_window->resize(900, 560);
        for (Page page : {Page::Discover, Page::Settings, Page::MyMusic, Page::Liked, Page::Local,
                 Page::Recent, Page::Messages, Page::Profile, Page::TopList, Page::Radio, Page::PersonalFM}) {
            AppState::shared().switchToTopLevel(page);
            QTest::qWait(20);
            QCOMPARE(m_window->size(), QSize(900, 560));
            capture(QStringLiteral("page-%1-900").arg(static_cast<int>(page)), m_window.get());
        }
        AppState::shared().setIsNowPlayingExpanded(true);
        QTest::qWait(20);
        auto* overlay = m_window->findChild<QWidget*>(QStringLiteral("ctNowPlayingOverlay"));
        QVERIFY(overlay->isVisible());
        for (auto* slider : overlay->findChildren<QSlider*>()) {
            if (!slider->isVisible()) continue;
            QVERIFY(overlay->rect().contains(QRect(slider->mapTo(overlay, QPoint()), slider->size())));
        }
        capture(QStringLiteral("now-playing-900"), m_window.get());
        AppState::shared().setIsNowPlayingExpanded(false);
        AppState::shared().setShowQueue(true);
        QTest::qWait(10);
        capture(QStringLiteral("queue-900"), m_window.get());
        AppState::shared().setShowQueue(false);
        AppState::shared().setIsLoginPresented(true);
        QTest::qWait(30);
        auto* loginPanel = m_window->findChild<QWidget*>(QStringLiteral("ctLoginPanel"));
        QVERIFY(m_window->rect().contains(QRect(loginPanel->mapTo(m_window.get(), QPoint()), loginPanel->size())));
        capture(QStringLiteral("login-900"), m_window.get());
        QTest::keyClick(m_window.get(), Qt::Key_Escape);
        QVERIFY(!AppState::shared().isLoginPresented());
    }
    void cleanupTestCase()
    {
        HelperProcessManager::shared().stop();
        m_window.reset();
    }
};

QTEST_MAIN(GuiLayoutTests)
#include "tst_gui_layout.moc"
