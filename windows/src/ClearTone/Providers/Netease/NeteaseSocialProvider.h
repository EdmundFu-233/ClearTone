#pragma once

#include "Core/Models/MusicSocialProvider.h"

#include <QDateTime>
#include <QHash>
#include <QJsonValue>
#include <QString>
#include <QStringList>

#include <optional>

namespace ct {

class NeteaseSocialProvider final : public IMusicSocialProvider {
public:
    static NeteaseSocialProvider& shared();

    Task<void> subscribePlaylist(const QString& id, bool subscribe,
        CancellationToken ct = CancellationToken::none()) override;
    Task<Playlist> createPlaylist(const QString& name, bool isPrivate,
        CancellationToken ct = CancellationToken::none()) override;
    Task<void> deletePlaylist(const QString& id,
        CancellationToken ct = CancellationToken::none()) override;
    Task<void> updatePlaylistName(const QString& id, const QString& name,
        CancellationToken ct = CancellationToken::none()) override;
    Task<void> addSongsToPlaylist(const QString& playlistID, const QStringList& songIDs,
        CancellationToken ct = CancellationToken::none()) override;
    Task<void> removeSongsFromPlaylist(const QString& playlistID, const QStringList& songIDs,
        CancellationToken ct = CancellationToken::none()) override;

    Task<void> subscribeAlbum(const QString& id, bool subscribe,
        CancellationToken ct = CancellationToken::none()) override;
    Task<void> subscribeArtist(const QString& id, bool subscribe,
        CancellationToken ct = CancellationToken::none()) override;
    Task<void> subscribeRadio(const QString& id, bool subscribe,
        CancellationToken ct = CancellationToken::none()) override;

    Task<QList<Playlist>> fetchSubscribedPlaylists(
        int limit = 50, CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Album>> fetchSubscribedAlbums(
        int limit = 50, CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Artist>> fetchSubscribedArtists(
        int limit = 50, CancellationToken ct = CancellationToken::none()) override;
    Task<QList<RadioStation>> fetchSubscribedRadios(
        int limit = 30, CancellationToken ct = CancellationToken::none()) override;
    Task<RadioStation> fetchRadioStationDetail(const QString& radioID,
        CancellationToken ct = CancellationToken::none()) override;

    Task<QList<TopList>> fetchTopLists(CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Song>> fetchTopSongs(
        TopSongArea area, CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Playlist>> fetchHotPlaylists(const std::optional<QString>& category,
        TopPlaylistOrder order, int limit, int offset,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<PlaylistCategoryGroup>> fetchPlaylistCategories(
        CancellationToken ct = CancellationToken::none()) override;
    Task<QStringList> fetchHotPlaylistTags(
        CancellationToken ct = CancellationToken::none()) override;

    Task<QList<Song>> fetchPersonalFM(CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Playlist>> fetchDailyRecommendPlaylists(
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Song>> fetchNewSongs(
        int limit = 30, CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Album>> fetchNewAlbums(
        int limit = 30, CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Song>> fetchSimilarSongs(const QString& songID, int limit = 30,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Artist>> fetchSimilarArtists(const QString& artistID,
        CancellationToken ct = CancellationToken::none()) override;
    Task<std::optional<Song>> dislikeDailyRecommend(const QString& songID,
        CancellationToken ct = CancellationToken::none()) override;

    Task<QList<SearchSuggestion>> fetchSearchSuggestions(const QString& keyword,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<HotSearchTerm>> fetchHotSearchTerms(
        CancellationToken ct = CancellationToken::none()) override;

    Task<CommentPage> fetchComments(const QString& songID, CommentSort sort, int page, int pageSize,
        const std::optional<QString>& cursor,
        CancellationToken ct = CancellationToken::none()) override;
    Task<void> likeComment(const QString& songID, const QString& commentID, bool like,
        CancellationToken ct = CancellationToken::none()) override;

    Task<QList<UserNotice>> fetchNotices(
        int limit = 30, CancellationToken ct = CancellationToken::none()) override;
    Task<QList<PrivateConversation>> fetchPrivateConversations(int limit = 30, int offset = 0,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<PrivateMessage>> fetchPrivateMessages(const QString& userID, int limit = 30,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<MyComment>> fetchMyComments(
        int limit = 30, CancellationToken ct = CancellationToken::none()) override;

    Task<UserLevelInfo> fetchUserLevel(CancellationToken ct = CancellationToken::none()) override;
    Task<QList<ListenRecord>> fetchListenRecords(
        bool weekly, CancellationToken ct = CancellationToken::none()) override;
    Task<SignInResult> dailySignIn(CancellationToken ct = CancellationToken::none()) override;
    Task<QHash<QString, int>> fetchUserCounts(
        CancellationToken ct = CancellationToken::none()) override;

    static QHash<QString, QString> commentQuery(const QString& songID, CommentSort sort, int page,
        int pageSize, const std::optional<QString>& cursor);
    static CommentPage mapCommentPage(
        const QJsonValue& json, const std::optional<QString>& myID);
    static QHash<QString, QString> commentLikeQuery(
        const QString& songID, const QString& commentID, bool like);
    static QJsonValue peerProfile(const QJsonValue& item, const std::optional<QString>& myID);
    static QDateTime dateFromMilliseconds(const QJsonValue& value);

private:
    static QString requireLoginCookie();
    static QString requireUserID();
    static void requireWriteSucceeded(const QJsonValue& json, const QString& action);
    Task<void> manipulatePlaylistTracks(const QString& op, const QString& playlistID,
        const QStringList& songIDs, CancellationToken ct);
    Task<void> toggleSub(const QString& route, const QString& id, bool subscribe,
        const QString& action, const QString& queryKey, CancellationToken ct);
    static QJsonValue normalizeRadioStationJson(const QJsonValue& dict, bool markSubscribed);
    static std::optional<QString> suggestionSubtitle(
        const QJsonValue& dict, SearchSuggestion::Kind kind);
    static std::optional<QString> hotSearchIconLabel(int type);
    static std::optional<QString> decodeNestedLastMessage(const std::optional<QString>& raw);
    static std::optional<QString> anyValue(const QJsonValue& value);
    static std::optional<int> intValue(const QJsonValue& value);
    static int categoryGroupOrder(const QString& name);
};

} // namespace ct
