#pragma once

#include "Core/Async.h"
#include "Core/Comments/CommentProvider.h"
#include "Core/Models/DiscoveryModels.h"
#include "Core/Models/MusicModels.h"
#include "Core/Models/RadioModels.h"
#include "Core/Models/SocialModels.h"

namespace ct {

class IMusicSocialProvider : public ICommentProvider {
public:
    virtual Task<void> subscribePlaylist(const QString& id, bool subscribe, CancellationToken ct) = 0;
    virtual Task<Playlist> createPlaylist(const QString& name, bool isPrivate, CancellationToken ct) = 0;
    virtual Task<void> deletePlaylist(const QString& id, CancellationToken ct) = 0;
    virtual Task<void> updatePlaylistName(const QString& id, const QString& name, CancellationToken ct) = 0;
    virtual Task<void> addSongsToPlaylist(
        const QString& playlistID, const QStringList& songIDs, CancellationToken ct) = 0;
    virtual Task<void> removeSongsFromPlaylist(
        const QString& playlistID, const QStringList& songIDs, CancellationToken ct) = 0;

    virtual Task<void> subscribeAlbum(const QString& id, bool subscribe, CancellationToken ct) = 0;
    virtual Task<void> subscribeArtist(const QString& id, bool subscribe, CancellationToken ct) = 0;
    virtual Task<void> subscribeRadio(const QString& id, bool subscribe, CancellationToken ct) = 0;

    virtual Task<QList<Playlist>> fetchSubscribedPlaylists(int limit, CancellationToken ct) = 0;
    virtual Task<QList<Album>> fetchSubscribedAlbums(int limit, CancellationToken ct) = 0;
    virtual Task<QList<Artist>> fetchSubscribedArtists(int limit, CancellationToken ct) = 0;
    virtual Task<QList<RadioStation>> fetchSubscribedRadios(int limit, CancellationToken ct) = 0;
    virtual Task<RadioStation> fetchRadioStationDetail(const QString& radioID, CancellationToken ct) = 0;

    virtual Task<QList<TopList>> fetchTopLists(CancellationToken ct) = 0;
    virtual Task<QList<Song>> fetchTopSongs(TopSongArea area, CancellationToken ct) = 0;
    virtual Task<QList<Playlist>> fetchHotPlaylists(
        const std::optional<QString>& category, TopPlaylistOrder order, int limit, int offset, CancellationToken ct) = 0;
    virtual Task<QList<PlaylistCategoryGroup>> fetchPlaylistCategories(CancellationToken ct) = 0;
    virtual Task<QStringList> fetchHotPlaylistTags(CancellationToken ct) = 0;

    virtual Task<QList<Song>> fetchPersonalFM(CancellationToken ct) = 0;
    virtual Task<QList<Playlist>> fetchDailyRecommendPlaylists(CancellationToken ct) = 0;
    virtual Task<QList<Song>> fetchNewSongs(int limit, CancellationToken ct) = 0;
    virtual Task<QList<Album>> fetchNewAlbums(int limit, CancellationToken ct) = 0;
    virtual Task<QList<Song>> fetchSimilarSongs(const QString& songID, int limit, CancellationToken ct) = 0;
    virtual Task<QList<Artist>> fetchSimilarArtists(const QString& artistID, CancellationToken ct) = 0;
    virtual Task<std::optional<Song>> dislikeDailyRecommend(const QString& songID, CancellationToken ct) = 0;

    virtual Task<QList<SearchSuggestion>> fetchSearchSuggestions(
        const QString& keyword, CancellationToken ct) = 0;
    virtual Task<QList<HotSearchTerm>> fetchHotSearchTerms(CancellationToken ct) = 0;

    virtual Task<QList<UserNotice>> fetchNotices(int limit, CancellationToken ct) = 0;
    virtual Task<QList<PrivateConversation>> fetchPrivateConversations(
        int limit, int offset, CancellationToken ct) = 0;
    virtual Task<QList<PrivateMessage>> fetchPrivateMessages(
        const QString& userID, int limit, CancellationToken ct) = 0;
    virtual Task<QList<MyComment>> fetchMyComments(int limit, CancellationToken ct) = 0;

    virtual Task<UserLevelInfo> fetchUserLevel(CancellationToken ct) = 0;
    virtual Task<QList<ListenRecord>> fetchListenRecords(bool weekly, CancellationToken ct) = 0;
    virtual Task<SignInResult> dailySignIn(CancellationToken ct) = 0;
    virtual Task<QHash<QString, int>> fetchUserCounts(CancellationToken ct) = 0;
};

} // namespace ct
