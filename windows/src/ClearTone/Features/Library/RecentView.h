#pragma once

#include <QWidget>

class QLabel;
class QPushButton;
class QVBoxLayout;

namespace ct {

class SongListView;

class RecentView : public QWidget {
    Q_OBJECT

public:
    explicit RecentView(QWidget* parent = nullptr);
    ~RecentView() override;

private:
    void render();
    void scheduleRender();

    QLabel* m_subtitle = nullptr;
    QPushButton* m_playAll = nullptr;
    QWidget* m_host = nullptr;
    QVBoxLayout* m_hostLayout = nullptr;
    SongListView* m_list = nullptr;

    int m_songObserver = 0;
    int m_recentObserver = 0;
    bool m_renderScheduled = false;
};

} // namespace ct
