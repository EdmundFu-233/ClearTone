using System.Net.Http;
using System.Text.Json;
using ClearTone.Core.Logging;
using ClearTone.Core.Models;
using ClearTone.Core.Persistence;

namespace ClearTone.Playback;

public sealed class AudioCacheManager
{
    private static readonly Lazy<AudioCacheManager> SharedHolder =
        new(() => new AudioCacheManager(), LazyThreadSafetyMode.ExecutionAndPublication);

    public static AudioCacheManager Shared => SharedHolder.Value;

    public sealed class CacheMeta
    {
        public string FormatName { get; set; } = "";
        public int BitrateKbps { get; set; }
        public string FileExtension { get; set; } = "";
        public long SizeBytes { get; set; }
        public DateTimeOffset CachedAt { get; set; }
        public DateTimeOffset? LastAccessedAt { get; set; }
    }

    public sealed record CachedAudio(Uri Url, string FormatName, int BitrateKbps);

    private sealed record PendingCache(string SongID, Uri SourceURL, double DurationSeconds, int Generation);

    private sealed record DownloadResult(string Path, string FormatName, string Extension, long SizeBytes);

    public const int DefaultTargetBitrate = 128_000;

    private const string TempPrefix = "tmp-";
    private const string UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36";
    private const long MaxCacheBytes = 1_500_000_000;
    private const long RequiredFreeBytes = 64L * 1024 * 1024;

    private static readonly TimeSpan AccessTouchInterval = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan IndexFlushDelay = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan DownloadTimeout = TimeSpan.FromMinutes(5);

    public static IReadOnlyList<string> CacheFileExtensions { get; } = new[]
    {
        "mp3", "m4a", "aac", "flac", "opus", "wav", "aiff",
    };

    private static readonly HashSet<string> CacheExtensionSet =
        new(CacheFileExtensions, StringComparer.OrdinalIgnoreCase);

    public event Action? StateChanged;

    private readonly object _gate = new();
    private readonly string _cacheDirectory;
    private readonly string _indexPath;
    private readonly HttpClient _client;
    private readonly Dictionary<string, CacheMeta> _index = new(StringComparer.Ordinal);
    private readonly HashSet<string> _cachedSongIDs = new(StringComparer.Ordinal);
    private readonly HashSet<string> _cachingSongIDs = new(StringComparer.Ordinal);
    private readonly Queue<PendingCache> _pending = new();

    private volatile bool _isEnabled = true;
    private bool _isRunning;
    private int _clearGeneration;
    private string? _currentCachedSongID;
    private bool _indexDirty;

    private AudioCacheManager() : this(Path.Combine(StoragePaths.Root, "AudioCache"), null)
    {
    }

    internal AudioCacheManager(string cacheDirectory, HttpMessageHandler? handler = null)
    {
        _cacheDirectory = cacheDirectory;
        _indexPath = Path.Combine(cacheDirectory, "index.json");
        var httpHandler = handler ?? CreateHandler();
        _client = new HttpClient(httpHandler, disposeHandler: true) { Timeout = DownloadTimeout };
        _client.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", UserAgent);
        Directory.CreateDirectory(_cacheDirectory);
        RefreshIndex();
    }

    public bool IsEnabled
    {
        get => _isEnabled;
        set => _isEnabled = value;
    }

    public IReadOnlyCollection<string> CachedSongIDs
    {
        get
        {
            lock (_gate) return _cachedSongIDs.ToList();
        }
    }

    public IReadOnlyCollection<string> CachingSongIDs
    {
        get
        {
            lock (_gate) return _cachingSongIDs.ToList();
        }
    }

    public long TotalCacheBytes
    {
        get
        {
            lock (_gate) return _index.Values.Sum(meta => meta.SizeBytes);
        }
    }

    public string FormattedTotalSize => FormatBytes(TotalCacheBytes);

