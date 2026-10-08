#pragma once

// 测试公共设施（对应 C# 版的 TestStorage / TestSupport / Stub*Provider）。
// 头文件形式以便 tests/CMakeLists.txt 只编译 tst_*.cpp。

#include "Core/Async.h"
#include "Core/Models/ArtistProfileModels.h"
#include "Core/Models/MusicProvider.h"
#include "Core/Models/MusicSocialProvider.h"
#include "Core/Search/SearchAssistStore.h"

#include <QElapsedTimer>
#include <QQueue>
#include <QStringList>
#include <QTest>

#include <functional>
#include <optional>
#include <vector>

namespace ct::tests {

// C# TestGate：手动放行的等待点。
class TestGate {
public:
    bool await_ready() const { return m_opened; }

    void await_suspend(std::coroutine_handle<> handle) { m_waiters.push_back(handle); }

    void await_resume() const {}

    void open()
    {
        if (m_opened) return;
        m_opened = true;
        auto waiters = std::move(m_waiters);
        m_waiters.clear();
        for (auto handle : waiters) detail::resumeOnLoop(handle);
    }

private:
    bool m_opened = false;
    std::vector<std::coroutine_handle<>> m_waiters;
};

inline bool until(const std::function<bool()>& condition, int timeoutMs = 5000)
{
    QElapsedTimer timer;
    timer.start();
    while (!condition()) {
        if (timer.elapsed() > timeoutMs) return false;
        QTest::qWait(10);
    }
    return true;
}

class InMemorySearchAssistPersistence : public ISearchAssistPersistence {
public:
    QStringList storedHistory;
    int saveCount = 0;

    QStringList loadHistory() override { return storedHistory; }

    void saveHistory(const QStringList& history) override
    {
        storedHistory = history;
        saveCount += 1;
    }
};

struct SearchCall {
    QString query;
    SearchType type = SearchType::Song;
    int page = 1;
};

class StubMusicProvider : public IMusicProvider {
public:
    QString identifier() const override { return QStringLiteral("stub"); }
    QString displayName() const override { return QStringLiteral("桩"); }

    int searchTotalPages = 1;
    std::function<Task<SearchResult>(QString, SearchType, int, int, CancellationToken)> searchHandler;
    std::function<Task<LyricResult>(QString, CancellationToken)> lyricsHandler;
    std::function<Task<std::optional<AccountInfo>>(CancellationToken)> accountInfoHandler;
    std::function<Task<QList<Playlist>>(CancellationToken)> userPlaylistsHandler;
    std::function<Task<QList<Song>>(CancellationToken)> likedSongsHandler;
    std::function<Task<QStringList>(CancellationToken)> likedSongIDsHandler;
    std::function<Task<void>(QString, bool, CancellationToken)> likeSongHandler;
    std::function<Task<void>(CancellationToken)> logoutHandler;

    QList<SearchCall> searchCalls;
    QStringList lyricRequests;

    static SearchResult page(const QString& query, SearchType type, int page, bool hasMore)
    {
        SearchResult result;
        result.totalCount = 100;
        result.hasMore = hasMore;
        switch (type) {
        case SearchType::Song: {
            Song song;
            song.id = QStringLiteral("%1-p%2").arg(query).arg(page);
            song.title = QStringLiteral("%1 第%2页").arg(query).arg(page);
            song.artists.append(Artist{QStringLiteral("a1"), QStringLiteral("Artist"), std::nullopt, {}});
            song.source = SongSource::Netease;
            result.songs.append(song);
            break;
        }
        case SearchType::Artist: {
            Artist artist;
            artist.id = QStringLiteral("%1-p%2").arg(query).arg(page);
            artist.name = QStringLiteral("%1 歌手%2").arg(query).arg(page);
            result.artists.append(artist);
            break;
        }
        case SearchType::Album: {
            Album album;
            album.id = QStringLiteral("%1-p%2").arg(query).arg(page);
            album.name = QStringLiteral("%1 专辑%2").arg(query).arg(page);
            result.albums.append(album);
            break;
        }
        case SearchType::Playlist: {
            Playlist playlist;
            playlist.id = QStringLiteral("%1-p%2").arg(query).arg(page);
            playlist.name = QStringLiteral("%1 歌单%2").arg(query).arg(page);
            playlist.source = SongSource::Netease;
            result.playlists.append(playlist);
            break;
        }
        }
        return result;
    }

