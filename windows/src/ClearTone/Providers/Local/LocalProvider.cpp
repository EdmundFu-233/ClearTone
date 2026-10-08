#include "Providers/Local/LocalProvider.h"

#include "Core/Logging/CTLog.h"
#include "Core/Persistence/PersistenceStore.h"
#include "Core/Persistence/StoragePaths.h"

#include <QCoreApplication>
#include <QCryptographicHash>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QUrl>

#include <cmath>

#ifdef CT_HAVE_QT_MULTIMEDIA
#include <QGuiApplication>
#include <QMediaMetaData>
#include <QMediaPlayer>
#include <QTimer>
#endif

namespace ct {

namespace {

const QStringList& supportedExtensions()
{
    static const QStringList extensions{
        QStringLiteral("mp3"),
        QStringLiteral("m4a"),
        QStringLiteral("aac"),
        QStringLiteral("wav"),
        QStringLiteral("flac"),
        QStringLiteral("aiff"),
        QStringLiteral("alac"),
    };
    return extensions;
}

bool isSupportedPath(const QString& path)
{
    return supportedExtensions().contains(QFileInfo(path).suffix().toLower());
}

std::optional<QString> normalizePath(const QString& path)
{
    if (path.trimmed().isEmpty()) return std::nullopt;
    const QString absolute = QFileInfo(path).absoluteFilePath();
    if (absolute.isEmpty()) return std::nullopt;
    return QDir::cleanPath(absolute);
}

QString dedupKey(const QString& path)
{
#ifdef Q_OS_WIN
    return path.toLower();
#else
    return path;
#endif
}

QString stableID(const QString& fullPath)
{
    return QString::fromLatin1(
        QCryptographicHash::hash(fullPath.toUtf8(), QCryptographicHash::Sha256).toHex());
}

QString coverDirectory()
{
    return QDir(StoragePaths::root()).filePath(QStringLiteral("LocalCovers"));
}

struct ParsedMetadata {
    QString title;
    QString artist;
    QString album;
    double duration = 0;
    QImage cover;
    bool valid = false;
};

std::optional<QString> extractCover(const QImage& cover, const QString& fileID)
{
    if (cover.isNull()) return std::nullopt;

    const QString directory = coverDirectory();
    QDir().mkpath(directory);
    const QString coverPath = QDir(directory).filePath(fileID + QStringLiteral(".jpg"));
    if (!QFile::exists(coverPath) && !cover.save(coverPath, "JPG", 90)) {
        CTLog::general().warn(QStringLiteral("写入本地封面失败 [%1]").arg(fileID));
        return std::nullopt;
    }
    return QUrl::fromLocalFile(coverPath).toString();
}

Song buildSong(const QString& path, const ParsedMetadata& parsed)
{
    const QString fileID = stableID(path);

    QString title = parsed.title.trimmed();
    if (title.isEmpty()) title = QFileInfo(path).completeBaseName();
    QString artistName = parsed.artist.trimmed();
    if (artistName.isEmpty()) artistName = QStringLiteral("未知艺术家");
    QString albumName = parsed.album.trimmed();
    if (albumName.isEmpty()) albumName = QStringLiteral("未知专辑");

    double duration = parsed.duration;
    if (!std::isfinite(duration) || duration < 0) duration = 0;

    const std::optional<QString> coverURL = extractCover(parsed.cover, fileID);

    Song song;
    song.id = QStringLiteral("local-") + fileID;
    song.title = title;
    Artist artist;
    artist.id = QStringLiteral("local-artist-") + artistName;
    artist.name = artistName;
    song.artists = QList<Artist>{artist};
    Album album;
    album.id = QStringLiteral("local-album-") + albumName;
    album.name = albumName;
    album.coverURL = coverURL;
    song.album = album;
    song.duration = duration;
    song.coverURL = coverURL;
    song.isPlayable = true;
    song.source = SongSource::Local;
    song.localFileURL = path;
    return song;
}

void reportMissingMultimedia()
{
    static bool reported = false;
    if (reported) return;
    reported = true;
    CTLog::general().warn(QStringLiteral("Qt Multimedia 不可用，本地音频元数据将仅从文件名推断"));
}

#ifdef CT_HAVE_QT_MULTIMEDIA

ParsedMetadata collectMetadata(QMediaPlayer* player)
{
    ParsedMetadata parsed;
    parsed.valid = true;
    const QMediaMetaData metadata = player->metaData();

    parsed.title = metadata.value(QMediaMetaData::Title).toString().trimmed();

    const QStringList leadPerformers = metadata.value(QMediaMetaData::LeadPerformer).toStringList();
    for (const QString& name : leadPerformers) {
        if (!name.trimmed().isEmpty()) {
            parsed.artist = name.trimmed();
            break;
        }
    }
    if (parsed.artist.isEmpty()) {
        parsed.artist = metadata.value(QMediaMetaData::AlbumArtist).toString().trimmed();
    }
    if (parsed.artist.isEmpty()) {
        parsed.artist = metadata.value(QMediaMetaData::Author).toString().trimmed();
    }

    parsed.album = metadata.value(QMediaMetaData::AlbumTitle).toString().trimmed();

    qint64 durationMs = metadata.value(QMediaMetaData::Duration).toLongLong();
    if (durationMs <= 0) durationMs = player->duration();
    if (durationMs > 0) parsed.duration = durationMs / 1000.0;

    parsed.cover = metadata.value(QMediaMetaData::CoverArtImage).value<QImage>();
    return parsed;
}

struct PlayerReadState {
    bool finished = false;
    QMediaPlayer* player = nullptr;
    QTimer* timer = nullptr;
    CancellationToken ct;
    int cancelId = 0;
    Callback<ParsedMetadata> callback;
};

Awaitable<ParsedMetadata> readPlayerMetadata(const QString& path, CancellationToken ct)
{
    return Awaitable<ParsedMetadata>{[path, ct](Callback<ParsedMetadata> callback) {
        auto state = std::make_shared<PlayerReadState>();
        state->ct = ct;
        state->callback = std::move(callback);

        QMediaPlayer* player = new QMediaPlayer();
        QTimer* timer = new QTimer();
        timer->setSingleShot(true);
        state->player = player;
        state->timer = timer;

        std::function<void(bool)> finish = [state](bool readSucceeded) {
            if (state->finished) return;
            state->finished = true;
            if (state->ct.canBeCancelled()) state->ct.unregisterCallback(state->cancelId);
            state->timer->stop();

            ParsedMetadata parsed;
            if (readSucceeded) parsed = collectMetadata(state->player);

            QMediaPlayer* player = state->player;
            QTimer* timer = state->timer;
            player->stop();
            player->deleteLater();
            timer->deleteLater();
            state->callback(Result<ParsedMetadata>::success(std::move(parsed)));
        };

        QObject::connect(player, &QMediaPlayer::mediaStatusChanged, player,
            [finish](QMediaPlayer::MediaStatus status) {
                switch (status) {
                case QMediaPlayer::LoadedMedia:
                case QMediaPlayer::BufferedMedia:
                case QMediaPlayer::EndOfMedia:
                    finish(true);
                    break;
                case QMediaPlayer::InvalidMedia:
                    finish(false);
                    break;
                default:
                    break;
                }
            });
        QObject::connect(player, &QMediaPlayer::errorOccurred, player,
            [finish](QMediaPlayer::Error error) {
                if (error != QMediaPlayer::NoError) finish(false);
            });
        QObject::connect(timer, &QTimer::timeout, player, [finish] { finish(false); });

        if (ct.canBeCancelled()) {
            state->cancelId = ct.registerCallback([finish] { finish(false); });
        }

        timer->start(15000);
        player->setSource(QUrl::fromLocalFile(path));
    }};
}

#endif // CT_HAVE_QT_MULTIMEDIA

Task<std::optional<Song>> parseMetadataTask(const QString& path, CancellationToken ct)
{
    if (ct.isCancellationRequested()) throw MusicException::cancelled();

    ParsedMetadata parsed;
#ifdef CT_HAVE_QT_MULTIMEDIA
    if (qobject_cast<QGuiApplication*>(QCoreApplication::instance()) != nullptr) {
        parsed = co_await readPlayerMetadata(path, ct);
        if (!parsed.valid) {
            CTLog::general().warn(
                QStringLiteral("读取本地音频失败 [%1]").arg(QFileInfo(path).fileName()));
            co_return std::optional<Song>{};
        }
    } else {
        reportMissingMultimedia();
    }
#else
    reportMissingMultimedia();
#endif

    co_return std::optional<Song>(buildSong(path, parsed));
}

} // namespace

LocalProvider& LocalProvider::shared()
{
    static LocalProvider instance;
    return instance;
}

LocalProvider::LocalProvider()
{
    QDir().mkpath(coverDirectory());
}

QString LocalProvider::identifier() const
{
    return QStringLiteral("local");
}

QString LocalProvider::displayName() const
{
    return QStringLiteral("本地音乐");
}

QSet<QString> LocalProvider::importedPathSet() const
{
    QSet<QString> seen;
    std::lock_guard<std::mutex> lock(m_gate);
    for (const Song& song : m_importedSongs) {
        if (song.localFileURL) seen.insert(dedupKey(*song.localFileURL));
    }
    return seen;
}

Task<QList<Song>> LocalProvider::importFiles(const QStringList& paths, CancellationToken ct)
{
    QList<Song> songs;
    QSet<QString> seen = importedPathSet();
    for (const QString& path : paths) {
        if (ct.isCancellationRequested()) throw MusicException::cancelled();
        if (!isSupportedPath(path)) continue;
        const std::optional<QString> fullPath = normalizePath(path);
        if (!fullPath) continue;
        const QString key = dedupKey(*fullPath);
        if (seen.contains(key)) continue;
        seen.insert(key);
        std::optional<Song> song = co_await parseMetadataTask(*fullPath, ct);
        if (song) songs.append(*song);
    }
    {
        std::lock_guard<std::mutex> lock(m_gate);
        m_importedSongs += songs;
    }
    persistLibrary();
    co_return songs;
}

Task<QList<Song>> LocalProvider::scanDirectory(const QString& directory, CancellationToken ct)
{
    QList<Song> songs;
    if (!QDir(directory).exists()) co_return songs;

    QSet<QString> seen = importedPathSet();
    QDirIterator it(directory, QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const QString file = it.next();
        if (ct.isCancellationRequested()) throw MusicException::cancelled();
        if (!isSupportedPath(file)) continue;
        const std::optional<QString> fullPath = normalizePath(file);
        if (!fullPath) continue;
        const QString key = dedupKey(*fullPath);
        if (seen.contains(key)) continue;
        seen.insert(key);
        std::optional<Song> song = co_await parseMetadataTask(*fullPath, ct);
        if (song) songs.append(*song);
    }
    {
        std::lock_guard<std::mutex> lock(m_gate);
        m_importedSongs += songs;
    }
    persistLibrary();
    co_return songs;
}

QList<Song> LocalProvider::allSongs() const
{
    std::lock_guard<std::mutex> lock(m_gate);
    return m_importedSongs;
}

Task<QList<Song>> LocalProvider::restoreLibrary(CancellationToken ct)
{
    {
        std::lock_guard<std::mutex> lock(m_gate);
        if (!m_importedSongs.isEmpty()) co_return m_importedSongs;
    }

    const QStringList paths = PersistenceStore::shared().loadLocalLibrary();
    QList<Song> songs;
    for (const QString& path : paths) {
        if (ct.isCancellationRequested()) throw MusicException::cancelled();
        if (!QFile::exists(path)) continue;
        std::optional<Song> song = co_await parseMetadataTask(path, ct);
        if (song) songs.append(*song);
    }

    QList<Song> result;
    {
        std::lock_guard<std::mutex> lock(m_gate);
        if (m_importedSongs.isEmpty()) m_importedSongs = songs;
        result = m_importedSongs;
    }
    co_return result;
}

void LocalProvider::persistLibrary() const
{
    QStringList paths;
    {
        std::lock_guard<std::mutex> lock(m_gate);
        for (const Song& song : m_importedSongs) {
            if (song.localFileURL) paths.append(*song.localFileURL);
        }
    }
    PersistenceStore::shared().saveLocalLibrary(paths);
}

Task<QString> LocalProvider::fetchQRCodeKey(CancellationToken ct)
{
    Q_UNUSED(ct);
    throw MusicException::unknown(QStringLiteral("本地音乐不支持登录"));
}

Task<QString> LocalProvider::fetchQRCodeImage(const QString& key, CancellationToken ct)
{
    Q_UNUSED(key);
    Q_UNUSED(ct);
    throw MusicException::unknown(QStringLiteral("本地音乐不支持登录"));
}

Task<QRLoginStatus> LocalProvider::checkQRCodeStatus(const QString& key, CancellationToken ct)
{
    Q_UNUSED(key);
    Q_UNUSED(ct);
    co_return QRLoginStatus::failed(QStringLiteral("本地音乐"));
}

Task<void> LocalProvider::logout(CancellationToken ct)
{
    Q_UNUSED(ct);
    co_return;
}

Task<std::optional<AccountInfo>> LocalProvider::fetchAccountInfo(CancellationToken ct)
{
    Q_UNUSED(ct);
    co_return std::optional<AccountInfo>{};
}

Task<SearchResult> LocalProvider::search(
    const QString& query, SearchType type, int page, int limit, CancellationToken ct)
{
    Q_UNUSED(type);
    Q_UNUSED(ct);

    QList<Song> snapshot;
    {
        std::lock_guard<std::mutex> lock(m_gate);
        snapshot = m_importedSongs;
    }

    QList<Song> filtered;
    for (const Song& song : snapshot) {
        if (song.title.contains(query, Qt::CaseInsensitive)
            || song.artistNames().contains(query, Qt::CaseInsensitive)) {
            filtered.append(song);
        }
    }

    const int start = (page - 1) * limit;
    const int end = qMin(start + limit, static_cast<int>(filtered.size()));
    QList<Song> songs;
    if (start >= 0 && start < end) songs = filtered.mid(start, end - start);

    SearchResult result;
    result.songs = songs;
    result.totalCount = filtered.size();
    result.hasMore = end < filtered.size();
    co_return result;
}

Task<PlaylistDetail> LocalProvider::fetchPlaylistDetail(const QString& id, CancellationToken ct)
{
    Q_UNUSED(id);
    Q_UNUSED(ct);
    throw MusicException::unknown(QStringLiteral("本地音乐不支持歌单"));
}

Task<QList<Song>> LocalProvider::fetchPlaylistTracks(
    const QString& id, int page, int limit, CancellationToken ct)
{
    Q_UNUSED(id);
    Q_UNUSED(page);
    Q_UNUSED(limit);
    Q_UNUSED(ct);
    co_return QList<Song>{};
}

Task<PlaylistDetail> LocalProvider::fetchAlbumDetail(const QString& id, CancellationToken ct)
{
    Q_UNUSED(id);
    Q_UNUSED(ct);
    throw MusicException::unknown(QStringLiteral("本地音乐不支持专辑"));
}

Task<ArtistDetail> LocalProvider::fetchArtistDetail(const QString& id, CancellationToken ct)
{
    Q_UNUSED(id);
    Q_UNUSED(ct);
    throw MusicException::unknown(QStringLiteral("本地音乐不支持歌手"));
}

Task<PlayableURL> LocalProvider::fetchPlayableURL(
    const QString& songID, QualityLevel quality, CancellationToken ct)
{
    Q_UNUSED(quality);
    Q_UNUSED(ct);

    std::optional<QString> localPath;
    {
        std::lock_guard<std::mutex> lock(m_gate);
        for (const Song& candidate : m_importedSongs) {
            if (candidate.id == songID) {
                localPath = candidate.localFileURL;
                break;
            }
        }
    }
    if (!localPath || !QFile::exists(*localPath)) throw MusicException::fileNotFound();

    PlayableURL playable;
    playable.url = QUrl::fromLocalFile(*localPath).toString();
    playable.quality.level = QualityLevel::Unknown;
    playable.quality.isActual = true;
    co_return playable;
}

Task<LyricResult> LocalProvider::fetchLyrics(const QString& songID, CancellationToken ct)
{
    Q_UNUSED(songID);
    Q_UNUSED(ct);
    LyricResult result;
    result.hasWordTiming = false;
    result.isPureMusic = true;
    co_return result;
}

Task<QList<Playlist>> LocalProvider::fetchUserPlaylists(CancellationToken ct)
{
    Q_UNUSED(ct);
    co_return QList<Playlist>{};
}

Task<QList<Song>> LocalProvider::fetchLikedSongs(CancellationToken ct)
{
    Q_UNUSED(ct);
    co_return QList<Song>{};
}

Task<void> LocalProvider::likeSong(const QString& id, bool like, CancellationToken ct)
{
    Q_UNUSED(id);
    Q_UNUSED(like);
    Q_UNUSED(ct);
    co_return;
}

Task<QList<Playlist>> LocalProvider::fetchRecommendPlaylists(CancellationToken ct)
{
    Q_UNUSED(ct);
    co_return QList<Playlist>{};
}

Task<QList<Song>> LocalProvider::fetchDailyRecommendSongs(CancellationToken ct)
{
    Q_UNUSED(ct);
    co_return QList<Song>{};
}

Task<QStringList> LocalProvider::fetchLikedSongIDs(CancellationToken ct)
{
    Q_UNUSED(ct);
    co_return QStringList{};
}

} // namespace ct
