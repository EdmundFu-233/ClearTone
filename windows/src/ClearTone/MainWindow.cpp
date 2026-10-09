#include "MainWindow.h"

#include "App/CloseBehaviorPolicy.h"
#include "App/MediaSessionIntegration.h"
#include "App/MiniPlayerWindow.h"
#include "App/SidebarShortcuts.h"
#include "App/TrayIconManager.h"
#include "Core/Async.h"
#include "Core/Logging/CTLog.h"
#include "Core/Models/MusicError.h"
#include "Core/Networking/HelperProcessManager.h"
#include "Core/Persistence/AppSettings.h"
#include "Core/Persistence/PersistenceStore.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "DesignSystem/L10n.h"
#include "Features/Shared/PageFactory.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"
#include "Playback/SongQuality.h"

#include <QAction>
#include <QApplication>
#include <QCloseEvent>
#include <QCoreApplication>
#include <QFrame>
#include <QGuiApplication>
#include <QHBoxLayout>
#include <QJsonObject>
#include <QJsonValue>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMenu>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QResizeEvent>
#include <QScreen>
#include <QScrollArea>
#include <QShowEvent>
#include <QSlider>
#include <QStackedWidget>
#include <QStyleHints>
#include <QTextEdit>
#include <QVBoxLayout>

#include <algorithm>
#include <cmath>

