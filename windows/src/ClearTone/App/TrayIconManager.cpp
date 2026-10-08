#include "App/TrayIconManager.h"

#include "App/AppState.h"
#include "App/CloseBehaviorPolicy.h"
#include "App/MiniPlayerWindow.h"
#include "Core/Logging/CTLog.h"
#include "Core/Persistence/AppSettings.h"
#include "Core/Persistence/PersistenceStore.h"
#include "DesignSystem/CTTheme.h"
#include "Playback/PlayerController.h"

#include <QAction>
#include <QApplication>
#include <QCoreApplication>
#include <QFile>
#include <QFont>
#include <QJsonObject>
#include <QJsonValue>
#include <QMenu>
#include <QPainter>
#include <QPixmap>
#include <QSystemTrayIcon>

namespace ct {

namespace {

AppSettings loadAppSettings()
{
    const QJsonValue value = PersistenceStore::shared().loadSetting(QStringLiteral("appSettings"));
    if (value.isObject()) return AppSettings::fromJson(value.toObject());
    return AppSettings{};
}

QIcon loadIconFile(const QString& name)
{
    QIcon icon(QStringLiteral(":/Assets/") + name);
    if (!icon.isNull()) return icon;
    const QString path = QCoreApplication::applicationDirPath() + QStringLiteral("/Assets/") + name;
    if (QFile::exists(path)) {
        QIcon fileIcon(path);
        if (!fileIcon.isNull()) return fileIcon;
    }
    return QIcon();
}

QIcon makeFallbackIcon()
{
    if (QCoreApplication::instance() == nullptr) return QIcon();
    QPixmap pixmap(64, 64);
    pixmap.fill(Qt::transparent);
    QPainter painter(&pixmap);
    painter.setRenderHint(QPainter::Antialiasing);
    painter.setBrush(CTColors::accent());
    painter.setPen(Qt::NoPen);
    painter.drawEllipse(QRectF(2, 2, 60, 60));
    painter.setPen(Qt::white);
    QFont font = painter.font();
    font.setPixelSize(30);
    font.setBold(true);
    painter.setFont(font);
    painter.drawText(pixmap.rect(), Qt::AlignCenter, QStringLiteral("澄"));
    painter.end();
    return QIcon(pixmap);
}

} // namespace

TrayIconManager& TrayIconManager::shared()
{
    static TrayIconManager* instance = new TrayIconManager();
    return *instance;
}

QIcon TrayIconManager::applicationIcon()
{
    static const QIcon icon = [] {
        const QIcon loaded = loadIconFile(QStringLiteral("appicon.png"));
        if (!loaded.isNull()) return loaded;
        return makeFallbackIcon();
    }();
    return icon;
}

void TrayIconManager::initialize(QWidget* mainWindow)
{
    m_mainWindow = mainWindow;
    if (m_tray != nullptr) return;
    if (QApplication::instance() == nullptr || !QSystemTrayIcon::isSystemTrayAvailable()) {
        CTLog::general().debug(QStringLiteral("系统托盘不可用，跳过托盘初始化"));
        return;
    }

    m_menu = new QMenu();
    QAction* showWindow = m_menu->addAction(QStringLiteral("显示主窗口"));
    QObject::connect(showWindow, &QAction::triggered, [this] { showMainWindow(); });

    QAction* miniPlayer = m_menu->addAction(QStringLiteral("迷你播放器"));
    QObject::connect(miniPlayer, &QAction::triggered, [] { MiniPlayerWindow::toggle(); });

    m_menu->addSeparator();

    m_playPauseAction = m_menu->addAction(QStringLiteral("播放·暂停"));
    QObject::connect(m_playPauseAction, &QAction::triggered,
        [] { PlayerController::shared().togglePlayPause(); });

    QAction* previous = m_menu->addAction(QStringLiteral("上一首"));
    QObject::connect(previous, &QAction::triggered, [] { PlayerController::shared().previous(); });

    QAction* next = m_menu->addAction(QStringLiteral("下一首"));
    QObject::connect(next, &QAction::triggered, [] { PlayerController::shared().next(); });

    QAction* like = m_menu->addAction(QStringLiteral("喜欢"));
    QObject::connect(like, &QAction::triggered, [] {
        AppState& app = AppState::shared();
        const auto& song = PlayerController::shared().currentSong();
        if (!song || !app.canPerformWrite()) return;
        detach(app.toggleLike(*song));
    });

    m_menu->addSeparator();

    QAction* settings = m_menu->addAction(QStringLiteral("设置"));
    QObject::connect(settings, &QAction::triggered, [] {
        AppState::shared().switchToTopLevel(Page::Settings);
    });
    QObject::connect(settings, &QAction::triggered, [this] { showMainWindow(); });

    QAction* quit = m_menu->addAction(QStringLiteral("退出应用"));
    QObject::connect(quit, &QAction::triggered, [] { QCoreApplication::quit(); });

    QObject::connect(m_menu, &QMenu::aboutToShow, [this] {
        if (m_playPauseAction != nullptr) {
            m_playPauseAction->setText(PlayerController::shared().playbackState().isPlayIntentActive()
                    ? QStringLiteral("暂停")
                    : QStringLiteral("播放"));
        }
    });

    QIcon icon = loadIconFile(QStringLiteral("trayicon.png"));
    if (icon.isNull()) icon = applicationIcon();

    m_tray = new QSystemTrayIcon(icon);
    m_tray->setToolTip(QStringLiteral("澄音 ClearTone"));
    m_tray->setContextMenu(m_menu);
    QObject::connect(m_tray, &QSystemTrayIcon::activated,
        [this](QSystemTrayIcon::ActivationReason reason) {
            if (reason == QSystemTrayIcon::Trigger || reason == QSystemTrayIcon::DoubleClick) {
                showMainWindow();
            }
        });
    m_tray->setVisible(false);
}

void TrayIconManager::showTray()
{
    if (m_tray == nullptr) return;
    m_tray->setVisible(true);
}

void TrayIconManager::hideTray()
{
    if (m_tray == nullptr) return;
    m_tray->setVisible(false);
}

void TrayIconManager::refreshVisibility()
{
    if (m_tray == nullptr) return;
    const AppSettings settings = loadAppSettings();
    if (CloseBehaviorPolicy::trayIconShouldBeVisible(settings, hasVisibleWindows())) {
        showTray();
    } else {
        hideTray();
    }
}

void TrayIconManager::showMainWindow()
{
    if (m_mainWindow == nullptr) return;
    m_mainWindow->show();
    m_mainWindow->setWindowState(m_mainWindow->windowState() & ~Qt::WindowMinimized);
    m_mainWindow->raise();
    m_mainWindow->activateWindow();
    refreshVisibility();
}

bool TrayIconManager::isAvailable() const { return m_tray != nullptr; }

bool TrayIconManager::hasVisibleWindows() const
{
    const QList<QWidget*> widgets = QApplication::topLevelWidgets();
    for (QWidget* widget : widgets) {
        if (widget == nullptr || qobject_cast<MiniPlayerWindow*>(widget) != nullptr) continue;
        if (!widget->isWindow() || !widget->isVisible()) continue;
        const Qt::WindowType type = widget->windowType();
        if (type == Qt::Popup || type == Qt::ToolTip) continue;
        return true;
    }
    return false;
}

} // namespace ct
