#pragma once

#include "App/AppState.h"
#include "App/PlayerBarModel.h"

#include <QHash>
#include <QMainWindow>
#include <QString>

#include <functional>

class QCloseEvent;
class QFrame;
class QKeyEvent;
class QLabel;
class QListWidget;
class QPushButton;
class QResizeEvent;
class QShowEvent;
class QSlider;
class QStackedWidget;
class QVBoxLayout;
class QWidget;

namespace ct {

class CoverImage;

// 主窗口（对应 C# MainWindow.axaml + MainWindow.axaml.cs）。
class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(QWidget* parent = nullptr);
    ~MainWindow() override;

    PlayerBarModel& bar() { return m_bar; }
    const PlayerBarModel& bar() const { return m_bar; }

protected:
    void closeEvent(QCloseEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;
    void showEvent(QShowEvent* event) override;
    void keyPressEvent(QKeyEvent* event) override;
    bool eventFilter(QObject* watched, QEvent* event) override;

private:
    QWidget* buildSidebar(QWidget* parent);
    QWidget* buildContentColumn(QWidget* parent);
    QWidget* buildPlayerBar(QWidget* parent);
    void buildOverlays();
    void applyTheme();
    void subscribeEvents();
    void refreshAll();

    void showPage(Page page);
    void rebuildSidebarItems();
    void syncSidebarSelection();
    void syncPlaylists();
    void updatePlaylistHighlight();
    void updateAccountArea();
    void updateOverlays();
    void updateOverlayGeometry();

    void updateBarSong();
    void updateBarTransport();
    void updateBarProgress();
    void updateBarVolume();
    void updateBarRate();
    void updateSleepButton();
    void updateMuteGlyph();
    void updateProgressTooltip();

    bool handleKeyPress(QKeyEvent* event);
    bool isTextInputFocused() const;
    bool switchToSidebar(QChar digit);
    void toggleCurrentLike(bool requireWritePermission);
    void openSleepMenu();
    void openRateMenu();
    void cycleQuality();

    PlayerBarModel m_bar;
    QList<std::function<void()>> m_unsubscribers;

    bool m_startupCompleted = false;
    bool m_syncingSidebar = false;
    bool m_syncingVolume = false;
    bool m_progressDragging = false;
    QString m_lastProgressTip;
    Page m_shownPage = Page::Discover;
    QString m_playlistSignature;

    QListWidget* m_sidebarList = nullptr;
    QWidget* m_playlistPanel = nullptr;
    QVBoxLayout* m_playlistLayout = nullptr;
    QHash<QString, QPushButton*> m_playlistButtons;

    QPushButton* m_accountButton = nullptr;
    QLabel* m_accountGlyph = nullptr;
    QLabel* m_accountName = nullptr;
    QLabel* m_accountHint = nullptr;

    QPushButton* m_backButton = nullptr;
    QLabel* m_pageTitle = nullptr;
    QPushButton* m_settingsButton = nullptr;
    QStackedWidget* m_content = nullptr;

    CoverImage* m_barCover = nullptr;
    QLabel* m_barTitle = nullptr;
    QLabel* m_barArtist = nullptr;
    QPushButton* m_expandButton = nullptr;
    QPushButton* m_titleButton = nullptr;
    QPushButton* m_likeButton = nullptr;
    QPushButton* m_prevButton = nullptr;
    QPushButton* m_playPauseButton = nullptr;
    QPushButton* m_nextButton = nullptr;
    QLabel* m_currentTimeLabel = nullptr;
    QSlider* m_progressSlider = nullptr;
    QLabel* m_durationLabel = nullptr;
    QPushButton* m_sleepButton = nullptr;
    QPushButton* m_modeButton = nullptr;
    QPushButton* m_queueButton = nullptr;
    QPushButton* m_rateButton = nullptr;
    QPushButton* m_qualityButton = nullptr;
    QPushButton* m_muteButton = nullptr;
    QSlider* m_volumeSlider = nullptr;

    QFrame* m_nowPlayingOverlay = nullptr;
    QFrame* m_queueOverlay = nullptr;
    QFrame* m_loginOverlay = nullptr;
    QLabel* m_nowPlayingTitle = nullptr;
};

} // namespace ct