namespace ct {

namespace {

constexpr int sidebarWidth = 212;

AppSettings loadAppSettings()
{
    const QJsonValue value = PersistenceStore::shared().loadSetting(QStringLiteral("appSettings"));
    if (value.isObject()) return AppSettings::fromJson(value.toObject());
    return AppSettings{};
}

QString glyphButtonStyle(double size)
{
    return QStringLiteral(
        "QPushButton { background: transparent; border: none; color: %1; font-size: %2px;"
        " font-family: 'lucide'; }"
        "QPushButton:hover { background: %3; border-radius: 6px; }")
        .arg(CTColors::textPrimary().name())
        .arg(size)
        .arg(CTColors::overlay().name());
}

QString plainTextButtonStyle()
{
    return QStringLiteral(
        "QPushButton { background: transparent; border: none; color: %1; font-size: 13px;"
        " padding: 0 6px; }"
        "QPushButton:hover { background: %2; border-radius: 6px; }")
        .arg(CTColors::accent().name(), CTColors::overlay().name());
}

QPushButton* makeGlyphButton(const QString& glyph, const QString& tip, double size, QWidget* parent)
{
    auto* button = new QPushButton(glyph, parent);
    button->setFlat(true);
    button->setCursor(Qt::PointingHandCursor);
    button->setToolTip(tip);
    button->setAccessibleName(tip);
    button->setFixedSize(32, 32);
    button->setStyleSheet(glyphButtonStyle(size));
    return button;
}

QPushButton* makeTextButton(const QString& text, const QColor& color, QWidget* parent)
{
    auto* button = new QPushButton(text, parent);
    button->setFlat(true);
    button->setCursor(Qt::PointingHandCursor);
    button->setStyleSheet(QStringLiteral(
        "QPushButton { background: transparent; border: none; color: %1; padding: 4px 6px;"
        " font-size: 13px; }"
        "QPushButton:hover { background: %2; border-radius: 6px; }")
                              .arg(color.name(), CTColors::overlay().name()));
    return button;
}

QString sliderStyle()
{
    return QStringLiteral(
        "QSlider { background: transparent; }"
        "QSlider::groove:horizontal { height: 4px; background: %1; border-radius: 2px; }"
        "QSlider::sub-page:horizontal { background: %2; border-radius: 2px; }"
        "QSlider::handle:horizontal { width: 10px; margin: -4px 0; background: %2; border-radius: 5px; }")
        .arg(CTColors::overlay().name(), CTColors::accent().name());
}

QString playlistButtonStyle(bool active)
{
    return QStringLiteral(
        "QPushButton { background: %1; border: none; text-align: left; padding: 5px 10px;"
        " color: %2; border-radius: 6px; }"
        "QPushButton:hover { background: %3; }")
        .arg(active ? CTColors::overlay().name() : QStringLiteral("transparent"),
            CTColors::textPrimary().name(), CTColors::overlay().name());
}

template <typename Event, typename Handler>
void appendSubscription(QList<std::function<void()>>& subscriptions, Event& event, Handler handler)
{
    const int id = event.subscribe(std::move(handler));
    subscriptions.append([&event, id] { event.unsubscribe(id); });
}

} // namespace

MainWindow::MainWindow(QWidget* parent)
    : QMainWindow(parent)
{
    applyTheme();

    setWindowTitle(QStringLiteral("澄音 ClearTone"));
    setMinimumSize(900, 560);
    // 默认尺寸不能超过屏幕可用区域：1080p + 125%/150% 缩放下逻辑高度只有
    // 864/720，写死 780 会把底部播放条挤出屏幕。
    if (const QScreen* targetScreen = QGuiApplication::primaryScreen()) {
        const QRect available = targetScreen->availableGeometry();
        resize(qBound(900, available.width() - 60, 1200),
            qBound(560, available.height() - 60, 780));
    } else {
        resize(1200, 780);
    }
    setWindowIcon(TrayIconManager::applicationIcon());

    auto* central = new QWidget(this);
    central->setObjectName(QStringLiteral("ctCentral"));
    central->setStyleSheet(
        QStringLiteral("#ctCentral { background: %1; }").arg(CTColors::background().name()));
    auto* rootLayout = new QVBoxLayout(central);
    rootLayout->setContentsMargins(0, 0, 0, 0);
    rootLayout->setSpacing(0);

    auto* upper = new QWidget(central);
    auto* upperLayout = new QHBoxLayout(upper);
    upperLayout->setContentsMargins(0, 0, 0, 0);
    upperLayout->setSpacing(0);
    upperLayout->addWidget(buildSidebar(upper));
    upperLayout->addWidget(buildContentColumn(upper), 1);
    rootLayout->addWidget(upper, 1);
    rootLayout->addWidget(buildPlayerBar(central));
    setCentralWidget(central);

    buildOverlays();

    rebuildSidebarItems();
    syncPlaylists();
    showPage(AppState::shared().currentPage());
    syncSidebarSelection();
    updateAccountArea();
    updateBarSong();
    updateBarTransport();
    updateBarProgress();
    updateBarVolume();
    updateBarRate();
    updateSleepButton();
    updateOverlays();
    updateOverlayGeometry();
    updateResponsiveGeometry();

    subscribeEvents();
    if (QApplication::instance() != nullptr) QApplication::instance()->installEventFilter(this);
}

MainWindow::~MainWindow()
{
    if (QApplication::instance() != nullptr) QApplication::instance()->removeEventFilter(this);
    m_bar.onChanged = nullptr;
    for (const auto& unsubscribe : m_unsubscribers) unsubscribe();
    m_unsubscribers.clear();
}

void MainWindow::applyTheme()
{
    CTTheme::apply(loadAppSettings().themeMode);
}

void MainWindow::subscribeEvents()
{
    AppState& app = AppState::shared();
    PlayerController& player = PlayerController::shared();

    appendSubscription(m_unsubscribers, app.changed, [this] { refreshAll(); });
    appendSubscription(m_unsubscribers, player.onSongChanged, [this] { updateBarSong(); });
    appendSubscription(m_unsubscribers, player.onStateChanged, [this] { updateBarTransport(); });
    appendSubscription(m_unsubscribers, player.onQueueChanged, [this] { updateBarTransport(); });
    appendSubscription(m_unsubscribers, player.onDurationChanged, [this] { updateBarProgress(); });
    appendSubscription(m_unsubscribers, player.onPositionChanged, [this] { updateBarProgress(); });
    appendSubscription(m_unsubscribers, player.timeUpdated, [this](double) { updateBarProgress(); });
    appendSubscription(m_unsubscribers, player.onQualityChanged, [this] { updateBarSong(); });
    appendSubscription(m_unsubscribers, player.onPlaybackRateChanged, [this] { updateBarRate(); });
    appendSubscription(m_unsubscribers, player.onSleepTimerChanged, [this] { updateSleepButton(); });
    appendSubscription(m_unsubscribers, player.onVolumeChanged, [this] { updateBarVolume(); });
}

void MainWindow::refreshAll()
{
    AppState& app = AppState::shared();
    if (app.currentPage() != m_shownPage) {
        showPage(app.currentPage());
    } else {
        m_backButton->setVisible(app.canGoBack());
    }
    syncSidebarSelection();
    syncPlaylists();
    updateAccountArea();
    updateOverlays();
    updateBarSong();
}

QWidget* MainWindow::buildSidebar(QWidget* parent)
{
    auto* side = new QFrame(parent);
    side->setObjectName(QStringLiteral("ctSidebar"));
    side->setFixedWidth(sidebarWidth);
    side->setStyleSheet(QStringLiteral("#ctSidebar { background: %1; border-right: 1px solid %2; }")
                            .arg(CTColors::panel().name(), CTColors::overlay().name()));
    auto* sideLayout = new QVBoxLayout(side);
    sideLayout->setContentsMargins(0, 0, 0, 0);
    sideLayout->setSpacing(0);

    auto* header = new QWidget(side);
    auto* headerLayout = new QVBoxLayout(header);
    headerLayout->setContentsMargins(16, 16, 12, 12);
    headerLayout->setSpacing(2);
    auto* brand = new QLabel(header);
    brand->setPixmap(QPixmap(QStringLiteral(":/Assets/appicon.png")).scaled(38, 38, Qt::KeepAspectRatio, Qt::SmoothTransformation));
    auto* brandRow = new QWidget(header);
    auto* brandLayout = new QHBoxLayout(brandRow);
    brandLayout->setContentsMargins(0, 0, 0, 0);
    brandLayout->setSpacing(10);
    brandLayout->addWidget(brand);
    auto* brandText = new QWidget(brandRow);
    auto* brandTextLayout = new QVBoxLayout(brandText);
    brandTextLayout->setContentsMargins(0, 0, 0, 0);
    brandTextLayout->setSpacing(0);
    brandTextLayout->addWidget(ui::titleLabel(QStringLiteral("澄音"), 22, true));
    brandTextLayout->addWidget(ui::secondaryElidedLabel(QStringLiteral("ClearTone")));
    brandLayout->addWidget(brandText, 1);
    headerLayout->addWidget(brandRow);
    sideLayout->addWidget(header);

    auto* scroll = new QScrollArea(side);
    scroll->setWidgetResizable(true);
    scroll->setFrameShape(QFrame::NoFrame);
    scroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    scroll->setStyleSheet(QStringLiteral("QScrollArea { background: transparent; }"));
    auto* scrollContent = new QWidget(scroll);
    auto* scrollLayout = new QVBoxLayout(scrollContent);
    scrollLayout->setContentsMargins(8, 4, 8, 16);
    scrollLayout->setSpacing(4);

    m_sidebarList = new QListWidget(scrollContent);
    m_sidebarList->setFrameShape(QFrame::NoFrame);
    m_sidebarList->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    m_sidebarList->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    m_sidebarList->setObjectName(QStringLiteral("ctNavigation"));
    m_sidebarList->setIconSize(QSize(20, 20));
    m_sidebarList->setSpacing(2);
    m_sidebarList->setFocusPolicy(Qt::StrongFocus);
    m_sidebarList->setStyleSheet(QStringLiteral(
        "QListWidget { background: transparent; border: none; outline: none; }"
        "QListWidget::item { padding: 0 12px; border-radius: 8px; color: %1; }"
        "QListWidget::item:hover { background: %2; }"
        "QListWidget::item:selected { background: %3; color: %4; font-weight: 600; }"
        "QListWidget::item:disabled { color: %5; background: transparent; }")
        .arg(CTColors::textPrimary().name(), CTColors::overlay().name(), CTColors::accentSoft().name(),
            CTColors::accent().name(), CTColors::textSecondary().name()));
    QObject::connect(m_sidebarList, &QListWidget::currentRowChanged, this, [this](int row) {
        if (m_syncingSidebar || row < 0) return;
        QListWidgetItem* item = m_sidebarList->item(row);
        if (item == nullptr || !item->data(Qt::UserRole).isValid()) return;
        AppState::shared().switchToTopLevel(static_cast<Page>(item->data(Qt::UserRole).toInt()));
    });
    scrollLayout->addWidget(m_sidebarList);

    scrollLayout->addWidget(ui::secondaryLabel(QStringLiteral("创建的歌单")));
    m_playlistPanel = new QWidget(scrollContent);
    m_playlistLayout = new QVBoxLayout(m_playlistPanel);
    m_playlistLayout->setContentsMargins(0, 0, 0, 0);
    m_playlistLayout->setSpacing(2);
    scrollLayout->addWidget(m_playlistPanel);
    scrollLayout->addStretch(1);
    scroll->setWidget(scrollContent);
    scrollContent->setAutoFillBackground(false);
    scroll->viewport()->setAutoFillBackground(false);
    sideLayout->addWidget(scroll, 1);

    auto* accountWrap = new QWidget(side);
    auto* accountWrapLayout = new QVBoxLayout(accountWrap);
    accountWrapLayout->setContentsMargins(12, 0, 12, 12);
    auto* accountFrame = new QFrame(accountWrap);
    accountFrame->setObjectName(QStringLiteral("ctAccount"));
    accountFrame->setStyleSheet(QStringLiteral("#ctAccount { background: %1; border-radius: 8px; }")
                                    .arg(CTColors::overlay().name()));
    auto* accountFrameLayout = new QVBoxLayout(accountFrame);
    accountFrameLayout->setContentsMargins(6, 6, 6, 6);

    m_accountButton = new QPushButton(accountFrame);
    m_accountButton->setFlat(true);
    m_accountButton->setCursor(Qt::PointingHandCursor);
    m_accountButton->setMinimumHeight(44);
    m_accountButton->setStyleSheet(QStringLiteral(
        "QPushButton { background: transparent; border: none; text-align: left; padding: 4px; }"));
    auto* accountLayout = new QHBoxLayout(m_accountButton);
    accountLayout->setContentsMargins(4, 4, 4, 4);
    accountLayout->setSpacing(10);
    m_accountGlyph = new QLabel(QStringLiteral("\uE46C"), m_accountButton);
    m_accountGlyph->setStyleSheet(QStringLiteral("color: %1; font-size: 20px;"
                                                 " font-family: 'lucide';")
                                      .arg(CTColors::textPrimary().name()));
    m_accountGlyph->setAlignment(Qt::AlignVCenter);
    accountLayout->addWidget(m_accountGlyph);
    auto* accountText = new QWidget(m_accountButton);
    auto* accountTextLayout = new QVBoxLayout(accountText);
    accountTextLayout->setContentsMargins(0, 0, 0, 0);
    accountTextLayout->setSpacing(1);
    m_accountName = new ui::ElidedLabel(QStringLiteral("未登录"), accountText);
    m_accountName->setStyleSheet(QStringLiteral("color: %1; font-size: %2px; font-weight: 600;")
                                     .arg(CTColors::textPrimary().name())
                                     .arg(CTTypography::Body));
    m_accountHint = ui::secondaryLabel(QStringLiteral("点击扫码登录"));
    accountTextLayout->addWidget(m_accountName);
    accountTextLayout->addWidget(m_accountHint);
    accountLayout->addWidget(accountText, 1);
    for (QWidget* child : m_accountButton->findChildren<QWidget*>()) child->setAttribute(Qt::WA_TransparentForMouseEvents);
    m_accountButton->setAccessibleName(QStringLiteral("账号与登录"));
    QObject::connect(m_accountButton, &QPushButton::clicked, [] {
        AppState& app = AppState::shared();
        if (!app.account()) {
            app.setIsLoginPresented(true);
        } else {
            app.switchToTopLevel(Page::Profile);
        }
    });
    accountFrameLayout->addWidget(m_accountButton);
    accountWrapLayout->addWidget(accountFrame);
    sideLayout->addWidget(accountWrap);

    return side;
}

QWidget* MainWindow::buildContentColumn(QWidget* parent)
{
    auto* column = new QWidget(parent);
    auto* layout = new QVBoxLayout(column);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);

