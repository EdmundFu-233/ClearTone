#include "App/AppState.h"

#include "Core/ClearToneConstants.h"
#include "Core/Logging/CTLog.h"
#include "Core/Persistence/PersistenceStore.h"
#include "Core/Security/CredentialStore.h"
#include "Playback/PlayerController.h"
#include "Providers/Netease/NeteaseProvider.h"
#include "Providers/Netease/NeteaseSocialProvider.h"

#include <QUuid>

#include <cmath>

namespace ct {

namespace page {

QString displayName(Page page)
{
    switch (page) {
    case Page::Discover:
        return QStringLiteral("发现音乐");
    case Page::Search:
        return QStringLiteral("搜索");
    case Page::TopList:
        return QStringLiteral("排行榜");
    case Page::Radio:
        return QStringLiteral("电台");
    case Page::PersonalFM:
        return QStringLiteral("私人FM");
    case Page::MyMusic:
        return QStringLiteral("我的音乐");
    case Page::Liked:
        return QStringLiteral("喜欢的音乐");
    case Page::Local:
        return QStringLiteral("本地音乐");
    case Page::Recent:
        return QStringLiteral("最近播放");
    case Page::Messages:
        return QStringLiteral("消息");
    case Page::Profile:
        return QStringLiteral("我的");
    case Page::PlaylistDetail:
        return QStringLiteral("歌单详情");
    case Page::RadioDetail:
        return QStringLiteral("电台详情");
    case Page::AlbumDetail:
        return QStringLiteral("专辑详情");
    case Page::ArtistDetail:
        return QStringLiteral("歌手详情");
    case Page::SongComments:
        return QStringLiteral("歌曲评论");
    case Page::Settings:
        return QStringLiteral("设置");
    }
    return QStringLiteral("设置");
}

QString glyph(Page page)
{
    switch (page) {
    case Page::Discover:
        return QStringLiteral("\uE8D6");
    case Page::Search:
        return QStringLiteral("\uE721");
    case Page::TopList:
        return QStringLiteral("\uE8FD");
    case Page::Radio:
        return QStringLiteral("\uE704");
    case Page::PersonalFM:
        return QStringLiteral("\uE720");
    case Page::MyMusic:
        return QStringLiteral("\uE8A5");
    case Page::Liked:
        return QStringLiteral("\uE734");
    case Page::Local:
        return QStringLiteral("\uE8B7");
    case Page::Recent:
        return QStringLiteral("\uE81C");
    case Page::Messages:
        return QStringLiteral("\uE8BD");
    case Page::Profile:
        return QStringLiteral("\uE77B");
    case Page::PlaylistDetail:
        return QStringLiteral("\uE8A5");
    case Page::RadioDetail:
        return QStringLiteral("\uE704");
    case Page::AlbumDetail:
        return QStringLiteral("\uE8B9");
    case Page::ArtistDetail:
        return QStringLiteral("\uE77B");
    case Page::SongComments:
        return QStringLiteral("\uE90A");
    case Page::Settings:
        return QStringLiteral("\uE713");
    }
    return QStringLiteral("\uE713");
}

bool isDetail(Page page)
{
    return page == Page::PlaylistDetail || page == Page::RadioDetail || page == Page::AlbumDetail
        || page == Page::ArtistDetail || page == Page::SongComments;
}

QList<Page> sidebarPages()
{
    return {Page::Discover, Page::Search, Page::TopList, Page::Radio, Page::PersonalFM,
        Page::MyMusic, Page::Liked, Page::Local, Page::Recent, Page::Messages};
}

} // namespace page

AppState& AppState::shared()
{
    static AppState* instance = new AppState();
    return *instance;
}

AppState::AppState(IMusicProvider* provider, IMusicSocialProvider* social)
    : m_provider(provider != nullptr ? provider : &NeteaseProvider::shared())
    , m_social(social != nullptr ? social : &NeteaseSocialProvider::shared())
    , m_sessionOwner(&NeteaseProvider::shared())
{
    m_sessionOwner->sessionExpired = [this] { handleSessionExpired(); };
}

void AppState::notifyChanged()
{
    changed.publish();
}

void AppState::notifyDataContextChanged()
{
    notifyChanged();
    dataContextChanged.publish();
}

void AppState::setCurrentPage(Page page)
{
    if (m_currentPage == page) return;
    m_currentPage = page;
    notifyChanged();
}

void AppState::setIsNowPlayingExpanded(bool value)
{
    if (m_isNowPlayingExpanded == value) return;
    m_isNowPlayingExpanded = value;
    notifyChanged();
}

void AppState::setShowQueue(bool value)
{
    if (m_showQueue == value) return;
    m_showQueue = value;
    notifyChanged();
}

void AppState::setSelectedPlaylistID(const std::optional<QString>& value)
{
    if (m_selectedPlaylistID == value) return;
    m_selectedPlaylistID = value;
    notifyChanged();
}

void AppState::setSelectedRadioID(const std::optional<QString>& value)
{
    if (m_selectedRadioID == value) return;
    m_selectedRadioID = value;
    notifyChanged();
}

void AppState::setSelectedAlbumID(const std::optional<QString>& value)
{
    if (m_selectedAlbumID == value) return;
    m_selectedAlbumID = value;
    notifyChanged();
}

void AppState::setSelectedArtistID(const std::optional<QString>& value)
{
    if (m_selectedArtistID == value) return;
    m_selectedArtistID = value;
    notifyChanged();
}

void AppState::setCommentSong(const std::optional<Song>& song)
{
    m_commentSong = song;
    notifyChanged();
}

void AppState::setSearchQuery(const QString& query)
{
    if (m_searchQuery == query) return;
    m_searchQuery = query;
    notifyChanged();
}

void AppState::setNeedsReLogin(bool value)
{
    if (m_needsReLogin == value) return;
    m_needsReLogin = value;
    notifyChanged();
}

void AppState::setIsLoginPresented(bool value)
{
    if (m_isLoginPresented == value) return;
    m_isLoginPresented = value;
    notifyChanged();
}

void AppState::goBack()
{
    if (m_pageHistory.isEmpty()) return;
    const Page previous = m_pageHistory.takeLast();
    notifyChanged();
    setCurrentPage(previous);
}

void AppState::switchToTopLevel(Page page)
{
    m_pageHistory.clear();
    notifyChanged();
    setCurrentPage(page);
}

void AppState::navigateToDetail(Page page)
{
    if (page == m_currentPage) return;
    if (!m_pageHistory.isEmpty() && m_pageHistory.last() == page) {
        setCurrentPage(page);
        return;
    }
    m_pageHistory.append(m_currentPage);
    notifyChanged();
    setCurrentPage(page);
}

void AppState::openPlaylist(const QString& id)
{
    setSelectedPlaylistID(id);
    navigateToDetail(Page::PlaylistDetail);
}

void AppState::openRadio(const QString& id)
{
    setSelectedRadioID(id);
    navigateToDetail(Page::RadioDetail);
}

void AppState::openAlbum(const QString& id)
{
    setSelectedAlbumID(id);
    navigateToDetail(Page::AlbumDetail);
}

void AppState::openArtist(const QString& id)
{
    setSelectedArtistID(id);
    navigateToDetail(Page::ArtistDetail);
}

void AppState::openComments(const Song& song)
{
    setCommentSong(song);
    navigateToDetail(Page::SongComments);
}

QString AppState::dataContextKey() const
{
    return QStringLiteral("%1-%2-%3")
        .arg(m_isLoggedIn ? QStringLiteral("true") : QStringLiteral("false"),
            m_account ? m_account->userID : QStringLiteral("guest"))
        .arg(m_accountGeneration);
}

void AppState::handleSessionExpired()
{
    if (!m_isLoggedIn && !m_account) return;
    CTLog::security().warn(QStringLiteral("登录状态已失效，请重新登录"));
    clearSession(false);
    setNeedsReLogin(true);
    setIsLoginPresented(true);
}

Task<void> AppState::restoreLoginState()
{
    if (m_isLoggedIn) co_return;
    if (!m_account) m_account = PersistenceStore::shared().loadCachedAccount();
    PlayerController::shared().setAccountIsVIP(m_account && m_account->isVIP);

    if (m_likedSongs.isEmpty()) {
        const QList<Song> cachedSongs = PersistenceStore::shared().loadCachedLikedSongs();
        const QStringList cachedIDs = PersistenceStore::shared().loadCachedLikedSongIDs();
        applyLikedSongs(cachedSongs, cachedIDs.isEmpty() ? std::nullopt : std::make_optional(cachedIDs));
    }

    const auto cookie = NeteaseProvider::loadLoginCookie();
    if (!cookie || cookie->isEmpty()) {
        clearSession(false);
        co_return;
    }

    if (m_account) {
        m_isLoggedIn = true;
        notifyChanged();
    }

    try {
        const auto info = co_await m_provider->fetchAccountInfo(CancellationToken::none());
        if (info) {
            applyAccount(*info);
        } else {
            clearSession(true);
            co_return;
        }
    } catch (const MusicException& error) {
        CTLog::security().warn(
            QStringLiteral("恢复登录态失败: %1").arg(CTLog::sanitize(error.message())));
        if (!m_account) {
            m_isLoggedIn = false;
            notifyChanged();
        }
    }

    if (m_isLoggedIn) {
        co_await loadLikedSongs(true);
        co_await loadUserPlaylists();
    }
}

Task<void> AppState::didLogin(AccountInfo info)
{
    applyAccount(info);
    m_sessionOwner->clearCache();
    m_sessionOwner->resetSessionGuard();
    co_await loadLikedSongs(true);
    co_await loadUserPlaylists();
}

Task<void> AppState::performLogout()
{
    try {
        co_await m_provider->logout(CancellationToken::none());
    } catch (const MusicException&) {
    }
    m_sessionOwner->clearCache();
    clearSession(true);
}

void AppState::applyAccount(const AccountInfo& info)
{
    m_account = info;
    m_isLoggedIn = true;
    m_accountGeneration += 1;
    m_needsReLogin = false;
    notifyDataContextChanged();
    PlayerController::shared().setAccountIsVIP(info.isVIP);
    if (!info.userID.isEmpty()) {
        CredentialStore::shared().save(info.userID, CredentialKey::NeteaseUserID);
    }
    PersistenceStore::shared().saveCachedAccount(info);
}

void AppState::clearSession(bool clearLikedCache)
{
    m_account.reset();
    m_isLoggedIn = false;
    m_likeWriteCooldownUntil.reset();
    m_likesWriteError.clear();
    m_likeRequestsInFlight.clear();
    PlayerController::shared().setAccountIsVIP(false);
    m_hasLoadedLikes = false;
    m_hasLoadedLikedSongs = false;
    m_likedIDs.clear();
    m_likedSongs.clear();
    m_likesVersion += 1;
    m_accountGeneration += 1;
    m_userPlaylistsToken = QUuid::createUuid();
    m_userPlaylists.clear();
    m_isLoadingUserPlaylists = false;
    notifyDataContextChanged();
    PersistenceStore::shared().clearCachedAccount();
    if (clearLikedCache) {
        PersistenceStore::shared().clearCachedLikedSongs();
        PersistenceStore::shared().clearCachedUserPlaylists();
    }
}

Task<std::optional<Playlist>> AppState::createPlaylist(const QString& name, bool isPrivate)
{
    if (!canPerformWrite()) co_return std::nullopt;
    try {
        const Playlist created = co_await m_social->createPlaylist(name, isPrivate, CancellationToken::none());
        m_userPlaylists.prepend(created);
        notifyChanged();
        PersistenceStore::shared().saveCachedUserPlaylists(m_userPlaylists);
        co_return created;
    } catch (const MusicException& error) {
        CTLog::general().error(QStringLiteral("创建歌单失败: %1").arg(CTLog::sanitize(error.message())));
        m_lastWriteError = error.userFacingMessage();
        notifyChanged();
        co_return std::nullopt;
    }
}

Task<bool> AppState::deletePlaylist(const Playlist& playlist)
{
    if (!canPerformWrite()) co_return false;
    try {
        co_await m_social->deletePlaylist(playlist.id, CancellationToken::none());
        for (int i = m_userPlaylists.size() - 1; i >= 0; --i) {
            if (m_userPlaylists[i].id == playlist.id) m_userPlaylists.removeAt(i);
        }
        notifyChanged();
        PersistenceStore::shared().saveCachedUserPlaylists(m_userPlaylists);
        if (m_selectedPlaylistID && *m_selectedPlaylistID == playlist.id) {
            setCurrentPage(Page::MyMusic);
        }
        co_return true;
    } catch (const MusicException& error) {
        CTLog::general().error(QStringLiteral("删除歌单失败: %1").arg(CTLog::sanitize(error.message())));
        m_lastWriteError = error.userFacingMessage();
        notifyChanged();
        co_return false;
    }
}

Task<bool> AppState::renamePlaylist(const Playlist& playlist, const QString& name)
{
    if (!canPerformWrite()) co_return false;
    try {
        co_await m_social->updatePlaylistName(playlist.id, name, CancellationToken::none());
        for (Playlist& item : m_userPlaylists) {
            if (item.id == playlist.id) {
                item.name = name;
                notifyChanged();
                break;
            }
        }
        PersistenceStore::shared().saveCachedUserPlaylists(m_userPlaylists);
        co_return true;
    } catch (const MusicException& error) {
        CTLog::general().error(QStringLiteral("重命名歌单失败: %1").arg(CTLog::sanitize(error.message())));
        m_lastWriteError = error.userFacingMessage();
        notifyChanged();
        co_return false;
    }
}

Task<bool> AppState::modifyPlaylist(const Playlist& playlist, const QStringList& songIDs, bool add)
{
    if (!canPerformWrite() || songIDs.isEmpty()) co_return false;
    try {
        if (add) {
            co_await m_social->addSongsToPlaylist(playlist.id, songIDs, CancellationToken::none());
        } else {
            co_await m_social->removeSongsFromPlaylist(playlist.id, songIDs, CancellationToken::none());
        }
        m_sessionOwner->clearCache();
        for (Playlist& item : m_userPlaylists) {
            if (item.id == playlist.id) {
                item.trackCount = qMax(0, item.trackCount + (add ? songIDs.size() : -songIDs.size()));
                notifyChanged();
                PersistenceStore::shared().saveCachedUserPlaylists(m_userPlaylists);
                break;
            }
        }
        co_return true;
    } catch (const MusicException& error) {
        CTLog::general().error(QStringLiteral("%1歌曲失败: %2")
                                   .arg(add ? QStringLiteral("添加") : QStringLiteral("移除"),
                                       CTLog::sanitize(error.message())));
        m_lastWriteError = error.userFacingMessage();
        notifyChanged();
        co_return false;
    }
}

void AppState::clearWriteError()
{
    m_lastWriteError.clear();
    notifyChanged();
}

void AppState::publishWriteError(const MusicException& error)
{
    CTLog::general().error(QStringLiteral("写操作失败: %1").arg(CTLog::sanitize(error.message())));
    m_lastWriteError = error.userFacingMessage();
    notifyChanged();
}

bool AppState::isLiked(const QString& songID) const { return m_likedIDs.contains(songID); }

Task<void> AppState::loadLikedSongs(bool force)
{
    if (!m_isLoggedIn) co_return;
    if (m_hasLoadedLikes && m_hasLoadedLikedSongs && !force) co_return;
    const int generation = m_accountGeneration;
    const QString dataContext = dataContextKey();
    try {
        const QStringList ids = co_await m_provider->fetchLikedSongIDs(CancellationToken::none());
        if (generation != m_accountGeneration || dataContext != dataContextKey()) co_return;
        applyLikedSongs(PersistenceStore::shared().loadCachedLikedSongs(), ids);
        PersistenceStore::shared().saveCachedLikedSongIDs(ids);
        m_hasLoadedLikes = true;

        const QList<Song> songs = co_await m_provider->fetchLikedSongs(CancellationToken::none());
        if (generation != m_accountGeneration || dataContext != dataContextKey()) co_return;
        applyLikedSongs(songs, ids);
        PersistenceStore::shared().saveCachedLikedSongs(songs);
        m_hasLoadedLikedSongs = true;
    } catch (const MusicException& error) {
        CTLog::general().error(QStringLiteral("加载喜欢的歌曲失败: %1").arg(CTLog::sanitize(error.message())));
    }
}

Task<void> AppState::loadUserPlaylists()
{
    const QUuid token = QUuid::createUuid();
    m_userPlaylistsToken = token;
    const int generation = m_accountGeneration;
    if (!m_isLoggedIn) {
        m_userPlaylists.clear();
        notifyChanged();
        co_return;
    }
    if (m_userPlaylists.isEmpty()) {
        const QList<Playlist> cached = PersistenceStore::shared().loadCachedUserPlaylists();
        if (m_userPlaylistsToken != token) co_return;
        m_userPlaylists = cached;
        notifyChanged();
    }
    m_isLoadingUserPlaylists = m_userPlaylists.isEmpty();
    notifyChanged();
    try {
        const QList<Playlist> loaded = co_await m_provider->fetchUserPlaylists(CancellationToken::none());
        if (m_userPlaylistsToken != token || generation != m_accountGeneration) co_return;
        m_userPlaylists = loaded;
        notifyChanged();
        PersistenceStore::shared().saveCachedUserPlaylists(loaded);
    } catch (const MusicException& error) {
        if (m_userPlaylistsToken != token) co_return;
        CTLog::general().error(QStringLiteral("加载歌单失败: %1").arg(CTLog::sanitize(error.message())));
    }
    if (m_userPlaylistsToken == token) {
        m_isLoadingUserPlaylists = false;
        notifyChanged();
    }
}

Task<bool> AppState::toggleLike(const Song& song)
{
    if (song.source != SongSource::Netease || !m_isLoggedIn) co_return false;
    if (isLikeWriteCoolingDown()) co_return m_likedIDs.contains(song.id);
    if (m_likeRequestsInFlight.contains(song.id)) co_return m_likedIDs.contains(song.id);
    m_likeRequestsInFlight.insert(song.id);

    const bool wasLiked = m_likedIDs.contains(song.id);
    updateLikedID(song.id, !wasLiked);
    QList<Song> optimistic;
    for (const Song& item : std::as_const(m_likedSongs)) {
        if (item.id != song.id) optimistic.append(item);
    }
    if (!wasLiked) optimistic.prepend(song);
    m_likedSongs = optimistic;
    notifyChanged();

    try {
        co_await m_provider->likeSong(song.id, !wasLiked, CancellationToken::none());
        PersistenceStore::shared().saveCachedLikedSongIDs(m_likedIDs.values());
        PersistenceStore::shared().saveCachedLikedSongs(m_likedSongs);
        m_likesWriteError.clear();
        m_likeRequestsInFlight.remove(song.id);
        notifyChanged();
        co_return !wasLiked;
    } catch (const MusicException& error) {
        CTLog::general().error(QStringLiteral("收藏操作失败: %1").arg(CTLog::sanitize(error.message())));
        updateLikedID(song.id, wasLiked);
        QList<Song> reverted;
        for (const Song& item : std::as_const(m_likedSongs)) {
            if (item.id != song.id) reverted.append(item);
        }
        if (wasLiked) reverted.prepend(song);
        m_likedSongs = reverted;
        notifyChanged();
        PersistenceStore::shared().saveCachedLikedSongIDs(m_likedIDs.values());
        PersistenceStore::shared().saveCachedLikedSongs(m_likedSongs);
        m_lastWriteError = error.userFacingMessage();
        notifyChanged();
        if (isWriteThrottled(error)) {
            enterLikeWriteCooldown();
        }
        m_likeRequestsInFlight.remove(song.id);
        co_return wasLiked;
    }
}

int AppState::likeCooldownRemaining() const
{
    if (!m_likeWriteCooldownUntil) return 0;
    const double remaining =
        QDateTime::currentDateTime().msecsTo(*m_likeWriteCooldownUntil) / 1000.0;
    return remaining > 0 ? static_cast<int>(std::ceil(remaining)) : 0;
}

void AppState::enterLikeWriteCooldown()
{
    m_likeWriteCooldownUntil =
        QDateTime::currentDateTime().addSecs(ClearToneConstants::likeWriteCooldownSeconds);
    m_likesWriteError = QStringLiteral("已触发限流，请稍后再试");
    notifyChanged();
}

bool AppState::isWriteThrottled(const MusicException& error)
{
    switch (error.kind()) {
    case MusicErrorKind::ApiError:
        return error.code() == 405 || error.code() == 524;
    case MusicErrorKind::RateLimited:
        return true;
    default:
        return false;
    }
}

void AppState::applyLikedSongs(const QList<Song>& songs, const std::optional<QStringList>& ids)
{
    m_likedSongs = songs;
    if (ids) {
        m_likedIDs = QSet<QString>(ids->begin(), ids->end());
    } else {
        m_likedIDs.clear();
        for (const Song& song : songs) m_likedIDs.insert(song.id);
    }
    m_likesVersion += 1;
    notifyChanged();
}

void AppState::updateLikedID(const QString& songID, bool isLiked)
{
    if (isLiked) {
        m_likedIDs.insert(songID);
    } else {
        m_likedIDs.remove(songID);
    }
    m_likesVersion += 1;
    notifyChanged();
}

} // namespace ct