    Task<SearchResult> search(
        const QString& query, SearchType type, int page, int limit, CancellationToken ct) override
    {
        searchCalls.append({query, type, page});
        if (searchHandler) co_return co_await searchHandler(query, type, page, limit, ct);
        co_return StubMusicProvider::page(query, type, page, page < searchTotalPages);
    }

    Task<LyricResult> fetchLyrics(const QString& songID, CancellationToken ct) override
    {
        lyricRequests.append(songID);
        if (lyricsHandler) co_return co_await lyricsHandler(songID, ct);
        throw MusicException::unknown(QStringLiteral("fetchLyrics unsupported"));
    }

    Task<QString> fetchQRCodeKey(CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchQRCodeKey unsupported"));
    }
    Task<QString> fetchQRCodeImage(const QString&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchQRCodeImage unsupported"));
    }
    Task<QRLoginStatus> checkQRCodeStatus(const QString&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("checkQRCodeStatus unsupported"));
    }
    Task<void> logout(CancellationToken ct) override
    {
        if (logoutHandler) co_await logoutHandler(ct);
    }
    Task<std::optional<AccountInfo>> fetchAccountInfo(CancellationToken ct) override
    {
        if (accountInfoHandler) co_return co_await accountInfoHandler(ct);
        co_return std::nullopt;
    }
    Task<PlaylistDetail> fetchPlaylistDetail(const QString&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchPlaylistDetail unsupported"));
    }
    Task<QList<Song>> fetchPlaylistTracks(const QString&, int, int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchPlaylistTracks unsupported"));
    }
    Task<PlaylistDetail> fetchAlbumDetail(const QString&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchAlbumDetail unsupported"));
    }
    Task<ArtistDetail> fetchArtistDetail(const QString&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchArtistDetail unsupported"));
    }
    Task<PlayableURL> fetchPlayableURL(const QString&, QualityLevel, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchPlayableURL unsupported"));
    }
    Task<QList<Playlist>> fetchUserPlaylists(CancellationToken ct) override
    {
        if (userPlaylistsHandler) co_return co_await userPlaylistsHandler(ct);
        co_return QList<Playlist>{};
    }
    Task<QList<Song>> fetchLikedSongs(CancellationToken ct) override
    {
        if (likedSongsHandler) co_return co_await likedSongsHandler(ct);
        co_return QList<Song>{};
    }
    Task<void> likeSong(const QString& id, bool like, CancellationToken ct) override
    {
        if (likeSongHandler) co_await likeSongHandler(id, like, ct);
    }
    Task<QList<Playlist>> fetchRecommendPlaylists(CancellationToken) override
    {
        co_return QList<Playlist>{};
    }
    Task<QList<Song>> fetchDailyRecommendSongs(CancellationToken) override
    {
        co_return QList<Song>{};
    }
    Task<QStringList> fetchLikedSongIDs(CancellationToken ct) override
    {
        if (likedSongIDsHandler) co_return co_await likedSongIDsHandler(ct);
        co_return QStringList{};
    }
};

class StubSocialProvider : public IMusicSocialProvider {
public:
    std::function<Task<QList<TopList>>(CancellationToken)> topListsHandler;
    std::function<Task<QList<SearchSuggestion>>(QString, CancellationToken)> searchSuggestionsHandler;
    std::function<Task<QList<HotSearchTerm>>(CancellationToken)> hotSearchTermsHandler;

    int topListCallCount = 0;
    QStringList suggestionCalls;
    int hotCallCount = 0;

    Task<QList<TopList>> fetchTopLists(CancellationToken ct) override
    {
        topListCallCount += 1;
        if (topListsHandler) co_return co_await topListsHandler(ct);
        co_return QList<TopList>{};
    }