    auto* header = new QWidget(column);
    auto* headerLayout = new QHBoxLayout(header);
    headerLayout->setContentsMargins(24, 10, 24, 4);
    headerLayout->setSpacing(8);
    m_backButton = makeGlyphButton(QStringLiteral("\uE04C"), L10n::Common::Back, 16, header);
    m_backButton->setVisible(false);
    m_pageTitle = ui::secondaryLabel(QStringLiteral("发现音乐"));
    m_settingsButton = makeGlyphButton(QStringLiteral("\uE244"), L10n::Common::Settings, 16, header);
    QObject::connect(m_backButton, &QPushButton::clicked, this,
        [] { AppState::shared().goBack(); });
    QObject::connect(m_settingsButton, &QPushButton::clicked, this,
        [] { AppState::shared().switchToTopLevel(Page::Settings); });
    headerLayout->addWidget(m_backButton);
    headerLayout->addWidget(m_pageTitle);
    headerLayout->addStretch(1);
    auto* search = ui::ghostButton(QStringLiteral("搜索音乐                         Ctrl F"));
    search->setObjectName(QStringLiteral("ctGlobalSearch"));
    search->setMinimumWidth(220);
    search->setMaximumWidth(340);
    search->setIcon(CTTheme::icon(page::glyph(Page::Search)));
    search->setProperty("ctIconGlyph", page::glyph(Page::Search));
    search->setAccessibleName(QStringLiteral("搜索音乐"));
    connect(search, &QPushButton::clicked, this, [this] {
        AppState::shared().switchToTopLevel(Page::Search);
        if (auto* edit = m_content->currentWidget()->findChild<QLineEdit*>()) edit->setFocus();
    });
    headerLayout->addWidget(search);
    headerLayout->addSpacing(8);
    headerLayout->addWidget(m_settingsButton);
    layout->addWidget(header);

    m_content = new QStackedWidget(column);
    layout->addWidget(m_content, 1);
    return column;
}

