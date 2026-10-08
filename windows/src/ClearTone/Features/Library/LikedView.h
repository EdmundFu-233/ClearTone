#pragma once

#include "Core/Async.h"
#include "Core/Models/MusicModels.h"

#include <QString>
#include <QWidget>

#include <memory>

class QLabel;
class QPushButton;
class QVBoxLayout;

namespace ct {

class SongListView;

class LikedView : public QWidget {
    Q_OBJECT

public:
    explicit LikedView(QWidget* parent = nullptr);
    ~LikedView() override;

protected:
    void showEvent(QShowEvent* event) override;

private:
    void render();
    void scheduleAppChange();
    void handleAppChange();
    Task<void> loadAsync();
    QWidget* buildLoginRequired();

    QLabel* m_subtitle = nullptr;
    QPushButton* m_playAll = nullptr;
    QWidget* m_host = nullptr;
    QVBoxLayout* m_hostLayout = nullptr;
    SongListView* m_list = nullptr;

    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
    int m_contextObserver = 0;
    bool m_appChangeScheduled = false;
    QString m_lastDataContextKey;
    int m_lastLikesVersion = -1;
    bool m_lastLoggedIn = false;
};

} // namespace ct
