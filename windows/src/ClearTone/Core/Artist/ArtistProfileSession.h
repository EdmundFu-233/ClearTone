#pragma once

#include "Core/Async.h"
#include "Core/Models/ArtistProfileModels.h"
#include "Core/Models/MusicModels.h"

#include <functional>
#include <optional>

namespace ct {

class ArtistProfileSession {
public:
    explicit ArtistProfileSession(QString artistID, IArtistProfileProvider* provider = nullptr);

    std::function<void()> onChanged;

    const QString& artistID() const { return m_artistID; }

    const std::optional<ArtistProfile>& profile() const { return m_profile; }
    bool isLoadingProfile() const { return m_isLoadingProfile; }
    const std::optional<QString>& profileError() const { return m_profileError; }

    const std::optional<ArtistIntro>& intro() const { return m_intro; }
    bool isLoadingIntro() const { return m_isLoadingIntro; }
    const std::optional<QString>& introError() const { return m_introError; }

    const QList<Song>& hotSongs() const { return m_hotSongs; }
    bool isLoadingHighlights() const { return m_isLoadingHighlights; }

    const QList<Song>& songs() const { return m_songs; }
    int songsTotal() const { return m_songsTotal; }
    bool isLoadingSongs() const { return m_isLoadingSongs; }
    bool isLoadingMoreSongs() const { return m_isLoadingMoreSongs; }
    const std::optional<QString>& songsError() const { return m_songsError; }
    bool canLoadMoreSongs() const
    {
        return m_songsHasMore && !m_songs.isEmpty() && !m_isLoadingMoreSongs;
    }

    const QList<Album>& albums() const { return m_albums; }
    bool isLoadingAlbums() const { return m_isLoadingAlbums; }
    bool isLoadingMoreAlbums() const { return m_isLoadingMoreAlbums; }
    const std::optional<QString>& albumsError() const { return m_albumsError; }
    const std::optional<bool>& isFollowed() const { return m_isFollowed; }
    bool canLoadMoreAlbums() const
    {
        return m_albumsHasMore && !m_albums.isEmpty() && !m_isLoadingMoreAlbums;
    }

    const QList<ArtistMV>& mvs() const { return m_mvs; }
    bool isLoadingMVs() const { return m_isLoadingMVs; }
    bool isLoadingMoreMVs() const { return m_isLoadingMoreMVs; }
    const std::optional<QString>& mvsError() const { return m_mvsError; }
    bool canLoadMoreMVs() const
    {
        return m_mvsHasMore && !m_mvs.isEmpty() && !m_isLoadingMoreMVs;
    }

    const QList<Artist>& similarArtists() const { return m_similarArtists; }

    void switchTo(const QString& artistID);
    void reloadForDataContext();
    void reset();

    Task<void> loadProfileAsync(CancellationToken ct = CancellationToken::none());
    Task<void> loadHighlightsAsync(CancellationToken ct = CancellationToken::none());
    Task<void> loadIntroAsync(CancellationToken ct = CancellationToken::none());
    Task<void> loadSongsAsync(CancellationToken ct = CancellationToken::none());
    Task<void> loadMoreSongsAsync(CancellationToken ct = CancellationToken::none());
    Task<void> loadAlbumsAsync(CancellationToken ct = CancellationToken::none());
    Task<void> loadMoreAlbumsAsync(CancellationToken ct = CancellationToken::none());
    Task<void> loadMVsAsync(CancellationToken ct = CancellationToken::none());
    Task<void> loadMoreMVsAsync(CancellationToken ct = CancellationToken::none());
    void setFollowed(bool value);

private:
    static constexpr int songPageSize = 50;
    static constexpr int albumPageSize = 30;
    static constexpr int mvPageSize = 30;

    void resetLocked();
    void notifyChanged();

    QString m_artistID;
    int m_generation = 0;
    IArtistProfileProvider* m_provider = nullptr;

    std::optional<ArtistProfile> m_profile;
    bool m_isLoadingProfile = false;
    std::optional<QString> m_profileError;

    std::optional<ArtistIntro> m_intro;
    bool m_isLoadingIntro = false;
    std::optional<QString> m_introError;

    QList<Song> m_hotSongs;
    bool m_isLoadingHighlights = false;

    QList<Song> m_songs;
    int m_songsTotal = 0;
    bool m_isLoadingSongs = false;
    bool m_isLoadingMoreSongs = false;
    std::optional<QString> m_songsError;
    bool m_songsHasMore = true;

    QList<Album> m_albums;
    bool m_isLoadingAlbums = false;
    bool m_isLoadingMoreAlbums = false;
    std::optional<QString> m_albumsError;
    bool m_albumsHasMore = true;
    std::optional<bool> m_isFollowed;

    QList<ArtistMV> m_mvs;
    bool m_isLoadingMVs = false;
    bool m_isLoadingMoreMVs = false;
    std::optional<QString> m_mvsError;
    bool m_mvsHasMore = true;

    QList<Artist> m_similarArtists;
};

} // namespace ct