QWidget* MainWindow::buildPlayerBar(QWidget* parent)
{
    auto* bar = new QFrame(parent);
    bar->setObjectName(QStringLiteral("ctPlayerBar"));
    bar->setStyleSheet(QStringLiteral("#ctPlayerBar { background: %1; border-top: 1px solid %2; }")
                           .arg(CTColors::panel().name(), CTColors::overlay().name()));
    bar->setSizePolicy(QSizePolicy::Preferred, QSizePolicy::Fixed);
    bar->setFixedHeight(104);
    auto* layout = new QHBoxLayout(bar);
    layout->setContentsMargins(20, 8, 20, 8);
    layout->setSpacing(10);

    auto* left = new QWidget(bar);
    auto* leftLayout = new QHBoxLayout(left);
    leftLayout->setContentsMargins(0, 0, 0, 0);
    leftLayout->setSpacing(10);

    m_expandButton = new QPushButton(left);
    m_expandButton->setFlat(true);
    m_expandButton->setCursor(Qt::PointingHandCursor);
    m_expandButton->setToolTip(QStringLiteral("打开正在播放"));
    m_expandButton->setFixedSize(56, 56);
    m_expandButton->setStyleSheet(QStringLiteral(
        "QPushButton { background: transparent; border: none; padding: 0; }"));
    auto* coverLayout = new QVBoxLayout(m_expandButton);
    coverLayout->setContentsMargins(0, 0, 0, 0);
    m_barCover = new CoverImage(m_expandButton);
    m_barCover->setFixedSize(56, 56);
    m_barCover->setCornerRadius(10);
    m_barCover->setAttribute(Qt::WA_TransparentForMouseEvents);
    coverLayout->addWidget(m_barCover);
    QObject::connect(m_expandButton, &QPushButton::clicked, this,
        [] { AppState::shared().setIsNowPlayingExpanded(true); });
    leftLayout->addWidget(m_expandButton);

    m_titleButton = new QPushButton(left);
    m_titleButton->setFlat(true);
    m_titleButton->setCursor(Qt::PointingHandCursor);
    m_titleButton->setToolTip(QStringLiteral("打开正在播放"));
    m_titleButton->setMinimumWidth(70);
    m_titleButton->setFixedHeight(52);
    m_titleButton->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
    m_titleButton->setMaximumWidth(250);
    m_titleButton->setStyleSheet(QStringLiteral(
        "QPushButton { background: transparent; border: none; text-align: left; padding: 4px; }"));
    auto* titleLayout = new QVBoxLayout(m_titleButton);
    titleLayout->setContentsMargins(0, 0, 0, 0);
    titleLayout->setSpacing(2);
    m_barTitle = new ui::ElidedLabel(QStringLiteral("未在播放"), m_titleButton);
    m_barTitle->setStyleSheet(QStringLiteral("color: %1; font-size: %2px; font-weight: 600;")
                                  .arg(CTColors::textPrimary().name())
                                  .arg(CTTypography::Body));
    m_barArtist = new ui::ElidedLabel(QString(), m_titleButton);
    m_barArtist->setStyleSheet(QStringLiteral("color: %1;").arg(CTColors::textSecondary().name()));
    titleLayout->addWidget(m_barTitle);
    titleLayout->addWidget(m_barArtist);
    QObject::connect(m_titleButton, &QPushButton::clicked, this,
        [] { AppState::shared().setIsNowPlayingExpanded(true); });
    leftLayout->addWidget(m_titleButton, 1);
    for (QWidget* child : m_titleButton->findChildren<QWidget*>()) child->setAttribute(Qt::WA_TransparentForMouseEvents);

    m_likeButton = makeGlyphButton(QStringLiteral("\uE0F5"), QStringLiteral("喜欢"), 16, left);
    QObject::connect(m_likeButton, &QPushButton::clicked, this, [this] { toggleCurrentLike(false); });
    leftLayout->addWidget(m_likeButton);
    left->setMinimumWidth(190);

    auto* center = new QWidget(bar);
    center->setMinimumWidth(240);
    auto* centerLayout = new QVBoxLayout(center);
    centerLayout->setContentsMargins(0, 0, 0, 0);
    centerLayout->setSpacing(2);

    auto* transport = new QWidget(center);
    auto* transportLayout = new QHBoxLayout(transport);
    transportLayout->setContentsMargins(0, 0, 0, 0);
    transportLayout->setSpacing(18);
    m_prevButton = makeGlyphButton(QStringLiteral("\uE162"), L10n::Common::Previous, 16, transport);
    m_playPauseButton = makeGlyphButton(QStringLiteral("\uE13F"), L10n::Common::Play, 22, transport);
    m_nextButton = makeGlyphButton(QStringLiteral("\uE163"), L10n::Common::Next, 16, transport);
    QObject::connect(m_prevButton, &QPushButton::clicked, this,
        [] { PlayerController::shared().previous(); });
    QObject::connect(m_playPauseButton, &QPushButton::clicked, this,
        [] { PlayerController::shared().togglePlayPause(); });
    QObject::connect(m_nextButton, &QPushButton::clicked, this,
        [] { PlayerController::shared().next(); });
    transportLayout->addStretch(1);
    m_playPauseButton->setObjectName(QStringLiteral("ctPrimaryPlay"));
    m_playPauseButton->setFixedSize(42, 42);
    m_playPauseButton->setStyleSheet(QStringLiteral("QPushButton { background: %1; color: %2; font-family: lucide; font-size: 20px; min-width: 42px; max-width: 42px; min-height: 42px; max-height: 42px; border: none; border-radius: 20px; padding: 0; } QPushButton:focus { border: 2px solid %3; }").arg(CTColors::accent().name(), CTColors::panel().name(), CTColors::textPrimary().name()));
    transportLayout->addWidget(m_prevButton);
    transportLayout->addWidget(m_playPauseButton);
    transportLayout->addWidget(m_nextButton);
    transportLayout->addStretch(1);
    centerLayout->addWidget(transport);

    auto* progressRow = new QWidget(center);
    auto* progressLayout = new QHBoxLayout(progressRow);
    progressLayout->setContentsMargins(0, 0, 0, 0);
    progressLayout->setSpacing(8);
    m_currentTimeLabel = ui::secondaryLabel(QStringLiteral("0:00"));
    m_currentTimeLabel->setAlignment(Qt::AlignVCenter);
    m_durationLabel = ui::secondaryLabel(QStringLiteral("0:00"));
    m_durationLabel->setAlignment(Qt::AlignVCenter);
    m_progressSlider = new QSlider(Qt::Horizontal, progressRow);
    m_progressSlider->setObjectName(QStringLiteral("ctProgress"));
    m_progressSlider->setAccessibleName(QStringLiteral("播放进度"));
    m_progressSlider->setRange(0, 100);
    m_progressSlider->setStyleSheet(sliderStyle());
    QObject::connect(m_progressSlider, &QSlider::sliderPressed, this,
        [this] { m_progressDragging = true; });
    QObject::connect(m_progressSlider, &QSlider::sliderReleased, this, [this] {
        if (!m_progressDragging) return;
        m_progressDragging = false;
        PlayerController& player = PlayerController::shared();
        const double duration = player.duration();
        if (duration > 0) player.commitSeek(m_progressSlider->value() / 100.0 * duration);
    });
    QObject::connect(m_progressSlider, &QSlider::valueChanged, this, [this](int value) {
        if (!m_progressDragging) return;
        PlayerController& player = PlayerController::shared();
        const double duration = player.duration();
        if (duration <= 0) return;
        player.previewSeek(value / 100.0 * duration);
    });
    progressLayout->addWidget(m_currentTimeLabel);
    progressLayout->addWidget(m_progressSlider, 1);
    progressLayout->addWidget(m_durationLabel);
    centerLayout->addWidget(progressRow);

    auto* right = new QWidget(bar);
    auto* rightLayout = new QHBoxLayout(right);
    rightLayout->setContentsMargins(0, 0, 0, 0);
    rightLayout->setSpacing(3);
    m_sleepButton = makeGlyphButton(QStringLiteral("\uE121"), QStringLiteral("睡眠定时"), 15, right);
    QObject::connect(m_sleepButton, &QPushButton::clicked, this, [this] { openSleepMenu(); });
    m_modeButton = makeGlyphButton(QStringLiteral("\uE149"), QStringLiteral("顺序播放"), 15, right);
    QObject::connect(m_modeButton, &QPushButton::clicked, this,
        [] { PlayerController::shared().cyclePlayMode(); });
    m_queueButton = makeGlyphButton(QStringLiteral("\uE2DF"), L10n::Common::Queue, 15, right);
    QObject::connect(m_queueButton, &QPushButton::clicked, this,
        [] { AppState::shared().setShowQueue(true); });
    m_rateButton = makeTextButton(QStringLiteral("1.0x"), CTColors::accent(), right);
    m_rateButton->setToolTip(QStringLiteral("播放速度"));
    m_rateButton->setVisible(false);
    QObject::connect(m_rateButton, &QPushButton::clicked, this, [this] { openRateMenu(); });
    m_qualityButton = makeTextButton(QString(), CTColors::textSecondary(), right);
    m_qualityButton->setToolTip(L10n::Player::Quality);
    QObject::connect(m_qualityButton, &QPushButton::clicked, this, [this] { cycleQuality(); });
    m_muteButton = makeGlyphButton(QStringLiteral("\uE1AA"), QStringLiteral("静音"), 15, right);
    QObject::connect(m_muteButton, &QPushButton::clicked, this, [] {
        PlayerController& player = PlayerController::shared();
        player.setMuted(!player.isMuted());
    });
    m_volumeSlider = new QSlider(Qt::Horizontal, right);
    m_volumeSlider->setRange(0, 100);
    m_volumeSlider->setFixedWidth(64);
    m_volumeSlider->setAccessibleName(QStringLiteral("音量"));
    m_volumeSlider->setStyleSheet(sliderStyle());
    QObject::connect(m_volumeSlider, &QSlider::valueChanged, this, [this](int value) {
        if (m_syncingVolume) return;
        m_syncingVolume = true;
        PlayerController& player = PlayerController::shared();
        player.setVolume(static_cast<float>(value / 100.0));
        if (player.volume() > 0.001f) player.setMuted(false);
        m_syncingVolume = false;
        updateBarVolume();
    });
    rightLayout->addStretch(1);
    rightLayout->addWidget(m_sleepButton);
    transportLayout->insertWidget(1, m_modeButton);
    rightLayout->addWidget(m_queueButton);
    rightLayout->addWidget(m_rateButton);
    rightLayout->addWidget(m_qualityButton);
    rightLayout->addWidget(m_muteButton);
    rightLayout->addWidget(m_volumeSlider);

    layout->addWidget(left, 3);
    layout->addWidget(center, 4);
    layout->addWidget(right, 3);
    return bar;
}

