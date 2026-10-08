#pragma once

#include "Core/Artist/ArtistProfileSession.h"
#include "Core/Async.h"

#include <QPointer>
#include <QWidget>

#include <functional>
#include <memory>
#include <optional>

class QDialog;
class QGridLayout;
class QHBoxLayout;
class QLabel;
class QScrollArea;
class QVBoxLayout;

namespace ct {

class SongListView;

class ArtistDetailView : public QWidget {
    Q_OBJECT

public:
    explicit ArtistDetailView(QWidget* parent = nullptr);
    ~ArtistDetailView() override;

protected:
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;

private:
    enum class ArtistTab {
        Hot,
        Songs,
        Albums,
        MVs,
        About,
    };

    void scheduleAppChange();
    void scheduleRender();
    void handleAppChange();
    void load();
    Task<void> loadAsync(quint64 token);
    Task<void> loadTabAsync(ArtistTab tab);
    Task<void> loadMoreSongsAsync();
    Task<void> loadMoreAlbumsAsync();
    Task<void> loadMoreMVsAsync();
    Task<void> toggleFollowAsync(bool follow, quint64 token);
    Task<void> loadIntroForDialogAsync();

    void switchTab(ArtistTab tab);
    void render();
    void renderHeader();
    void renderTabs();
    void renderTabContent();
    void renderHot();
    void renderSongs();
    void renderAlbums();
    void renderMVs();
    void renderAbout();
    void showContent(QWidget* content);
    void showStatus(QWidget* status);
    void resetCollections();
    void refreshAlbumsGrid();
    void refreshMvsGrid();
    void populateIntroDialog();
    void showIntroDialog();

    QWidget* buildHeader();
    QWidget* buildPaginationFooter(bool isLoading, bool canLoadMore,
        const std::optional<QString>& error, std::function<void()> retry);
    QWidget* buildAboutSection(const QString& title, QWidget* content);
    QWidget* buildMvCard(const ArtistMV& mv);
    QString tabName(ArtistTab tab) const;
    int gridColumns(int cardWidth) const;

    static QString songIDs(const QList<Song>& songs);

    QWidget* m_headerHost = nullptr;
    QVBoxLayout* m_headerLayout = nullptr;
    QWidget* m_tabsHost = nullptr;
    QHBoxLayout* m_tabsLayout = nullptr;
    QWidget* m_contentHost = nullptr;
    QVBoxLayout* m_contentLayout = nullptr;
    QWidget* m_statusHost = nullptr;
    QVBoxLayout* m_statusLayout = nullptr;

    SongListView* m_hotList = nullptr;
    QWidget* m_songsPanel = nullptr;
    QLabel* m_songsHeader = nullptr;
    SongListView* m_songsList = nullptr;
    QWidget* m_songsFooter = nullptr;
    QVBoxLayout* m_songsFooterLayout = nullptr;

    QWidget* m_albumsPanel = nullptr;
    QScrollArea* m_albumsScroll = nullptr;
    QWidget* m_albumsGridHost = nullptr;
    QGridLayout* m_albumsGrid = nullptr;
    QWidget* m_albumsFooter = nullptr;
    QVBoxLayout* m_albumsFooterLayout = nullptr;

    QWidget* m_mvsPanel = nullptr;
    QScrollArea* m_mvsScroll = nullptr;
    QWidget* m_mvsGridHost = nullptr;
    QGridLayout* m_mvsGrid = nullptr;
    QWidget* m_mvsFooter = nullptr;
    QVBoxLayout* m_mvsFooterLayout = nullptr;

    QScrollArea* m_aboutScroll = nullptr;
    QWidget* m_aboutBody = nullptr;
    QVBoxLayout* m_aboutLayout = nullptr;

    QWidget* m_currentContent = nullptr;
    int m_lastAlbumColumns = 0;
    int m_lastMvColumns = 0;

    ArtistProfileSession m_session;
    ArtistTab m_tab = ArtistTab::Hot;
    std::optional<QString> m_activeArtistID;
    quint64 m_loadToken = 0;
    bool m_isAttached = false;
    bool m_isSubscribing = false;
    std::optional<QString> m_actionError;
    QString m_lastDataContextKey;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
    QPointer<QDialog> m_introDialog;
    QPointer<QVBoxLayout> m_introDialogLayout;
    int m_appObserver = 0;
    bool m_appChangeScheduled = false;
    bool m_renderScheduled = false;
};

} // namespace ct