    Task<QList<SearchSuggestion>> fetchSearchSuggestions(const QString& keyword, CancellationToken ct) override
    {
        suggestionCalls.append(keyword);
        if (searchSuggestionsHandler) co_return co_await searchSuggestionsHandler(keyword, ct);
        co_return QList<SearchSuggestion>{};
    }

    Task<QList<HotSearchTerm>> fetchHotSearchTerms(CancellationToken ct) override
    {
        hotCallCount += 1;
        if (hotSearchTermsHandler) co_return co_await hotSearchTermsHandler(ct);
        co_return QList<HotSearchTerm>{};
    }

    Task<CommentPage> fetchComments(const QString&, CommentSort, int, int,
        const std::optional<QString>&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchComments unsupported"));
    }
    Task<void> likeComment(const QString&, const QString&, bool, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("likeComment unsupported"));
    }
    Task<void> subscribePlaylist(const QString&, bool, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("subscribePlaylist unsupported"));
    }
    Task<Playlist> createPlaylist(const QString&, bool, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("createPlaylist unsupported"));
    }
    Task<void> deletePlaylist(const QString&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("deletePlaylist unsupported"));
    }
    Task<void> updatePlaylistName(const QString&, const QString&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("updatePlaylistName unsupported"));
    }
    Task<void> addSongsToPlaylist(const QString&, const QStringList&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("addSongsToPlaylist unsupported"));
    }
    Task<void> removeSongsFromPlaylist(const QString&, const QStringList&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("removeSongsFromPlaylist unsupported"));
    }
    Task<void> subscribeAlbum(const QString&, bool, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("subscribeAlbum unsupported"));
    }
    Task<void> subscribeArtist(const QString&, bool, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("subscribeArtist unsupported"));
    }
    Task<void> subscribeRadio(const QString&, bool, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("subscribeRadio unsupported"));
    }
    Task<QList<Playlist>> fetchSubscribedPlaylists(int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchSubscribedPlaylists unsupported"));
    }
    Task<QList<Album>> fetchSubscribedAlbums(int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchSubscribedAlbums unsupported"));
    }
    Task<QList<Artist>> fetchSubscribedArtists(int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchSubscribedArtists unsupported"));
    }
    Task<QList<RadioStation>> fetchSubscribedRadios(int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchSubscribedRadios unsupported"));
    }
    Task<RadioStation> fetchRadioStationDetail(const QString&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchRadioStationDetail unsupported"));
    }
    Task<QList<Song>> fetchTopSongs(TopSongArea, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchTopSongs unsupported"));
    }
    Task<QList<Playlist>> fetchHotPlaylists(
        const std::optional<QString>&, TopPlaylistOrder, int, int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchHotPlaylists unsupported"));
    }
    Task<QList<PlaylistCategoryGroup>> fetchPlaylistCategories(CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchPlaylistCategories unsupported"));
    }
    Task<QStringList> fetchHotPlaylistTags(CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchHotPlaylistTags unsupported"));
    }
    Task<QList<Song>> fetchPersonalFM(CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchPersonalFM unsupported"));
    }
    Task<QList<Playlist>> fetchDailyRecommendPlaylists(CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchDailyRecommendPlaylists unsupported"));
    }
    Task<QList<Song>> fetchNewSongs(int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchNewSongs unsupported"));
    }
    Task<QList<Album>> fetchNewAlbums(int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchNewAlbums unsupported"));
    }
    Task<QList<Song>> fetchSimilarSongs(const QString&, int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchSimilarSongs unsupported"));
    }
    Task<QList<Artist>> fetchSimilarArtists(const QString&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchSimilarArtists unsupported"));
    }
    Task<std::optional<Song>> dislikeDailyRecommend(const QString&, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("dislikeDailyRecommend unsupported"));
    }
    Task<QList<UserNotice>> fetchNotices(int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchNotices unsupported"));
    }
    Task<QList<PrivateConversation>> fetchPrivateConversations(int, int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchPrivateConversations unsupported"));
    }
    Task<QList<PrivateMessage>> fetchPrivateMessages(const QString&, int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchPrivateMessages unsupported"));
    }
    Task<QList<MyComment>> fetchMyComments(int, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchMyComments unsupported"));
    }
    Task<UserLevelInfo> fetchUserLevel(CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchUserLevel unsupported"));
    }
    Task<QList<ListenRecord>> fetchListenRecords(bool, CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchListenRecords unsupported"));
    }
    Task<SignInResult> dailySignIn(CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("dailySignIn unsupported"));
    }
    Task<QHash<QString, int>> fetchUserCounts(CancellationToken) override
    {
        throw MusicException::unknown(QStringLiteral("fetchUserCounts unsupported"));
    }
};