void MainWindow::buildOverlays()
{
    m_nowPlayingOverlay = new QFrame(this);
    m_nowPlayingOverlay->setProperty("ctImmersive", true);
    m_nowPlayingOverlay->setObjectName(QStringLiteral("ctNowPlayingOverlay"));
    m_nowPlayingOverlay->setStyleSheet(
        QStringLiteral("#ctNowPlayingOverlay { background: #10141c; }"));
    auto* nowPlayingLayout = new QVBoxLayout(m_nowPlayingOverlay);
    nowPlayingLayout->setContentsMargins(0, 0, 0, 0);
    nowPlayingLayout->setSpacing(0);
    auto* nowPlayingHeader = new QWidget(m_nowPlayingOverlay);
    auto* nowPlayingHeaderLayout = new QHBoxLayout(nowPlayingHeader);
    nowPlayingHeaderLayout->setContentsMargins(16, 12, 16, 12);
    auto* collapse = makeGlyphButton(QStringLiteral("\uE071"), QStringLiteral("收起"), 16, nowPlayingHeader);
    collapse->setStyleSheet(QStringLiteral("QPushButton { font-family: lucide; font-size: 18px; color: #f0f3f8; background: transparent; border: none; }"));
    QObject::connect(collapse, &QPushButton::clicked, this,
        [] { AppState::shared().setIsNowPlayingExpanded(false); });
    m_nowPlayingTitle = new ui::ElidedLabel(QString(), nowPlayingHeader);
    m_nowPlayingTitle->setStyleSheet(QStringLiteral("color: %1; font-size: %2px; font-weight: 600;")
                                         .arg(CTColors::DarkTextPrimary.name())
                                         .arg(CTTypography::Body));
    m_nowPlayingTitle->setMaximumWidth(420);
    auto* nowPlayingHint = ui::secondaryLabel(QStringLiteral("正在播放"));
    nowPlayingHint->setStyleSheet(QStringLiteral("color: #a8b3c5;"));
    nowPlayingHeaderLayout->addWidget(collapse);
    nowPlayingHeaderLayout->addStretch(1);
    nowPlayingHeaderLayout->addWidget(m_nowPlayingTitle);
    nowPlayingHeaderLayout->addStretch(1);
    nowPlayingHeaderLayout->addWidget(nowPlayingHint);
    nowPlayingLayout->addWidget(nowPlayingHeader);
    nowPlayingLayout->addWidget(PageFactory::resolveOverlay(OverlayKind::NowPlaying), 1);
    m_nowPlayingOverlay->hide();

    m_queueOverlay = new QFrame(this);
    m_queueOverlay->setObjectName(QStringLiteral("ctQueueOverlay"));
    m_queueOverlay->setStyleSheet(
        QStringLiteral("#ctQueueOverlay { background: rgba(0, 0, 0, 0.6); }"));
    auto* queueLayout = new QHBoxLayout(m_queueOverlay);
    queueLayout->setContentsMargins(0, 0, 0, 0);
    queueLayout->setSpacing(0);
    auto* queuePanel = new QFrame(m_queueOverlay);
    queuePanel->setObjectName(QStringLiteral("ctQueuePanel"));
    queuePanel->setFixedWidth(400);
    queuePanel->setStyleSheet(QStringLiteral("#ctQueuePanel { background: %1; }")
                                  .arg(CTColors::panel().name()));
    auto* queuePanelLayout = new QVBoxLayout(queuePanel);
    queuePanelLayout->setContentsMargins(0, 0, 0, 0);
    queuePanelLayout->setSpacing(0);
    auto* queueHeader = new QWidget(queuePanel);
    auto* queueHeaderLayout = new QHBoxLayout(queueHeader);
    queueHeaderLayout->setContentsMargins(16, 14, 10, 8);
    queueHeaderLayout->addWidget(ui::titleLabel(L10n::Common::Queue, 16, true));
    queueHeaderLayout->addStretch(1);
    auto* queueClose = makeGlyphButton(QStringLiteral("\uE1B1"), L10n::Common::Close, 14, queueHeader);
    QObject::connect(queueClose, &QPushButton::clicked, this,
        [] { AppState::shared().setShowQueue(false); });
    queueHeaderLayout->addWidget(queueClose);
    queuePanelLayout->addWidget(queueHeader);
    queuePanelLayout->addWidget(PageFactory::resolveOverlay(OverlayKind::Queue), 1);
    queueLayout->addStretch(1);
    queueLayout->addWidget(queuePanel);
    m_queueOverlay->hide();

    m_loginOverlay = new QFrame(this);
    m_loginOverlay->setObjectName(QStringLiteral("ctLoginOverlay"));
    m_loginOverlay->setStyleSheet(
        QStringLiteral("#ctLoginOverlay { background: rgba(0, 0, 0, 0.6); }"));
    auto* loginLayout = new QVBoxLayout(m_loginOverlay);
    loginLayout->setContentsMargins(0, 0, 0, 0);
    loginLayout->addStretch(1);
    auto* loginPanel = new QFrame(m_loginOverlay);
    loginPanel->setObjectName(QStringLiteral("ctLoginPanel"));
    loginPanel->setFixedWidth(420);
    loginPanel->setStyleSheet(QStringLiteral("#ctLoginPanel { background: %1; border-radius: 14px; }")
                                  .arg(CTColors::panel().name()));
    auto* loginPanelLayout = new QVBoxLayout(loginPanel);
    loginPanelLayout->setContentsMargins(0, 0, 0, 0);
    loginPanelLayout->addWidget(PageFactory::resolveOverlay(OverlayKind::Login));
    loginLayout->addWidget(loginPanel, 0, Qt::AlignHCenter);
    loginLayout->addStretch(1);
    m_loginOverlay->hide();
}