    public static bool IsCacheFile(string path)
    {
        var name = Path.GetFileName(path);
        if (name.StartsWith(TempPrefix, StringComparison.Ordinal)) return false;
        var extension = Path.GetExtension(name).TrimStart('.');
        return CacheExtensionSet.Contains(extension);
    }

    public static List<string> CacheClearDeletionTargets(IEnumerable<string> paths, string? protectedSongID)
    {
        var list = paths.ToList();
        if (protectedSongID is null) return list;
        return list.Where(path => Path.GetFileNameWithoutExtension(path) != protectedSongID).ToList();
    }

    internal static string ExtensionFor(string? contentType, Uri? sourceURL)
    {
        if (!string.IsNullOrEmpty(contentType))
        {
            var mediaType = contentType.Split(';')[0].Trim().ToLowerInvariant();
            var mapped = mediaType switch
            {
                "audio/mpeg" or "audio/mp3" => "mp3",
                "audio/mp4" or "audio/x-m4a" or "audio/m4a" => "m4a",
                "audio/aac" or "audio/aacp" => "aac",
                "audio/flac" or "audio/x-flac" => "flac",
                "audio/opus" => "opus",
                "audio/wav" or "audio/x-wav" or "audio/wave" => "wav",
                "audio/aiff" or "audio/x-aiff" => "aiff",
                _ => null,
            };
            if (mapped is not null) return mapped;
        }
        if (sourceURL is not null)
        {
            var extension = Path.GetExtension(sourceURL.AbsolutePath).TrimStart('.').ToLowerInvariant();
            if (CacheExtensionSet.Contains(extension)) return extension;
        }
        return "mp3";
    }

