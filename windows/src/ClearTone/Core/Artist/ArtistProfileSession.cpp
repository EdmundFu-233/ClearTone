#include "Core/Artist/ArtistProfileSession.h"

#include <QSet>

#include <utility>

namespace ct {

namespace {

QString unknownUserMessage(const std::exception& error)
{
    return MusicException::unknown(QString::fromUtf8(error.what())).userFacingMessage();
}

} // namespace

ArtistProfileSession::ArtistProfileSession(QString artistID, IArtistProfileProvider* provider)
    : m_artistID(std::move(artistID)), m_provider(provider)
{
}

void ArtistProfileSession::switchTo(const QString& artistID)
{
    if (artistID == m_artistID) return;
    resetLocked();
    m_artistID = artistID;
    notifyChanged();
}

void ArtistProfileSession::reloadForDataContext()
{
    resetLocked();
}

void ArtistProfileSession::reset()
{
    resetLocked();
}

void ArtistProfileSession::resetLocked()
{
    m_generation++;
    m_profile.reset();
    m_isLoadingProfile = false;
    m_profileError.reset();
    m_intro.reset();
    m_isLoadingIntro = false;
    m_introError.reset();
    m_hotSongs.clear();
    m_isLoadingHighlights = false;
    m_songs.clear();
    m_songsTotal = 0;
    m_isLoadingSongs = false;
    m_isLoadingMoreSongs = false;
    m_songsError.reset();
    m_songsHasMore = true;
    m_albums.clear();
    m_isLoadingAlbums = false;
    m_isLoadingMoreAlbums = false;
    m_albumsError.reset();
    m_albumsHasMore = true;
    m_isFollowed.reset();
    m_mvs.clear();
    m_isLoadingMVs = false;
    m_isLoadingMoreMVs = false;
    m_mvsError.reset();
    m_mvsHasMore = true;
    m_similarArtists.clear();
    notifyChanged();
}

Task<void> ArtistProfileSession::loadProfileAsync(CancellationToken ct)
{
    const int token = m_generation;
    const QString id = m_artistID;
    m_isLoadingProfile = true;
    m_profileError.reset();
    notifyChanged();
    try {
        if (m_provider != nullptr) {
            ArtistProfile loaded = co_await m_provider->fetchArtistProfile(id, ct);
            if (token == m_generation && !ct.isCancellationRequested()) {
                m_isFollowed = loaded.isFollowed;
                m_profile = std::move(loaded);
                notifyChanged();
            }
        }
    } catch (const MusicException& error) {
        if (!error.isCancelled() && token == m_generation && !ct.isCancellationRequested()) {
            m_profileError = error.userFacingMessage();
            notifyChanged();
        }
    } catch (const std::exception& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_profileError = unknownUserMessage(error);
            notifyChanged();
        }
    }
    if (token == m_generation) {
        m_isLoadingProfile = false;
        notifyChanged();
    }
}

Task<void> ArtistProfileSession::loadHighlightsAsync(CancellationToken ct)
{
    if (m_isLoadingHighlights) co_return;
    m_isLoadingHighlights = true;
    notifyChanged();
    const int token = m_generation;
    const QString id = m_artistID;
    if (m_provider != nullptr) {
        std::optional<QList<Song>> hot;
        try {
            hot = co_await m_provider->fetchHotArtistSongs(id, ct);
        } catch (const MusicException&) {
        } catch (const std::exception&) {
        }
        if (token == m_generation && !ct.isCancellationRequested() && hot.has_value()) {
            m_hotSongs = std::move(*hot);
            notifyChanged();
        }
        std::optional<QList<Artist>> similar;
        try {
            similar = co_await m_provider->fetchSimilarArtists(id, ct);
        } catch (const MusicException&) {
        } catch (const std::exception&) {
        }
        if (token == m_generation && !ct.isCancellationRequested() && similar.has_value()) {
            QList<Artist> filtered;
            for (const Artist& artist : *similar) {
                if (artist.id != id) filtered.append(artist);
                if (filtered.size() >= 12) break;
            }
            m_similarArtists = std::move(filtered);
            notifyChanged();
        }
    }
    m_isLoadingHighlights = false;
    notifyChanged();
}

