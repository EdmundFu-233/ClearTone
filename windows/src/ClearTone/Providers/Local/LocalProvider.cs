using System.Security.Cryptography;
using System.Text;
using ClearTone.Core.Logging;
using ClearTone.Core.Models;
using ClearTone.Core.Persistence;
using TagFile = TagLib.File;

namespace ClearTone.Providers.Local;

public sealed class LocalProvider : IMusicProvider
{
    public static readonly LocalProvider Shared = new();

    public string Identifier => "local";
    public string DisplayName => "本地音乐";

    private static readonly string[] SupportedExtensions = { "mp3", "m4a", "aac", "wav", "flac", "aiff", "alac" };
    private static readonly HashSet<string> SupportedExtensionSet = new(SupportedExtensions, StringComparer.OrdinalIgnoreCase);
    private static readonly StringComparer PathComparer =
        OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    private readonly object _gate = new();
    private readonly List<Song> _importedSongs = new();

    public LocalProvider()
    {
        Directory.CreateDirectory(CoverDirectory);
    }

    private static string CoverDirectory => Path.Combine(StoragePaths.Root, "LocalCovers");

    public async Task<List<Song>> ImportFilesAsync(IReadOnlyList<string> paths, CancellationToken ct = default)
    {
        var songs = new List<Song>();
        var seen = ImportedPathSet();
        foreach (var path in paths)
        {
            ct.ThrowIfCancellationRequested();
            if (!IsSupported(path)) continue;
            var fullPath = NormalizePath(path);
            if (fullPath is null || !seen.Add(fullPath)) continue;
            var song = await Task.Run(() => ParseMetadata(fullPath), ct).ConfigureAwait(false);
            if (song is not null) songs.Add(song);
        }
        lock (_gate)
        {
            _importedSongs.AddRange(songs);
        }
        PersistLibrary();
        return songs;
    }

