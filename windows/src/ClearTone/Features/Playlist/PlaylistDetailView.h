#pragma once

#include "Core/Async.h"
#include "Core/Models/MusicProvider.h"

#include <QPointer>
#include <QWidget>

#include <memory>
#include <optional>

class QDialog;
class QLabel;
class QPushButton;
class QVBoxLayout;

namespace ct {

class SongListView;

class PlaylistDetailView : public QWidget {
    Q_OBJECT

public:
    explicit PlaylistDetailView(QWidget* parent = nullptr);
    ~PlaylistDetailView() override;

protected:
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;
    bool eventFilter(QObject* watched, QEvent* event) override;

private:
    void scheduleAppChange();
    void handleAppChange();
    void load();
    Task<void> loadAsync(quint64 token);
    Task<void> streamAsync(QString playlistID, int totalCount, quint64 token);
    Task<void> fetchRemainingAsync(QString playlistID, int totalCount, quint64 token);
    Task<void> subscribeAsync(bool subscribe, quint64 token);
    Task<void> renameAsync(Playlist playlist, QString name, QPointer<QDialog> dialog,
        QPointer<QLabel> error, QPointer<QPushButton> confirm);
    Task<void> deleteAsync(Playlist playlist, QPointer<QDialog> dialog, QPointer<QLabel> error,
        QPointer<QPushButton> confirm);
    Task<void> removeTrackAsync(Playlist playlist, QString songID, QPointer<QDialog> dialog,
        QPointer<QLabel> error, QPointer<QPushButton> confirm);
    void render();
    void renderHeader();
    void showStatus(QWidget* status);
    QWidget* buildHeader();
    void showRenameDialog();
    void showDeleteDialog();
    void showRemoveDialog(const Song& song);
    void showOwnedTrackMenu(const QPoint& position, int row);
    bool isOwned() const;

    QWidget* m_headerHost = nullptr;
    QVBoxLayout* m_headerLayout = nullptr;
    SongListView* m_trackList = nullptr;
    QWidget* m_statusHost = nullptr;
    QVBoxLayout* m_statusLayout = nullptr;

    std::optional<PlaylistDetail> m_detail;
    std::optional<QString> m_playlistID;
    quint64 m_loadToken = 0;
    bool m_isLoading = false;
    bool m_isAttached = false;
    bool m_isOwned = false;
    bool m_isSubscribing = false;
    std::optional<bool> m_isSubscribed;
    std::optional<QString> m_errorMessage;
    QString m_lastDataContextKey;
    std::shared_ptr<CancellationTokenSource> m_loadCts;
    std::shared_ptr<CancellationTokenSource> m_streamCts;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
    bool m_appChangeScheduled = false;
};

} // namespace ct
