#pragma once

#include "Core/Async.h"
#include "Core/Event.h"
#include "Core/Models/MusicModels.h"
#include "Core/Models/MusicProvider.h"
#include "Core/Models/MusicSocialProvider.h"

#include <QDateTime>
#include <QList>
#include <QSet>
#include <QString>
#include <QUuid>

#include <functional>
#include <optional>

namespace ct {

class NeteaseProvider;

enum class Page {
    Discover,
    Search,
    TopList,
    Radio,
    PersonalFM,
    MyMusic,
    Liked,
    Local,
    Recent,
    Messages,
    Profile,
    PlaylistDetail,
    RadioDetail,
    AlbumDetail,
    ArtistDetail,
    SongComments,
    Settings,
};

namespace page {
QString displayName(Page page);
QString glyph(Page page);
bool isDetail(Page page);
QList<Page> sidebarPages();
} // namespace page

class AppState {
public:
    static AppState& shared();

    explicit AppState(IMusicProvider* provider = nullptr, IMusicSocialProvider* social = nullptr);

    IMusicProvider* provider() const { return m_provider; }
    IMusicSocialProvider* social() const { return m_social; }
    NeteaseProvider* sessionOwner() const { return m_sessionOwner; }

    Event<> changed;
    Event<> dataContextChanged;

    Page currentPage() const { return m_currentPage; }
    void setCurrentPage(Page page);

    bool isNowPlayingExpanded() const { return m_isNowPlayingExpanded; }
    void setIsNowPlayingExpanded(bool value);

    bool showQueue() const { return m_showQueue; }
    void setShowQueue(bool value);

    std::optional<AccountInfo> account() const { return m_account; }
    bool isLoggedIn() const { return m_isLoggedIn; }

    std::optional<QString> selectedPlaylistID() const { return m_selectedPlaylistID; }
    void setSelectedPlaylistID(const std::optional<QString>& value);
    std::optional<QString> selectedRadioID() const { return m_selectedRadioID; }
    void setSelectedRadioID(const std::optional<QString>& value);
    std::optional<QString> selectedAlbumID() const { return m_selectedAlbumID; }
    void setSelectedAlbumID(const std::optional<QString>& value);
    std::optional<QString> selectedArtistID() const { return m_selectedArtistID; }
    void setSelectedArtistID(const std::optional<QString>& value);

    std::optional<Song> commentSong() const { return m_commentSong; }
    void setCommentSong(const std::optional<Song>& song);

    QString searchQuery() const { return m_searchQuery; }
    void setSearchQuery(const QString& query);

    const QList<Page>& pageHistory() const { return m_pageHistory; }
    bool canGoBack() const { return !m_pageHistory.isEmpty(); }
    void goBack();
    void switchToTopLevel(Page page);
    void navigateToDetail(Page page);

    void openPlaylist(const QString& id);
    void openRadio(const QString& id);
    void openAlbum(const QString& id);
    void openArtist(const QString& id);
    void openComments(const Song& song);

    const QList<Song>& likedSongs() const { return m_likedSongs; }
    int likesVersion() const { return m_likesVersion; }
    const QList<Playlist>& userPlaylists() const { return m_userPlaylists; }
    bool isLoadingUserPlaylists() const { return m_isLoadingUserPlaylists; }

    bool needsReLogin() const { return m_needsReLogin; }
    void setNeedsReLogin(bool value);
    bool isLoginPresented() const { return m_isLoginPresented; }
    void setIsLoginPresented(bool value);

    QString dataContextKey() const;
    bool canPerformWrite() const { return m_isLoggedIn && !m_needsReLogin; }
    int currentAccountGeneration() const { return m_accountGeneration; }

    Task<void> restoreLoginState();
    Task<void> didLogin(AccountInfo info);
    Task<void> performLogout();
    void applyAccount(const AccountInfo& info);

    Task<std::optional<Playlist>> createPlaylist(const QString& name, bool isPrivate);
    Task<bool> deletePlaylist(const Playlist& playlist);
    Task<bool> renamePlaylist(const Playlist& playlist, const QString& name);
    Task<bool> modifyPlaylist(const Playlist& playlist, const QStringList& songIDs, bool add);

    QString lastWriteError() const { return m_lastWriteError; }
    void clearWriteError();
    void publishWriteError(const MusicException& error);

    bool isLiked(const QString& songID) const;
    Task<void> loadLikedSongs(bool force = false);
    Task<void> loadUserPlaylists();
    Task<bool> toggleLike(const Song& song);

    QString likesWriteError() const { return m_likesWriteError; }
    int likeCooldownRemaining() const;
    bool isLikeWriteCoolingDown() const { return likeCooldownRemaining() > 0; }

    static bool isWriteThrottled(const MusicException& error);

private:
    void handleSessionExpired();
    void clearSession(bool clearLikedCache);
    void applyLikedSongs(const QList<Song>& songs, const std::optional<QStringList>& ids);
    void updateLikedID(const QString& songID, bool isLiked);
    void notifyChanged();
    void notifyDataContextChanged();
    void enterLikeWriteCooldown();

    IMusicProvider* m_provider;
    IMusicSocialProvider* m_social;
    NeteaseProvider* m_sessionOwner;

    Page m_currentPage = Page::Discover;
    bool m_isNowPlayingExpanded = false;
    bool m_showQueue = false;
    std::optional<AccountInfo> m_account;
    bool m_isLoggedIn = false;
    std::optional<QString> m_selectedPlaylistID;
    std::optional<QString> m_selectedRadioID;
    std::optional<QString> m_selectedAlbumID;
    std::optional<QString> m_selectedArtistID;
    std::optional<Song> m_commentSong;
    QString m_searchQuery;
    QList<Page> m_pageHistory;

    QList<Song> m_likedSongs;
    int m_likesVersion = 0;
    QList<Playlist> m_userPlaylists;
    bool m_isLoadingUserPlaylists = false;
    QUuid m_userPlaylistsToken;
    bool m_needsReLogin = false;
    bool m_isLoginPresented = false;
    QSet<QString> m_likedIDs;
    bool m_hasLoadedLikes = false;
    bool m_hasLoadedLikedSongs = false;
    QSet<QString> m_likeRequestsInFlight;
    std::optional<QDateTime> m_likeWriteCooldownUntil;
    QString m_likesWriteError;
    QString m_lastWriteError;
    int m_accountGeneration = 0;
};

} // namespace ct
