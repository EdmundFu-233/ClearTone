#pragma once

#include "Core/Models/MusicProvider.h"

#include <QList>
#include <QSet>
#include <QString>
#include <QStringList>

#include <mutex>
#include <optional>

namespace ct {

class LocalProvider final : public IMusicProvider {
public:
    static LocalProvider& shared();

    LocalProvider();

    QString identifier() const override;
    QString displayName() const override;

    Task<QList<Song>> importFiles(const QStringList& paths,
        CancellationToken ct = CancellationToken::none());
    Task<QList<Song>> scanDirectory(const QString& directory,
        CancellationToken ct = CancellationToken::none());
    QList<Song> allSongs() const;
    Task<QList<Song>> restoreLibrary(CancellationToken ct = CancellationToken::none());

    Task<QString> fetchQRCodeKey(CancellationToken ct = CancellationToken::none()) override;
    Task<QString> fetchQRCodeImage(const QString& key,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QRLoginStatus> checkQRCodeStatus(const QString& key,
        CancellationToken ct = CancellationToken::none()) override;
    Task<void> logout(CancellationToken ct = CancellationToken::none()) override;
    Task<std::optional<AccountInfo>> fetchAccountInfo(
        CancellationToken ct = CancellationToken::none()) override;

    Task<SearchResult> search(const QString& query, SearchType type, int page, int limit,
        CancellationToken ct = CancellationToken::none()) override;
    Task<PlaylistDetail> fetchPlaylistDetail(const QString& id,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Song>> fetchPlaylistTracks(const QString& id, int page, int limit,
        CancellationToken ct = CancellationToken::none()) override;
    Task<PlaylistDetail> fetchAlbumDetail(const QString& id,
        CancellationToken ct = CancellationToken::none()) override;
    Task<ArtistDetail> fetchArtistDetail(const QString& id,
        CancellationToken ct = CancellationToken::none()) override;
    Task<PlayableURL> fetchPlayableURL(const QString& songID, QualityLevel quality,
        CancellationToken ct = CancellationToken::none()) override;
    Task<LyricResult> fetchLyrics(const QString& songID,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Playlist>> fetchUserPlaylists(CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Song>> fetchLikedSongs(CancellationToken ct = CancellationToken::none()) override;
    Task<void> likeSong(const QString& id, bool like,
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Playlist>> fetchRecommendPlaylists(
        CancellationToken ct = CancellationToken::none()) override;
    Task<QList<Song>> fetchDailyRecommendSongs(
        CancellationToken ct = CancellationToken::none()) override;
    Task<QStringList> fetchLikedSongIDs(CancellationToken ct = CancellationToken::none()) override;

private:
    QSet<QString> importedPathSet() const;
    void persistLibrary() const;

    mutable std::mutex m_gate;
    QList<Song> m_importedSongs;
};

} // namespace ct
