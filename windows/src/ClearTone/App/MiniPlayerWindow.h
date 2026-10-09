#pragma once

#include "Features/Shared/UIComponents.h"

#include <QWidget>

class QLabel;
class QMouseEvent;
class QPushButton;
class QSlider;
class QCloseEvent;

namespace ct {

class CoverImage;
class PlayerController;
struct AppSettings;

// 独立置顶迷你播放器（对应 C# App/MiniPlayerWindow.cs）。
class MiniPlayerWindow : public QWidget {
    Q_OBJECT

public:
    ~MiniPlayerWindow() override;

    static void toggle();

protected:
    void closeEvent(QCloseEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;

private:
    explicit MiniPlayerWindow(const AppSettings& settings);

    void buildUi();
    void refresh();
    void updateProgress();
    void onProgressPressed();
    void onProgressReleased();
    void onProgressValueChanged(int value);
    void positionBottomRight();

    static MiniPlayerWindow* s_instance;

    PlayerController* m_player;
    CoverImage* m_cover = nullptr;
    ui::ElidedLabel* m_title = nullptr;
    ui::ElidedLabel* m_artist = nullptr;
    QSlider* m_progress = nullptr;
    QPushButton* m_previous = nullptr;
    QPushButton* m_playPause = nullptr;
    QPushButton* m_next = nullptr;
    bool m_dragging = false;
    bool m_syncingProgress = false;
    int m_songSub = 0;
    int m_stateSub = 0;
    int m_queueSub = 0;
    int m_durationSub = 0;
    int m_timeSub = 0;
};

} // namespace ct