Task<void> ArtistProfileSession::loadIntroAsync(CancellationToken ct)
{
    const int token = m_generation;
    const QString id = m_artistID;
    m_isLoadingIntro = true;
    m_introError.reset();
    notifyChanged();
    try {
        if (m_provider != nullptr) {
            ArtistIntro loaded = co_await m_provider->fetchArtistIntro(id, ct);
            if (token == m_generation && !ct.isCancellationRequested()) {
                m_intro = std::move(loaded);
                notifyChanged();
            }
        }
    } catch (const MusicException& error) {
        if (!error.isCancelled() && token == m_generation && !ct.isCancellationRequested()) {
            m_introError = error.userFacingMessage();
            notifyChanged();
        }
    } catch (const std::exception& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_introError = unknownUserMessage(error);
            notifyChanged();
        }
    }
    if (token == m_generation) {
        m_isLoadingIntro = false;
        notifyChanged();
    }
}

Task<void> ArtistProfileSession::loadSongsAsync(CancellationToken ct)
{
    if (m_isLoadingSongs) co_return;
    m_isLoadingSongs = true;
    m_songsError.reset();
    const int token = m_generation;
    const QString id = m_artistID;
    notifyChanged();
    try {
        if (m_provider != nullptr) {
            ArtistSongPage page
                = co_await m_provider->fetchArtistSongs(id, 0, songPageSize, QStringLiteral("hot"), ct);
            if (token == m_generation && !ct.isCancellationRequested()) {
                m_songs = std::move(page.songs);
                m_songsTotal = page.total;
                m_songsHasMore = page.hasMore;
                notifyChanged();
            }
        }
    } catch (const MusicException& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_songsError = error.userFacingMessage();
            notifyChanged();
        }
    } catch (const std::exception& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_songsError = unknownUserMessage(error);
            notifyChanged();
        }
    }
    if (token == m_generation) {
        m_isLoadingSongs = false;
        notifyChanged();
    }
}

Task<void> ArtistProfileSession::loadMoreSongsAsync(CancellationToken ct)
{
    if (!m_songsHasMore || m_songs.isEmpty() || m_isLoadingMoreSongs) co_return;
    m_isLoadingMoreSongs = true;
    m_songsError.reset();
    const int token = m_generation;
    const QString id = m_artistID;
    const int offset = m_songs.size();
    notifyChanged();
    try {
        if (m_provider != nullptr) {
            ArtistSongPage page = co_await m_provider->fetchArtistSongs(
                id, offset, songPageSize, QStringLiteral("hot"), ct);
            if (token == m_generation && !ct.isCancellationRequested()) {
                QSet<QString> existing;
                for (const Song& song : m_songs) existing.insert(song.id);
                for (const Song& song : page.songs) {
                    if (!existing.contains(song.id)) {
                        existing.insert(song.id);
                        m_songs.append(song);
                    }
                }
                m_songsTotal = qMax(m_songsTotal, page.total);
                m_songsHasMore = page.hasMore;
                notifyChanged();
            }
        }
    } catch (const MusicException& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_songsError = error.userFacingMessage();
            notifyChanged();
        }
    } catch (const std::exception& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_songsError = unknownUserMessage(error);
            notifyChanged();
        }
    }
    if (token == m_generation) {
        m_isLoadingMoreSongs = false;
        notifyChanged();
    }
}

Task<void> ArtistProfileSession::loadAlbumsAsync(CancellationToken ct)
{
    if (m_isLoadingAlbums) co_return;
    m_isLoadingAlbums = true;
    m_albumsError.reset();
    const int token = m_generation;
    const QString id = m_artistID;
    notifyChanged();
    try {
        if (m_provider != nullptr) {
            ArtistAlbumPage page
                = co_await m_provider->fetchArtistAlbums(id, 0, albumPageSize, ct);
            if (token == m_generation && !ct.isCancellationRequested()) {
                m_albums = std::move(page.albums);
                m_albumsHasMore = page.hasMore;
                if (page.isFollowed.has_value()) m_isFollowed = page.isFollowed;
                notifyChanged();
            }
        }
    } catch (const MusicException& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_albumsError = error.userFacingMessage();
            notifyChanged();
        }
    } catch (const std::exception& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_albumsError = unknownUserMessage(error);
            notifyChanged();
        }
    }
    if (token == m_generation) {
        m_isLoadingAlbums = false;
        notifyChanged();
    }
}

