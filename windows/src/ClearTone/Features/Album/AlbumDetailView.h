#pragma once

#include "Core/Async.h"
#include "Core/Models/MusicProvider.h"

#include <QWidget>

#include <memory>
#include <optional>

class QLabel;
class QScrollArea;
class QVBoxLayout;

namespace ct {

class SongListView;

class AlbumDetailView : public QWidget {
    Q_OBJECT

public:
    explicit AlbumDetailView(QWidget* parent = nullptr);
    ~AlbumDetailView() override;

protected:
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;

private:
    void scheduleAppChange();
    void handleAppChange();
    void load();
    Task<void> loadAsync(quint64 token);
    Task<void> loadSimilarAsync(quint64 token, QString albumID, Song first);
    Task<void> subscribeAsync(bool subscribe, quint64 token);
    void render();
    void renderHeader();
    void showStatus(QWidget* status);
    QWidget* buildHeader();
    void refreshTrackHeights();

    QWidget* m_headerHost = nullptr;
    QVBoxLayout* m_headerLayout = nullptr;
    QWidget* m_statusHost = nullptr;
    QVBoxLayout* m_statusLayout = nullptr;
    QWidget* m_bodyPanel = nullptr;
    QVBoxLayout* m_bodyLayout = nullptr;
    QScrollArea* m_bodyScroll = nullptr;
    SongListView* m_trackList = nullptr;
    QLabel* m_similarHeader = nullptr;
    SongListView* m_similarList = nullptr;

    std::optional<PlaylistDetail> m_detail;
    std::optional<QString> m_albumID;
    quint64 m_loadToken = 0;
    bool m_isLoading = false;
    bool m_isAttached = false;
    bool m_isSubscribing = false;
    std::optional<bool> m_isSubscribed;
    std::optional<QString> m_actionError;
    std::optional<QString> m_errorMessage;
    QString m_lastDataContextKey;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
    bool m_appChangeScheduled = false;
};

} // namespace ct