    public async Task<List<Song>> ScanDirectoryAsync(string directory, CancellationToken ct = default)
    {
        var songs = new List<Song>();
        if (!Directory.Exists(directory)) return songs;
        var seen = ImportedPathSet();
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System,
        };
        foreach (var file in Directory.EnumerateFiles(directory, "*", options))
        {
            ct.ThrowIfCancellationRequested();
            if (!IsSupported(file)) continue;
            var fullPath = NormalizePath(file);
            if (fullPath is null || !seen.Add(fullPath)) continue;
            var song = await Task.Run(() => ParseMetadata(fullPath), ct).ConfigureAwait(false);
            if (song is not null) songs.Add(song);
        }
        lock (_gate)
        {
            _importedSongs.AddRange(songs);
        }
        PersistLibrary();
        return songs;
    }

    public List<Song> AllSongs()
    {
        lock (_gate) return _importedSongs.ToList();
    }

    public async Task<List<Song>> RestoreLibraryAsync(CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_importedSongs.Count > 0) return _importedSongs.ToList();
        }
        var paths = PersistenceStore.Shared.LoadLocalLibrary();
        var songs = new List<Song>();
        foreach (var path in paths)
        {
            ct.ThrowIfCancellationRequested();
            if (!File.Exists(path)) continue;
            var song = await Task.Run(() => ParseMetadata(path), ct).ConfigureAwait(false);
            if (song is not null) songs.Add(song);
        }
        lock (_gate)
        {
            if (_importedSongs.Count == 0) _importedSongs.AddRange(songs);
            return _importedSongs.ToList();
        }
    }

    public Task<string> FetchQRCodeKeyAsync(CancellationToken ct = default) =>
        throw MusicException.Unknown("本地音乐不支持登录");

    public Task<string> FetchQRCodeImageAsync(string key, CancellationToken ct = default) =>
        throw MusicException.Unknown("本地音乐不支持登录");

    public Task<QRLoginStatus> CheckQRCodeStatusAsync(string key, CancellationToken ct = default) =>
        Task.FromResult<QRLoginStatus>(new QRLoginStatus.Failed("本地音乐"));

    public Task LogoutAsync(CancellationToken ct = default) => Task.CompletedTask;

    public Task<AccountInfo?> FetchAccountInfoAsync(CancellationToken ct = default) =>
        Task.FromResult<AccountInfo?>(null);

    public Task<SearchResult> SearchAsync(string query, SearchType type, int page, int limit, CancellationToken ct = default)
    {
        List<Song> snapshot;
        lock (_gate) snapshot = _importedSongs.ToList();
        var filtered = snapshot
            .Where(song =>
                song.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase) ||
                song.ArtistNames.Contains(query, StringComparison.CurrentCultureIgnoreCase))
            .ToList();
        var start = (page - 1) * limit;
        var end = Math.Min(start + limit, filtered.Count);
        var songs = start >= 0 && start < end ? filtered.GetRange(start, end - start) : new List<Song>();
        return Task.FromResult(new SearchResult
        {
            Songs = songs,
            TotalCount = filtered.Count,
            HasMore = end < filtered.Count,
        });
    }

    public Task<PlaylistDetail> FetchPlaylistDetailAsync(string id, CancellationToken ct = default) =>
        throw MusicException.Unknown("本地音乐不支持歌单");

    public Task<List<Song>> FetchPlaylistTracksAsync(string id, int page, int limit, CancellationToken ct = default) =>
        Task.FromResult(new List<Song>());

    public Task<PlaylistDetail> FetchAlbumDetailAsync(string id, CancellationToken ct = default) =>
        throw MusicException.Unknown("本地音乐不支持专辑");

    public Task<ArtistDetail> FetchArtistDetailAsync(string id, CancellationToken ct = default) =>
        throw MusicException.Unknown("本地音乐不支持歌手");

    public Task<PlayableURL> FetchPlayableURLAsync(string songID, QualityLevel quality, CancellationToken ct = default)
    {
        Song? song;
        lock (_gate)
        {
            song = _importedSongs.FirstOrDefault(candidate => candidate.Id == songID);
        }
        if (song?.LocalFileURL is null || !File.Exists(song.LocalFileURL)) throw MusicException.FileNotFound();
        return Task.FromResult(new PlayableURL
        {
            Url = new Uri(song.LocalFileURL),
            Quality = new AudioQuality { Level = QualityLevel.Unknown, IsActual = true },
        });
    }

    public Task<LyricResult> FetchLyricsAsync(string songID, CancellationToken ct = default) =>
        Task.FromResult(new LyricResult { Lines = new List<LyricLine>(), HasWordTiming = false, IsPureMusic = true });

    public Task<List<Playlist>> FetchUserPlaylistsAsync(CancellationToken ct = default) =>
        Task.FromResult(new List<Playlist>());

    public Task<List<Song>> FetchLikedSongsAsync(CancellationToken ct = default) =>
        Task.FromResult(new List<Song>());

    public Task LikeSongAsync(string id, bool like, CancellationToken ct = default) => Task.CompletedTask;

    public Task<List<Playlist>> FetchRecommendPlaylistsAsync(CancellationToken ct = default) =>
        Task.FromResult(new List<Playlist>());

    public Task<List<Song>> FetchDailyRecommendSongsAsync(CancellationToken ct = default) =>
        Task.FromResult(new List<Song>());

    public Task<List<string>> FetchLikedSongIDsAsync(CancellationToken ct = default) =>
        Task.FromResult(new List<string>());

    private HashSet<string> ImportedPathSet()
    {
        var seen = new HashSet<string>(PathComparer);
        lock (_gate)
        {
            foreach (var song in _importedSongs)
            {
                if (song.LocalFileURL is { } path) seen.Add(path);
            }
        }
        return seen;
    }

    private static bool IsSupported(string path)
    {
        var extension = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        return SupportedExtensionSet.Contains(extension);
    }

    private static string? NormalizePath(string path)
    {
        try
        {
            return Path.GetFullPath(path);
        }
        catch
        {
            return null;
        }
    }

    private static string StableID(string fullPath)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(fullPath));
        return Convert.ToHexString(digest).ToLowerInvariant();
    }

    private static Song? ParseMetadata(string path)
    {
        try
        {
            using var tagFile = TagFile.Create(path);
            var duration = tagFile.Properties?.Duration.TotalSeconds ?? 0;
            if (!double.IsFinite(duration) || duration < 0) duration = 0;

            var tag = tagFile.Tag;
            var title = string.IsNullOrWhiteSpace(tag?.Title) ? Path.GetFileNameWithoutExtension(path) : tag.Title;
            var artistName = tag?.Performers?.FirstOrDefault(name => !string.IsNullOrWhiteSpace(name)) ?? "未知艺术家";
            var albumName = string.IsNullOrWhiteSpace(tag?.Album) ? "未知专辑" : tag.Album;
            var fileID = StableID(path);
            var coverURL = ExtractCover(tag, fileID);

            return new Song
            {
                Id = $"local-{fileID}",
                Title = title,
                Artists = new List<Artist> { new() { Id = $"local-artist-{artistName}", Name = artistName } },
                Album = new Album { Id = $"local-album-{albumName}", Name = albumName, CoverURL = coverURL },
                Duration = duration,
                CoverURL = coverURL,
                IsPlayable = true,
                Source = SongSource.Local,
                LocalFileURL = path,
            };
        }
        catch (Exception error)
        {
            CTLog.General.Warn($"读取本地音频失败 [{Path.GetFileName(path)}]: {CTLog.Sanitize(error.Message)}");
            return null;
        }
    }

    private static string? ExtractCover(TagLib.Tag? tag, string fileID)
    {
        var picture = tag?.Pictures?.FirstOrDefault(candidate => candidate.Data is { Count: > 0 });
        if (picture is null) return null;
        try
        {
            Directory.CreateDirectory(CoverDirectory);
            var coverPath = Path.Combine(CoverDirectory, $"{fileID}.jpg");
            if (!File.Exists(coverPath))
            {
                File.WriteAllBytes(coverPath, picture.Data.ToArray());
            }
            return new Uri(coverPath).AbsoluteUri;
        }
        catch (Exception error)
        {
            CTLog.General.Warn($"写入本地封面失败 [{fileID}]: {CTLog.Sanitize(error.Message)}");
            return null;
        }
    }

    private void PersistLibrary()
    {
        List<string> paths;
        lock (_gate)
        {
            paths = _importedSongs
                .Where(song => song.LocalFileURL is not null)
                .Select(song => song.LocalFileURL!)
                .ToList();
        }
        PersistenceStore.Shared.SaveLocalLibrary(paths);
    }
}