    internal static string FormatBytes(long bytes)
    {
        var value = (double)Math.Max(0, bytes);
        string[] units = { "B", "KB", "MB", "GB", "TB" };
        var unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit += 1;
        }
        return unit == 0 ? $"{bytes} B" : $"{value:0.##} {units[unit]}";
    }

    public CachedAudio? CachedItem(string songID)
    {
        string? path;
        CacheMeta meta;
        lock (_gate)
        {
            if (!_index.TryGetValue(songID, out var indexed)) return null;
            if (AudioCacheRetentionPolicy.IsExpired(indexed.CachedAt)) return null;
            meta = indexed;
            path = FilePathFor(songID, meta);
        }
        if (path is null || !File.Exists(path)) return null;
        TouchAccess(songID);
        return new CachedAudio(new Uri(path), meta.FormatName, meta.BitrateKbps);
    }

    public CacheMeta? Meta(string songID)
    {
        lock (_gate)
        {
            if (!_index.TryGetValue(songID, out var meta)) return null;
            if (AudioCacheRetentionPolicy.IsExpired(meta.CachedAt)) return null;
            return CloneMeta(meta);
        }
    }

    public void SetCurrentCachedSong(string? songID)
    {
        lock (_gate)
        {
            _currentCachedSongID = songID;
        }
    }

    public void CacheInBackground(string songID, Uri sourceURL, double durationSeconds = 0)
    {
        if (!_isEnabled || string.IsNullOrEmpty(songID) || sourceURL.IsFile) return;
        lock (_gate)
        {
            if (_cachedSongIDs.Contains(songID) || _cachingSongIDs.Contains(songID)) return;
        }
        if (!HasSufficientDiskSpace())
        {
            CTLog.General.Warn($"磁盘空间不足，跳过缓存: {songID}");
            return;
        }
        lock (_gate)
        {
            if (_cachedSongIDs.Contains(songID) || _cachingSongIDs.Contains(songID)) return;
            _cachingSongIDs.Add(songID);
            _pending.Enqueue(new PendingCache(songID, sourceURL, durationSeconds, _clearGeneration));
        }
        StateChanged?.Invoke();
        PumpCacheQueue();
    }

    public void ClearAll()
    {
        string? protectedID;
        lock (_gate)
        {
            _clearGeneration += 1;
            _pending.Clear();
            _cachingSongIDs.Clear();
            protectedID = _currentCachedSongID;
            if (protectedID is not null && _index.TryGetValue(protectedID, out var meta))
            {
                _index.Clear();
                _index[protectedID] = meta;
                _cachedSongIDs.Clear();
                _cachedSongIDs.Add(protectedID);
            }
            else
            {
                _index.Clear();
                _cachedSongIDs.Clear();
            }
        }
        var files = Directory.Exists(_cacheDirectory) ? Directory.GetFiles(_cacheDirectory) : Array.Empty<string>();
        foreach (var file in CacheClearDeletionTargets(files, protectedID))
        {
            TryDelete(file);
        }
        PersistIndex();
        StateChanged?.Invoke();
    }

    private static SocketsHttpHandler CreateHandler() => new()
    {
        UseCookies = false,
        UseProxy = false,
        ConnectTimeout = TimeSpan.FromSeconds(10),
        MaxConnectionsPerServer = 2,
    };

    private static CacheMeta CloneMeta(CacheMeta meta) => new()
    {
        FormatName = meta.FormatName,
        BitrateKbps = meta.BitrateKbps,
        FileExtension = meta.FileExtension,
        SizeBytes = meta.SizeBytes,
        CachedAt = meta.CachedAt,
        LastAccessedAt = meta.LastAccessedAt,
    };

    private string? FilePathFor(string songID, CacheMeta meta)
    {
        if (string.IsNullOrEmpty(meta.FileExtension)) return null;
        return Path.Combine(_cacheDirectory, $"{songID}.{meta.FileExtension}");
    }

    private static void TryDelete(string? path)
    {
        if (string.IsNullOrEmpty(path)) return;
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch
        {
        }
    }

    private void RefreshIndex()
    {
        Dictionary<string, CacheMeta>? loaded = null;
        try
        {
            if (File.Exists(_indexPath))
            {
                loaded = JsonSerializer.Deserialize<Dictionary<string, CacheMeta>>(File.ReadAllText(_indexPath), JsonDefaults.Options);
            }
        }
        catch (Exception error)
        {
            CTLog.General.Warn($"读取音频缓存索引失败: {CTLog.Sanitize(error.Message)}");
        }

        var listing = Directory.Exists(_cacheDirectory) ? Directory.GetFiles(_cacheDirectory) : Array.Empty<string>();
        foreach (var file in listing)
        {
            if (Path.GetFileName(file).StartsWith(TempPrefix, StringComparison.Ordinal)) TryDelete(file);
        }

        lock (_gate)
        {
            _index.Clear();
            if (loaded is not null)
            {
                foreach (var (key, value) in loaded) _index[key] = value;
            }
        }

        var present = new HashSet<string>(StringComparer.Ordinal);
        foreach (var file in listing)
        {
            if (!IsCacheFile(file)) continue;
            var id = Path.GetFileNameWithoutExtension(file);
            if (string.IsNullOrEmpty(id)) continue;
            present.Add(id);
            lock (_gate)
            {
                if (_index.TryGetValue(id, out var existing) && FilePathFor(id, existing) is { } indexedPath && File.Exists(indexedPath))
                {
                    continue;
                }
                _index.Remove(id);
                _index[id] = OrphanMeta(file);
            }
        }

        lock (_gate)
        {
            foreach (var key in _index.Keys.Where(key => !present.Contains(key)).ToList())
            {
                _index.Remove(key);
            }
            _cachedSongIDs.Clear();
            foreach (var key in _index.Keys) _cachedSongIDs.Add(key);
        }

        PersistIndex();
        PurgeExpired();
    }

    private static CacheMeta OrphanMeta(string file)
    {
        long size = 0;
        try
        {
            size = new FileInfo(file).Length;
        }
        catch
        {
        }
        var extension = Path.GetExtension(file).TrimStart('.').ToLowerInvariant();
        return new CacheMeta
        {
            FormatName = extension.ToUpperInvariant(),
            BitrateKbps = DefaultTargetBitrate / 1000,
            FileExtension = extension,
            SizeBytes = size,
            CachedAt = DateTimeOffset.UtcNow,
            LastAccessedAt = null,
        };
    }

    private void PersistIndex()
    {
        Dictionary<string, CacheMeta> snapshot;
        lock (_gate)
        {
            _indexDirty = false;
            snapshot = new Dictionary<string, CacheMeta>(_index, StringComparer.Ordinal);
        }
        try
        {
            Directory.CreateDirectory(_cacheDirectory);
            var data = JsonSerializer.SerializeToUtf8Bytes(snapshot, JsonDefaults.Options);
            var temp = _indexPath + ".tmp";
            File.WriteAllBytes(temp, data);
            File.Move(temp, _indexPath, overwrite: true);
        }
        catch (Exception error)
        {
            CTLog.General.Warn($"写入音频缓存索引失败: {CTLog.Sanitize(error.Message)}");
        }
    }

    private void PersistIndexSoon()
    {
        lock (_gate)
        {
            if (_indexDirty) return;
            _indexDirty = true;
        }
        _ = Task.Run(async () =>
        {
            await Task.Delay(IndexFlushDelay).ConfigureAwait(false);
            PersistIndex();
        });
    }

    private void PumpCacheQueue()
    {
        PendingCache job;
        lock (_gate)
        {
            if (_isRunning || _pending.Count == 0) return;
            _isRunning = true;
            job = _pending.Dequeue();
        }
        _ = Task.Run(() => RunCacheJobAsync(job));
    }

    private async Task RunCacheJobAsync(PendingCache job)
    {
        try
        {
            var result = await DownloadAsync(job, CancellationToken.None).ConfigureAwait(false);
            var meta = new CacheMeta
            {
                FormatName = result.FormatName,
                BitrateKbps = job.DurationSeconds > 0
                    ? SongQualityPolicy.DerivedBitrateKbps(result.SizeBytes, job.DurationSeconds) ?? DefaultTargetBitrate / 1000
                    : DefaultTargetBitrate / 1000,
                FileExtension = result.Extension,
                SizeBytes = result.SizeBytes,
                CachedAt = DateTimeOffset.UtcNow,
                LastAccessedAt = DateTimeOffset.UtcNow,
            };
            bool stale;
            lock (_gate)
            {
                stale = job.Generation != _clearGeneration;
                if (!stale)
                {
                    _index[job.SongID] = meta;
                    _cachedSongIDs.Add(job.SongID);
                }
            }
            if (stale)
            {
                TryDelete(result.Path);
                CTLog.General.Info($"丢弃已过期的缓存结果: {job.SongID}");
                return;
            }
            PersistIndexSoon();
            PurgeExpired();
            TrimIfNeeded();
            CTLog.General.Info($"音频缓存完成: {job.SongID} {meta.FormatName} {meta.BitrateKbps}kbps ({meta.SizeBytes} bytes)");
        }
        catch (Exception error)
        {
            CTLog.General.Warn($"音频缓存失败 [{job.SongID}]: {CTLog.Sanitize(error.Message)}");
        }
        finally
        {
            lock (_gate)
            {
                _cachingSongIDs.Remove(job.SongID);
                _isRunning = false;
            }
            StateChanged?.Invoke();
            PumpCacheQueue();
        }
    }

    private async Task<DownloadResult> DownloadAsync(PendingCache job, CancellationToken ct)
    {
        var temp = Path.Combine(_cacheDirectory, TempPrefix + Guid.NewGuid().ToString("N"));
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, job.SourceURL);
            using var response = await _client
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct)
                .ConfigureAwait(false);
            if ((int)response.StatusCode is < 200 or > 299) throw MusicException.Unknown("缓存下载失败");

            var extension = ExtensionFor(response.Content.Headers.ContentType?.MediaType, job.SourceURL);
            await using (var source = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
            await using (var destination = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, useAsync: true))
            {
                await source.CopyToAsync(destination, ct).ConfigureAwait(false);
            }

            var destinationPath = Path.Combine(_cacheDirectory, $"{job.SongID}.{extension}");
            if (File.Exists(destinationPath)) File.Delete(destinationPath);
            File.Move(temp, destinationPath);
            return new DownloadResult(destinationPath, extension.ToUpperInvariant(), extension, new FileInfo(destinationPath).Length);
        }
        finally
        {
            TryDelete(temp);
        }
    }

    private void TouchAccess(string songID)
    {
        var changed = false;
        lock (_gate)
        {
            if (!_index.TryGetValue(songID, out var meta)) return;
            var now = DateTimeOffset.UtcNow;
            var last = meta.LastAccessedAt ?? meta.CachedAt;
            if (now - last < AccessTouchInterval) return;
            meta.LastAccessedAt = now;
            changed = true;
        }
        if (changed) PersistIndexSoon();
    }

    private int PurgeExpired()
    {
        Dictionary<string, DateTimeOffset> cachedAtByID;
        lock (_gate)
        {
            cachedAtByID = _index.ToDictionary(entry => entry.Key, entry => entry.Value.CachedAt, StringComparer.Ordinal);
        }
        var expired = AudioCacheRetentionPolicy.ExpiredIDs(cachedAtByID);
        if (expired.Count == 0) return 0;

        var removed = 0;
        foreach (var songID in expired)
        {
            string? path;
            lock (_gate)
            {
                if (songID == _currentCachedSongID) continue;
                path = _index.TryGetValue(songID, out var meta) ? FilePathFor(songID, meta) : null;
            }
            TryDelete(path);
            lock (_gate)
            {
                if (_index.Remove(songID))
                {
                    _cachedSongIDs.Remove(songID);
                    removed += 1;
                }
            }
        }
        PersistIndex();
        CTLog.General.Info($"音频缓存过期清理: {expired.Count} 条超过 {AudioCacheRetentionPolicy.MaxAge.TotalDays:0} 天");
        return removed;
    }

    private void TrimIfNeeded()
    {
        lock (_gate)
        {
            if (TotalCacheBytes <= MaxCacheBytes) return;
        }
        var entries = new List<(string Id, string Path, CacheMeta Meta)>();
        foreach (var file in Directory.GetFiles(_cacheDirectory))
        {
            if (!IsCacheFile(file)) continue;
            var id = Path.GetFileNameWithoutExtension(file);
            lock (_gate)
            {
                if (_index.TryGetValue(id, out var meta)) entries.Add((id, file, meta));
            }
        }
        entries.Sort((left, right) =>
        {
            var leftTime = left.Meta.LastAccessedAt ?? left.Meta.CachedAt;
            var rightTime = right.Meta.LastAccessedAt ?? right.Meta.CachedAt;
            return leftTime.CompareTo(rightTime);
        });

        var changed = false;
        foreach (var entry in entries)
        {
            bool over;
            lock (_gate)
            {
                over = TotalCacheBytes > MaxCacheBytes;
            }
            if (!over) break;
            bool protect;
            lock (_gate)
            {
                protect = entry.Id == _currentCachedSongID;
            }
            if (protect) continue;
            TryDelete(entry.Path);
            lock (_gate)
            {
                if (_index.Remove(entry.Id))
                {
                    _cachedSongIDs.Remove(entry.Id);
                    changed = true;
                }
            }
        }
        if (changed) PersistIndex();
    }

    private bool HasSufficientDiskSpace()
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(_cacheDirectory));
            if (string.IsNullOrEmpty(root)) return true;
            var drive = new DriveInfo(root);
            return !drive.IsReady || drive.AvailableFreeSpace > RequiredFreeBytes;
        }
        catch
        {
            return true;
        }
    }
}
