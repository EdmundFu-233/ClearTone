#pragma once

#include "Core/Async.h"
#include "Core/Models/MusicModels.h"

#include <QDateTime>
#include <QList>
#include <QString>

#include <optional>

namespace ct {

struct ArtistProfile {
    Artist artist;
    std::optional<QString> briefDescription;
    int albumCount = 0;
    int songCount = 0;
    int mvCount = 0;
    int videoCount = 0;
    QStringList identifyTags;
    std::optional<bool> isFollowed;
};

struct ArtistIntroSection {
    QString id;
    QString title;
    QString body;

    bool operator==(const ArtistIntroSection&) const = default;
};

struct ArtistIntro {
    std::optional<QString> briefDescription;
    QList<ArtistIntroSection> sections;

    bool isEmpty() const { return sections.isEmpty() && !briefDescription.has_value(); }
};

struct ArtistSongPage {
    QList<Song> songs;
    int total = 0;
    bool hasMore = false;

    static ArtistSongPage empty() { return {}; }
};

struct ArtistAlbumPage {
    QList<Album> albums;
    std::optional<bool> isFollowed;
    bool hasMore = false;

    static ArtistAlbumPage empty() { return {}; }
};

struct ArtistMV {
    QString id;
    QString name;
    std::optional<QString> artistName;
    std::optional<QString> coverURL;
    double duration = 0;
    int playCount = 0;
    std::optional<QDateTime> publishDate;

    bool operator==(const ArtistMV&) const = default;
};

struct ArtistMVPage {
    QList<ArtistMV> mvs;
    bool hasMore = false;

    static ArtistMVPage empty() { return {}; }
};

class IArtistProfileProvider {
public:
    virtual ~IArtistProfileProvider() = default;

    virtual Task<ArtistProfile> fetchArtistProfile(const QString& id, CancellationToken ct) = 0;
    virtual Task<QList<Song>> fetchHotArtistSongs(const QString& id, CancellationToken ct) = 0;
    virtual Task<ArtistSongPage> fetchArtistSongs(
        const QString& id, int offset, int limit, const QString& order, CancellationToken ct) = 0;
    virtual Task<ArtistAlbumPage> fetchArtistAlbums(
        const QString& id, int offset, int limit, CancellationToken ct) = 0;
    virtual Task<ArtistMVPage> fetchArtistMVs(
        const QString& id, int offset, int limit, CancellationToken ct) = 0;
    virtual Task<ArtistIntro> fetchArtistIntro(const QString& id, CancellationToken ct) = 0;
    virtual Task<QList<Artist>> fetchSimilarArtists(const QString& artistID, CancellationToken ct) = 0;
};

} // namespace ct
