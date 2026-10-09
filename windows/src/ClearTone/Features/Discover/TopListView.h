#pragma once

#include "Core/Async.h"
#include "Core/Discover/TopListSession.h"
#include "Core/Models/DiscoveryModels.h"
#include "Core/Models/MusicModels.h"

#include <QList>
#include <QString>
#include <QWidget>

#include <memory>
#include <optional>

class QLabel;
class QHBoxLayout;
class QListWidget;
class QPushButton;
class QVBoxLayout;

namespace ct {

class SongListView;
class FlowLayout;
namespace ui { class ElidedLabel; }

class TopListView : public QWidget {
    Q_OBJECT

public:
    explicit TopListView(QWidget* parent = nullptr);
    ~TopListView() override;

protected:
    void showEvent(QShowEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;

private:
    void renderLists();
    void renderTracks();
    void rebuildAreaChips();
    void scheduleRenderLists();
    void selectListRow(int row);

    Task<void> loadTracksAsync(TopList list);
    Task<void> loadAreaAsync(TopSongArea area);

    TopListSession m_session;

    QWidget* m_listHost = nullptr;
    QVBoxLayout* m_listLayout = nullptr;
    QListWidget* m_listBox = nullptr;
    QString m_listsSignature;

    ui::ElidedLabel* m_trackTitle = nullptr;
    QLabel* m_trackCount = nullptr;
    QPushButton* m_playAll = nullptr;
    QWidget* m_areaRow = nullptr;
    FlowLayout* m_areaLayout = nullptr;
    QWidget* m_trackHost = nullptr;
    QVBoxLayout* m_trackLayout = nullptr;
    SongListView* m_songList = nullptr;

    QList<Song> m_tracks;
    std::optional<TopList> m_selected;
    std::optional<TopSongArea> m_selectedArea;
    quint64 m_trackToken = 0;
    bool m_isLoadingTracks = false;
    std::optional<QString> m_tracksError;
    bool m_loaded = false;
    bool m_renderListsScheduled = false;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
};

} // namespace ct