void MainWindow::closeEvent(QCloseEvent* event)
{
    const AppSettings settings = loadAppSettings();
    if (!CloseBehaviorPolicy::shouldQuitOnClose(settings)) {
        event->ignore();
        hide();
        TrayIconManager::shared().refreshVisibility();
        return;
    }
    QMainWindow::closeEvent(event);
    QCoreApplication::quit();
}

void MainWindow::resizeEvent(QResizeEvent* event)
{
    QMainWindow::resizeEvent(event);
    updateOverlayGeometry();
    updateResponsiveGeometry();
}

void MainWindow::showEvent(QShowEvent* event)
{
    QMainWindow::showEvent(event);
    updateOverlayGeometry();
    TrayIconManager::shared().refreshVisibility();
    if (m_startupCompleted) return;
    m_startupCompleted = true;
    try {
        MediaSessionIntegration::shared().initialize(this);
        ct::detach(HelperProcessManager::shared().startIfNeeded(CancellationToken::none()));
        ct::detach(AppState::shared().restoreLoginState());
        PlayerController::shared().resumeFromPersistence();
    } catch (const MusicException& error) {
        CTLog::general().error(
            QStringLiteral("启动初始化失败: %1").arg(CTLog::sanitize(error.userFacingMessage())));
    }
}

void MainWindow::keyPressEvent(QKeyEvent* event)
{
    if (handleKeyPress(event)) {
        event->accept();
        return;
    }
    QMainWindow::keyPressEvent(event);
}

bool MainWindow::eventFilter(QObject* watched, QEvent* event)
{
    if (event->type() == QEvent::KeyPress) {
        auto* keyEvent = static_cast<QKeyEvent*>(event);
        QWidget* widget = qobject_cast<QWidget*>(watched);
        if (widget != nullptr && widget->window() == this && handleKeyPress(keyEvent)) return true;
    }
    return QMainWindow::eventFilter(watched, event);
}

bool MainWindow::handleKeyPress(QKeyEvent* event)
{
    const Qt::KeyboardModifiers modifiers = event->modifiers();
    const bool ctrl = modifiers.testFlag(Qt::ControlModifier);
    const bool shift = modifiers.testFlag(Qt::ShiftModifier);
    const bool alt = modifiers.testFlag(Qt::AltModifier);
    PlayerController& player = PlayerController::shared();

    if (modifiers == Qt::NoModifier && event->key() == Qt::Key_Escape) {
        AppState& app = AppState::shared();
        if (app.isLoginPresented()) app.setIsLoginPresented(false);
        else if (app.showQueue()) app.setShowQueue(false);
        else if (app.isNowPlayingExpanded()) app.setIsNowPlayingExpanded(false);
        else return false;
        return true;
    }
    if (modifiers == Qt::NoModifier && event->key() == Qt::Key_Space) {
        QWidget* focus = QApplication::focusWidget();
        if (qobject_cast<QAbstractButton*>(focus) || qobject_cast<ui::CardButton*>(focus)) return false;
        if (isTextInputFocused()) return false;
        player.togglePlayPause();
        return true;
    }
    if (!ctrl || alt) return false;

    if (shift) {
        switch (event->key()) {
        case Qt::Key_0:
            AppState::shared().setShowQueue(!AppState::shared().showQueue());
            return true;
        case Qt::Key_L:
            player.cyclePlayMode();
            return true;
        case Qt::Key_D:
            toggleCurrentLike(true);
            return true;
        case Qt::Key_M:
            MiniPlayerWindow::toggle();
            return true;
        case Qt::Key_BracketRight:
            player.seekBy(-15);
            return true;
        default:
            return false;
        }
    }

    switch (event->key()) {
    case Qt::Key_F:
        AppState::shared().switchToTopLevel(Page::Search);
        if (auto* edit = m_content->currentWidget()->findChild<QLineEdit*>()) edit->setFocus();
        return true;
    case Qt::Key_Comma:
        AppState::shared().switchToTopLevel(Page::Settings);
        return true;
    case Qt::Key_BracketLeft:
        AppState::shared().goBack();
        return true;
    case Qt::Key_P:
        player.togglePlayPause();
        return true;
    case Qt::Key_Right:
        player.next();
        return true;
    case Qt::Key_Left:
        player.previous();
        return true;
    case Qt::Key_BracketRight:
        player.seekBy(15);
        return true;
    case Qt::Key_Up:
        player.setVolume(std::min(1.0f, player.volume() + 0.1f));
        if (player.volume() > 0.001f) player.setMuted(false);
        return true;
    case Qt::Key_Down:
        player.setVolume(std::max(0.0f, player.volume() - 0.1f));
        if (player.volume() > 0.001f) player.setMuted(false);
        return true;
    default:
        break;
    }

    if (event->key() >= Qt::Key_0 && event->key() <= Qt::Key_9) {
        const QChar digit(QLatin1Char(static_cast<char>('0' + (event->key() - Qt::Key_0))));
        if (switchToSidebar(digit)) return true;
    }
    return false;
}

bool MainWindow::isTextInputFocused() const
{
    QWidget* focus = QApplication::focusWidget();
    if (focus == nullptr) return false;
    return qobject_cast<QLineEdit*>(focus) != nullptr || qobject_cast<QTextEdit*>(focus) != nullptr
        || qobject_cast<QPlainTextEdit*>(focus) != nullptr;
}

