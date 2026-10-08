#pragma once

#include <QIcon>

class QAction;
class QMenu;
class QSystemTrayIcon;
class QWidget;

namespace ct {

// 系统托盘（对应 C# App/TrayIconManager.cs）。托盘不可用时静默降级。
class TrayIconManager {
public:
    static TrayIconManager& shared();

    static QIcon applicationIcon();

    void initialize(QWidget* mainWindow);
    void showTray();
    void hideTray();
    void refreshVisibility();
    void showMainWindow();
    bool isAvailable() const;

private:
    TrayIconManager() = default;

    bool hasVisibleWindows() const;

    QSystemTrayIcon* m_tray = nullptr;
    QMenu* m_menu = nullptr;
    QAction* m_playPauseAction = nullptr;
    QWidget* m_mainWindow = nullptr;
};

} // namespace ct