Task<void> ArtistProfileSession::loadMoreAlbumsAsync(CancellationToken ct)
{
    if (!m_albumsHasMore || m_albums.isEmpty() || m_isLoadingMoreAlbums) co_return;
    m_isLoadingMoreAlbums = true;
    m_albumsError.reset();
    const int token = m_generation;
    const QString id = m_artistID;
    const int offset = m_albums.size();
    notifyChanged();
    try {
        if (m_provider != nullptr) {
            ArtistAlbumPage page = co_await m_provider->fetchArtistAlbums(id, offset, albumPageSize, ct);
            if (token == m_generation && !ct.isCancellationRequested()) {
                QSet<QString> existing;
                for (const Album& album : m_albums) existing.insert(album.id);
                for (const Album& album : page.albums) {
                    if (!existing.contains(album.id)) {
                        existing.insert(album.id);
                        m_albums.append(album);
                    }
                }
                m_albumsHasMore = page.hasMore;
                notifyChanged();
            }
        }
    } catch (const MusicException& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_albumsError = error.userFacingMessage();
            notifyChanged();
        }
    } catch (const std::exception& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_albumsError = unknownUserMessage(error);
            notifyChanged();
        }
    }
    if (token == m_generation) {
        m_isLoadingMoreAlbums = false;
        notifyChanged();
    }
}

Task<void> ArtistProfileSession::loadMVsAsync(CancellationToken ct)
{
    if (m_isLoadingMVs) co_return;
    m_isLoadingMVs = true;
    m_mvsError.reset();
    const int token = m_generation;
    const QString id = m_artistID;
    notifyChanged();
    try {
        if (m_provider != nullptr) {
            ArtistMVPage page = co_await m_provider->fetchArtistMVs(id, 0, mvPageSize, ct);
            if (token == m_generation && !ct.isCancellationRequested()) {
                m_mvs = std::move(page.mvs);
                m_mvsHasMore = page.hasMore;
                notifyChanged();
            }
        }
    } catch (const MusicException& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_mvsError = error.userFacingMessage();
            notifyChanged();
        }
    } catch (const std::exception& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_mvsError = unknownUserMessage(error);
            notifyChanged();
        }
    }
    if (token == m_generation) {
        m_isLoadingMVs = false;
        notifyChanged();
    }
}

Task<void> ArtistProfileSession::loadMoreMVsAsync(CancellationToken ct)
{
    if (!m_mvsHasMore || m_mvs.isEmpty() || m_isLoadingMoreMVs) co_return;
    m_isLoadingMoreMVs = true;
    m_mvsError.reset();
    const int token = m_generation;
    const QString id = m_artistID;
    const int offset = m_mvs.size();
    notifyChanged();
    try {
        if (m_provider != nullptr) {
            ArtistMVPage page = co_await m_provider->fetchArtistMVs(id, offset, mvPageSize, ct);
            if (token == m_generation && !ct.isCancellationRequested()) {
                QSet<QString> existing;
                for (const ArtistMV& mv : m_mvs) existing.insert(mv.id);
                for (const ArtistMV& mv : page.mvs) {
                    if (!existing.contains(mv.id)) {
                        existing.insert(mv.id);
                        m_mvs.append(mv);
                    }
                }
                m_mvsHasMore = page.hasMore;
                notifyChanged();
            }
        }
    } catch (const MusicException& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_mvsError = error.userFacingMessage();
            notifyChanged();
        }
    } catch (const std::exception& error) {
        if (token == m_generation && !ct.isCancellationRequested()) {
            m_mvsError = unknownUserMessage(error);
            notifyChanged();
        }
    }
    if (token == m_generation) {
        m_isLoadingMoreMVs = false;
        notifyChanged();
    }
}

void ArtistProfileSession::setFollowed(bool value)
{
    m_isFollowed = value;
    notifyChanged();
}

void ArtistProfileSession::notifyChanged()
{
    if (onChanged) onChanged();
}

} // namespace ct