class StubArtistProfileProvider : public IArtistProfileProvider {
public:
    ArtistProfile profile;
    ArtistIntro intro;
    QList<Song> hotSongs;
    QList<Artist> similarArtists;

    bool failProfile = false;
    bool failSongPage = false;
    bool failNextSongPage = false;
    bool failHighlights = false;

    std::shared_ptr<TestGate> songGate;
    std::shared_ptr<TestGate> albumGate;

    QList<int> requestedSongOffsets;
    QList<int> requestedAlbumOffsets;
    QList<int> requestedMVOffsets;

    QQueue<ArtistSongPage> songPages;
    QQueue<ArtistAlbumPage> albumPages;
    QQueue<ArtistMVPage> mvPages;

    StubArtistProfileProvider()
    {
        profile.artist.id = QStringLiteral("1");
        profile.artist.name = QStringLiteral("测试歌手");
        profile.briefDescription = QStringLiteral("简介");
        profile.albumCount = 2;
        profile.songCount = 10;
        profile.mvCount = 1;
    }

    void enqueueSongPage(const ArtistSongPage& page) { songPages.enqueue(page); }
    void enqueueAlbumPage(const ArtistAlbumPage& page) { albumPages.enqueue(page); }
    void enqueueMVPage(const ArtistMVPage& page) { mvPages.enqueue(page); }

    Task<ArtistProfile> fetchArtistProfile(const QString&, CancellationToken) override
    {
        co_await ct::Delay(0);
        if (failProfile) throw MusicException::notLoggedIn();
        co_return profile;
    }

    Task<QList<Song>> fetchHotArtistSongs(const QString&, CancellationToken) override
    {
        co_await ct::Delay(0);
        if (failHighlights) throw MusicException::invalidResponse();
        co_return hotSongs;
    }

    Task<ArtistSongPage> fetchArtistSongs(
        const QString&, int offset, int, const QString&, CancellationToken) override
    {
        requestedSongOffsets.append(offset);
        if (songGate) co_await *songGate;
        if (failSongPage || failNextSongPage) {
            failNextSongPage = false;
            throw MusicException::apiError(524, QStringLiteral("风控"));
        }
        co_return songPages.isEmpty() ? ArtistSongPage{} : songPages.dequeue();
    }

    Task<ArtistAlbumPage> fetchArtistAlbums(const QString&, int offset, int, CancellationToken) override
    {
        requestedAlbumOffsets.append(offset);
        if (albumGate) co_await *albumGate;
        co_return albumPages.isEmpty() ? ArtistAlbumPage{} : albumPages.dequeue();
    }

    Task<ArtistMVPage> fetchArtistMVs(const QString&, int offset, int, CancellationToken) override
    {
        requestedMVOffsets.append(offset);
        co_await ct::Delay(0);
        co_return mvPages.isEmpty() ? ArtistMVPage{} : mvPages.dequeue();
    }

    Task<ArtistIntro> fetchArtistIntro(const QString&, CancellationToken) override
    {
        co_await ct::Delay(0);
        co_return intro;
    }

    Task<QList<Artist>> fetchSimilarArtists(const QString&, CancellationToken) override
    {
        co_await ct::Delay(0);
        if (failHighlights) throw MusicException::invalidResponse();
        co_return similarArtists;
    }
};

} // namespace ct::tests