bool MainWindow::switchToSidebar(QChar digit)
{
    const QList<Page> pages = page::sidebarPages();
    for (int index = 0; index < pages.size(); ++index) {
        const auto key = SidebarShortcuts::keyForIndex(index);
        if (key && *key == digit) {
            AppState::shared().switchToTopLevel(pages.at(index));
            return true;
        }
    }
    return false;
}

void MainWindow::toggleCurrentLike(bool requireWritePermission)
{
    AppState& app = AppState::shared();
    const auto& song = PlayerController::shared().currentSong();
    if (!song) return;
    if (requireWritePermission && !app.canPerformWrite()) return;
    Task<bool> task = app.toggleLike(*song);
    task.onComplete([this] {
        m_bar.notifyLike();
        updateBarSong();
    });
    ct::detach(std::move(task));
}

void MainWindow::openSleepMenu()
{
    auto* menu = new QMenu(this);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    for (int minutes : {15, 30, 45, 60, 90}) {
        QAction* action = menu->addAction(QStringLiteral("%1 分钟").arg(minutes));
        QObject::connect(action, &QAction::triggered, this,
            [minutes] { PlayerController::shared().setSleepTimer(minutes); });
    }
    menu->addSeparator();
    QAction* cancel = menu->addAction(QStringLiteral("关闭定时器"));
    QObject::connect(cancel, &QAction::triggered, [] { PlayerController::shared().setSleepTimer(0); });
    menu->popup(m_sleepButton->mapToGlobal(QPoint(0, -menu->sizeHint().height())));
}

void MainWindow::openRateMenu()
{
    auto* menu = new QMenu(this);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    PlayerController& player = PlayerController::shared();
    for (float rate : PlayerController::availableRates()) {
        QAction* action = menu->addAction(PlayerController::rateLabel(rate));
        action->setCheckable(true);
        action->setChecked(std::abs(player.playbackRate() - rate) < 0.001f);
        QObject::connect(action, &QAction::triggered, this, [this, rate] {
            PlayerController::shared().setPlaybackRate(rate);
            m_bar.refreshRate();
            updateBarRate();
        });
    }
    menu->popup(m_rateButton->mapToGlobal(QPoint(0, -menu->sizeHint().height())));
}

void MainWindow::cycleQuality()
{
    const QList<QualityLevel>& levels = songQualityPolicy::selectableLevels;
    const QualityLevel current = PlayerController::shared().requestedQuality();
    int index = -1;
    for (int i = 0; i < levels.size(); ++i) {
        if (levels.at(i) == current) index = i;
    }
    PlayerController::shared().setRequestedQuality(levels.at((index + 1 + levels.size()) % levels.size()));
}

void MainWindow::showPage(Page page)
{
    m_shownPage = page;
    m_pageTitle->setText(page::displayName(page));
    m_pageTitle->setVisible(page::isDetail(page));
    QWidget* widget = PageFactory::resolve(page);
    if (m_content->indexOf(widget) < 0) m_content->addWidget(widget);
    m_content->setCurrentWidget(widget);
    m_backButton->setVisible(AppState::shared().canGoBack());
}

void MainWindow::rebuildSidebarItems()
{
    m_sidebarList->clear();
    int index = 0;
    int totalHeight = 8;
    for (Page page : page::sidebarPages()) {
        if (index == 0 || index == 5) {
            auto* section = new QListWidgetItem(index == 0 ? QStringLiteral("在线音乐") : QStringLiteral("我的资料库"));
            section->setFlags(Qt::NoItemFlags);
            section->setSizeHint(QSize(0, 30));
            m_sidebarList->addItem(section);
            totalHeight += 34;
        }
        auto* item = new QListWidgetItem(CTTheme::icon(page::glyph(page)), page::displayName(page));
        item->setData(Qt::UserRole, static_cast<int>(page));
        item->setData(Qt::UserRole + 1, page::glyph(page));
        item->setSizeHint(QSize(0, 38));
        if (const auto key = SidebarShortcuts::keyForIndex(index))
            item->setToolTip(QStringLiteral("%1 · Ctrl+%2").arg(page::displayName(page), QString(*key)));
        m_sidebarList->addItem(item);
        totalHeight += 42;
        ++index;
    }
    m_sidebarList->setFixedHeight(totalHeight);
}

void MainWindow::syncSidebarSelection()
{
    m_syncingSidebar = true;
    int target = -1;
    const Page current = AppState::shared().currentPage();
    for (int i = 0; i < m_sidebarList->count(); ++i) {
        QListWidgetItem* item = m_sidebarList->item(i);
        if (item != nullptr && item->data(Qt::UserRole).isValid() && static_cast<Page>(item->data(Qt::UserRole).toInt()) == current) {
            target = i;
            break;
        }
    }
    m_sidebarList->setCurrentRow(target);
    m_syncingSidebar = false;
}

void MainWindow::syncPlaylists()
{
    const QList<Playlist>& playlists = AppState::shared().userPlaylists();
    QStringList signature;
    const int limit = static_cast<int>(std::min<qsizetype>(playlists.size(), 200));
    for (int i = 0; i < limit; ++i) {
        signature.append(playlists.at(i).id + QChar(0x1F) + playlists.at(i).name);
    }
    const QString joined = QStringLiteral("playlists:") + signature.join(QChar(0x1E));
    if (joined == m_playlistSignature) {
        updatePlaylistHighlight();
        return;
    }
    m_playlistSignature = joined;

    while (QLayoutItem* item = m_playlistLayout->takeAt(0)) {
        if (QWidget* widget = item->widget()) {
            widget->hide();
            widget->deleteLater();
        }
        delete item;
    }
    m_playlistButtons.clear();
    if (playlists.isEmpty()) {
        auto* hint = ui::secondaryLabel(AppState::shared().isLoggedIn() ? QStringLiteral("还没有创建歌单") : QStringLiteral("登录后同步你的歌单"));
        hint->setContentsMargins(12, 8, 0, 12);
        m_playlistLayout->addWidget(hint);
    }

    for (int i = 0; i < limit; ++i) {
        const Playlist& playlist = playlists.at(i);
        auto* button = new QPushButton(m_playlistPanel);
        button->setFlat(true);
        button->setCursor(Qt::PointingHandCursor);
        button->setStyleSheet(playlistButtonStyle(false));
        button->setText(button->fontMetrics().elidedText(playlist.name, Qt::ElideRight, 164));
        button->setToolTip(playlist.name);
        connect(button, &QPushButton::clicked, this,
            [id = playlist.id] { AppState::shared().openPlaylist(id); });
        m_playlistButtons.insert(playlist.id, button);
        m_playlistLayout->addWidget(button);
    }
    updatePlaylistHighlight();
}

