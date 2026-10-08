#pragma once

#include "Core/Async.h"
#include "Core/Models/DiscoveryModels.h"
#include "Core/Models/MusicModels.h"
#include "Core/Models/RadioModels.h"

#include <QList>
#include <QSet>
#include <QString>
#include <QWidget>

#include <memory>
#include <optional>

class QLabel;
class QPushButton;
class QVBoxLayout;

namespace ct {

class DiscoverView : public QWidget {
    Q_OBJECT

public:
    explicit DiscoverView(QWidget* parent = nullptr);
    ~DiscoverView() override;

protected:
    void showEvent(QShowEvent* event) override;

private:
    void renderAll();
    void renderDaily();
    void renderPlaylists();
    void renderDailyPlaylists();
    void renderRadios();
    void renderNewSongs();
    void renderNewAlbums();

    void loadAll();
    Task<void> loadDailySongsAsync(quint64 token);
    Task<void> loadPlaylistsAsync(quint64 token);
    Task<void> loadDailyPlaylistsAsync(quint64 token);
    Task<void> loadRadiosAsync(quint64 token);
    Task<void> loadNewSongsAsync(quint64 token);
    Task<void> loadNewAlbumsAsync(quint64 token);
    Task<void> dislikeDailyAsync(Song song);

    void scheduleAppChange();
    void handleAppChange();

    QWidget* buildSongStrip(const QList<Song>& songs, bool allowDislike);

    QWidget* m_dailyHost = nullptr;
    QVBoxLayout* m_dailyLayout = nullptr;
    QWidget* m_playlistsHost = nullptr;
    QVBoxLayout* m_playlistsLayout = nullptr;
    QWidget* m_dailyPlaylistsHost = nullptr;
    QVBoxLayout* m_dailyPlaylistsLayout = nullptr;
    QWidget* m_radiosHost = nullptr;
    QVBoxLayout* m_radiosLayout = nullptr;
    QWidget* m_newSongsHost = nullptr;
    QVBoxLayout* m_newSongsLayout = nullptr;
    QWidget* m_newAlbumsHost = nullptr;
    QVBoxLayout* m_newAlbumsLayout = nullptr;
    QPushButton* m_dailyPlayAll = nullptr;
    QPushButton* m_newSongsPlayAll = nullptr;

    QList<Song> m_dailySongs;
    QSet<QString> m_dailyDislikesInFlight;
    bool m_dailyLoading = false;
    std::optional<QString> m_dailyError;

    QList<Playlist> m_playlists;
    bool m_playlistsLoading = false;
    std::optional<QString> m_playlistsError;

    QList<Playlist> m_dailyPlaylists;
    bool m_dailyPlaylistsLoading = false;
    std::optional<QString> m_dailyPlaylistsError;

    QList<RadioStation> m_radios;
    bool m_radiosLoading = false;
    std::optional<QString> m_radiosError;

    QList<Song> m_newSongs;
    bool m_newSongsLoading = false;
    std::optional<QString> m_newSongsError;

    QList<Album> m_newAlbums;
    bool m_newAlbumsLoading = false;
    std::optional<QString> m_newAlbumsError;

    quint64 m_loadToken = 0;
    QString m_lastDataContextKey;
    bool m_appChangeScheduled = false;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    int m_appObserver = 0;
    int m_contextObserver = 0;
};

} // namespace ct