void MainWindow::updatePlaylistHighlight()
{
    AppState& app = AppState::shared();
    const std::optional<QString> selected =
        app.currentPage() == Page::PlaylistDetail ? app.selectedPlaylistID() : std::nullopt;
    for (auto it = m_playlistButtons.cbegin(); it != m_playlistButtons.cend(); ++it) {
        it.value()->setStyleSheet(playlistButtonStyle(selected && *selected == it.key()));
    }
}

void MainWindow::updateAccountArea()
{
    const std::optional<AccountInfo> account = AppState::shared().account();
    m_accountName->setFullText(account ? account->nickname : L10n::Common::NotLoggedIn);
    m_accountHint->setText(!account ? QStringLiteral("点击扫码登录")
                                    : (account->isVIP ? QStringLiteral("VIP 会员")
                                                      : QStringLiteral("已登录")));
    m_accountGlyph->setText(
        account && account->isVIP ? QStringLiteral("\uE1D5") : QStringLiteral("\uE46C"));
}

void MainWindow::updateOverlays()
{
    AppState& app = AppState::shared();
    auto applyVisibility = [](QWidget* overlay, bool visible) {
        if (overlay == nullptr) return;
        if (overlay->isVisible() != visible) overlay->setVisible(visible);
        if (visible) overlay->raise();
    };
    applyVisibility(m_nowPlayingOverlay, app.isNowPlayingExpanded());
    applyVisibility(m_queueOverlay, app.showQueue());
    applyVisibility(m_loginOverlay, app.isLoginPresented());
}

void MainWindow::updateResponsiveGeometry()
{
    const bool compact = height() < 680;
    if (auto* sidebar = findChild<QWidget*>(QStringLiteral("ctSidebar"))) {
        const int desiredWidth = qBound(184, width() / 6, 224);
        sidebar->setFixedWidth(desiredWidth);
        for (auto* button : m_playlistButtons)
            button->setText(button->fontMetrics().elidedText(button->toolTip(), Qt::ElideRight, desiredWidth - 44));
    }
    if (m_sidebarList) {
        int totalHeight = 8;
        for (int i = 0; i < m_sidebarList->count(); ++i) {
            auto* item = m_sidebarList->item(i);
            const int rowHeight = item->data(Qt::UserRole).isValid() ? (compact ? 30 : 36) : 24;
            item->setSizeHint(QSize(0, rowHeight));
            totalHeight += rowHeight + 4;
        }
        m_sidebarList->setFixedHeight(totalHeight);
    }
    if (auto* bar = findChild<QWidget*>(QStringLiteral("ctPlayerBar")))
        bar->setFixedHeight(compact ? 88 : 96);
    if (m_volumeSlider) m_volumeSlider->setFixedWidth(width() < 1000 ? 56 : 80);
}

void MainWindow::updateOverlayGeometry()
{
    const QRect area = rect();
    if (m_nowPlayingOverlay != nullptr) m_nowPlayingOverlay->setGeometry(area);
    if (m_queueOverlay != nullptr) m_queueOverlay->setGeometry(area);
    if (m_loginOverlay != nullptr) m_loginOverlay->setGeometry(area);
}

void MainWindow::updateBarSong()
{
    m_barCover->setCoverURL(m_bar.coverUrl(), 92);
    m_barTitle->setFullText(m_bar.title());
    m_barArtist->setFullText(m_bar.artist());
    m_likeButton->setText(m_bar.likeGlyph());
    m_likeButton->setStyleSheet(QStringLiteral(
        "QPushButton { background: transparent; border: none; color: %1; font-size: 16px;"
        " font-family: 'lucide'; }"
        "QPushButton:hover { background: %2; border-radius: 6px; }")
                                    .arg(m_bar.likeForeground().name(),
                                        CTColors::overlay().name()));
    m_qualityButton->setText(m_bar.qualityLabel());
    if (m_nowPlayingTitle != nullptr) m_nowPlayingTitle->setFullText(m_bar.title());
}

void MainWindow::updateBarTransport()
{
    m_playPauseButton->setText(m_bar.playPauseGlyph());
    m_playPauseButton->setToolTip(m_bar.playPauseTooltip());
    m_playPauseButton->setAccessibleName(m_bar.playPauseTooltip());
    m_modeButton->setText(m_bar.modeGlyph());
    m_modeButton->setToolTip(m_bar.modeLabel());
}

void MainWindow::updateBarProgress()
{
    if (!m_progressDragging) {
        const int percent = static_cast<int>(std::lround(m_bar.progressPercent()));
        if (m_progressSlider->value() != percent) m_progressSlider->setValue(percent);
    }
    m_currentTimeLabel->setText(m_bar.currentTimeText());
    m_durationLabel->setText(m_bar.durationText());
    updateProgressTooltip();
}

void MainWindow::updateBarVolume()
{
    if (!m_syncingVolume) {
        const int percent = static_cast<int>(std::lround(m_bar.volumePercent()));
        if (m_volumeSlider->value() != percent) {
            m_syncingVolume = true;
            m_volumeSlider->setValue(percent);
            m_syncingVolume = false;
        }
    }
    updateMuteGlyph();
}

void MainWindow::updateBarRate()
{
    m_rateButton->setText(m_bar.rateLabel());
    m_rateButton->setVisible(m_bar.isRateAdjusted());
}

void MainWindow::updateSleepButton()
{
    const double remaining = PlayerController::shared().sleepTimerRemaining();
    if (remaining > 0) {
        const QString text = QStringLiteral("%1 分钟")
                                 .arg(qMax(1, static_cast<int>(std::ceil(remaining / 60.0))));
        m_sleepButton->setText(text);
        m_sleepButton->setStyleSheet(plainTextButtonStyle());
        m_sleepButton->setFixedSize(m_sleepButton->fontMetrics().horizontalAdvance(text) + 16, 32);
    } else {
        m_sleepButton->setText(QStringLiteral("\uE121"));
        m_sleepButton->setStyleSheet(glyphButtonStyle(15));
        m_sleepButton->setFixedSize(32, 32);
    }
}

void MainWindow::updateMuteGlyph()
{
    PlayerController& player = PlayerController::shared();
    m_muteButton->setText(player.isMuted() || player.volume() <= 0.001f ? QStringLiteral("\uE1AB")
                                                                        : QStringLiteral("\uE1AA"));
}

void MainWindow::updateProgressTooltip()
{
    PlayerController& player = PlayerController::shared();
    const QString tip = QStringLiteral("%1 / %2")
                            .arg(CTFormatting::time(player.currentTime()),
                                CTFormatting::time(player.duration()));
    if (tip == m_lastProgressTip) return;
    m_lastProgressTip = tip;
    m_progressSlider->setToolTip(tip);
}

} // namespace ct
