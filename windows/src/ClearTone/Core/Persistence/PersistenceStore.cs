using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using ClearTone.Core.Logging;
using ClearTone.Core.Models;
using ClearTone.Playback;

namespace ClearTone.Core.Persistence;

public sealed class PersistenceStore
{
    public static readonly PersistenceStore Shared = new();

    private const string SettingsPrefix = "cleartone.persisted.settings";

    private readonly object _settingsGate = new();
    private JsonObject? _settingsCache;

    public string StorageRoot => StoragePaths.Root;

    private string QueuePath => Path.Combine(StorageRoot, "queue.json");
    private string SettingsPath => Path.Combine(StorageRoot, "settings.json");

    public PersistenceStore()
    {
        Directory.CreateDirectory(StorageRoot);
        PurgeOrphanedDemoAudio();
    }

    private void PurgeOrphanedDemoAudio()
    {
        var dir = Path.Combine(StorageRoot, "DemoAudio");
        if (!Directory.Exists(dir)) return;
        try
        {
            Directory.Delete(dir, recursive: true);
            CTLog.General.Info("已清理演示模式遗留的音频目录");
        }
        catch (Exception error)
        {
            CTLog.General.Error($"清理演示音频目录失败: {CTLog.Sanitize(error.Message)}");
        }
    }

    // MARK: - 队列

    public void SaveQueue(PersistedQueue queue)
    {
        try
        {
            var data = JsonSerializer.SerializeToUtf8Bytes(queue, JsonDefaults.Options);
            WriteAtomic(QueuePath, data);
        }
        catch (Exception error)
        {
            CTLog.General.Error($"保存队列失败: {CTLog.Sanitize(error.Message)}");
        }
    }

    public PersistedQueue? LoadQueue()
    {
        try
        {
            if (!File.Exists(QueuePath)) return null;
            var queue = JsonSerializer.Deserialize<PersistedQueue>(File.ReadAllBytes(QueuePath), JsonDefaults.Options);
            if (queue is null) return null;
            queue.Items = queue.Items.Where(item => IsNotLegacyDemoSong(item.Song)).ToList();
            return queue;
        }
        catch (Exception error)
        {
            CTLog.General.Error($"读取队列失败: {CTLog.Sanitize(error.Message)}");
            return null;
        }
    }

    public void ClearQueue()
    {
        try
        {
            if (File.Exists(QueuePath)) File.Delete(QueuePath);
        }
        catch (Exception error)
        {
            CTLog.General.Error($"清空队列失败: {CTLog.Sanitize(error.Message)}");
        }
        PersistenceWriter.Shared.Reset();
    }

    private static bool IsNotLegacyDemoSong(Song song) => !song.Id.StartsWith("demo-", StringComparison.Ordinal);

    // MARK: - 设置

    public void SaveSetting<T>(T value, string key)
    {
        lock (_settingsGate)
        {
            var settings = LoadSettingsFile();
            settings[key] = JsonSerializer.SerializeToNode(value, JsonDefaults.Options);
            PersistSettingsFile(settings);
        }
    }

    public T? LoadSetting<T>(string key)
    {
        lock (_settingsGate)
        {
            var settings = LoadSettingsFile();
            if (!settings.TryGetPropertyValue(key, out var node) || node is null) return default;
            try
            {
                return node.Deserialize<T>(JsonDefaults.Options);
            }
            catch (Exception error)
            {
                CTLog.General.Error($"读取设置 {key} 失败: {CTLog.Sanitize(error.Message)}");
                return default;
            }
        }
    }

    public void RemoveSetting(string key)
    {
        lock (_settingsGate)
        {
            var settings = LoadSettingsFile();
            if (settings.Remove(key))
            {
                PersistSettingsFile(settings);
            }
        }
    }

    internal string SettingKeyFor(string key) => $"{SettingsPrefix}.{key}";

    private JsonObject LoadSettingsFile()
    {
        if (_settingsCache is not null) return _settingsCache;
        try
        {
            if (File.Exists(SettingsPath))
            {
                var node = JsonNode.Parse(File.ReadAllText(SettingsPath, Encoding.UTF8));
                if (node is JsonObject obj)
                {
                    _settingsCache = obj;
                    return obj;
                }
            }
        }
        catch (Exception error)
        {
            CTLog.General.Error($"读取设置文件失败: {CTLog.Sanitize(error.Message)}");
        }
        _settingsCache = new JsonObject();
        return _settingsCache;
    }

    private void PersistSettingsFile(JsonObject settings)
    {
        try
        {
            var data = Encoding.UTF8.GetBytes(settings.ToJsonString(new JsonSerializerOptions
            {
                WriteIndented = false,
            }));
            WriteAtomic(SettingsPath, data);
        }
        catch (Exception error)
        {
            CTLog.General.Error($"写入设置文件失败: {CTLog.Sanitize(error.Message)}");
        }
    }

    private static void WriteAtomic(string path, byte[] data)
    {
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        var temp = path + ".tmp";
        File.WriteAllBytes(temp, data);
        File.Move(temp, path, overwrite: true);
    }

    // MARK: - 离线缓存（账号 / 喜欢的歌曲）

    public void SaveCachedAccount(AccountInfo account) => SaveSetting(account, "cachedAccount");

    public AccountInfo? LoadCachedAccount() => LoadSetting<AccountInfo>("cachedAccount");

    public void ClearCachedAccount() => RemoveSetting("cachedAccount");

    public void SaveCachedLikedSongs(List<Song> songs) => SaveSetting(songs, "cachedLikedSongs");

    public List<Song> LoadCachedLikedSongs()
    {
        var songs = LoadSetting<List<Song>>("cachedLikedSongs") ?? new List<Song>();
        return songs.Where(IsNotLegacyDemoSong).ToList();
    }

    public void SaveCachedLikedSongIDs(List<string> ids) => SaveSetting(ids, "cachedLikedSongIDs");

    public List<string> LoadCachedLikedSongIDs() => LoadSetting<List<string>>("cachedLikedSongIDs") ?? new List<string>();

    public void ClearCachedLikedSongs()
    {
        RemoveSetting("cachedLikedSongs");
        RemoveSetting("cachedLikedSongIDs");
    }

    public void SaveCachedUserPlaylists(List<Playlist> playlists) => SaveSetting(playlists, "cachedUserPlaylists");

    public List<Playlist> LoadCachedUserPlaylists() =>
        LoadSetting<List<Playlist>>("cachedUserPlaylists") ?? new List<Playlist>();

    public void ClearCachedUserPlaylists() => RemoveSetting("cachedUserPlaylists");

    public void SaveLocalLibrary(List<string> paths) => SaveSetting(paths, "localLibrary");

    public List<string> LoadLocalLibrary() => LoadSetting<List<string>>("localLibrary") ?? new List<string>();

    public void SaveRecentSongs(List<Song> songs) => SaveSetting(songs, "recentSongs");

    public List<Song> LoadRecentSongs()
    {
        var songs = LoadSetting<List<Song>>("recentSongs") ?? new List<Song>();
        return songs.Where(IsNotLegacyDemoSong).ToList();
    }
}

public sealed class PersistenceWriter
{
    public static readonly PersistenceWriter Shared = new();

    private readonly object _gate = new();
    private PersistedQueue? _pendingQueue;
    private List<Song>? _pendingRecent;
    private Task? _flushTask;
    private CancellationTokenSource? _flushCts;
    private int _consecutiveWriteFailures;

    private const int MaxAutoRetries = 5;
    private static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(800);
    private const long MaxBytes = 8L * 1024 * 1024;

    internal Action<PersistedQueue>? QueueWriteOverride { get; set; }
    internal Action<List<Song>>? RecentWriteOverride { get; set; }

    public void Schedule(PersistedQueue queue)
    {
        lock (_gate)
        {
            _pendingQueue = queue;
            ScheduleFlushLocked();
        }
    }

    public void ScheduleRecent(List<Song> recentSongs)
    {
        lock (_gate)
        {
            _pendingRecent = recentSongs;
            ScheduleFlushLocked();
        }
    }

    public async Task FlushNowAsync()
    {
        Task? task;
        CancellationTokenSource? cts;
        lock (_gate)
        {
            task = _flushTask;
            cts = _flushCts;
            _flushTask = null;
            _flushCts = null;
        }
        cts?.Cancel();
        if (task is not null)
        {
            try
            {
                await task.ConfigureAwait(false);
            }
            catch
            {
            }
        }
        await WritePendingAsync().ConfigureAwait(false);
    }

    public async Task PersistAndFlushAsync(PersistedQueue? queue, List<Song>? recentSongs)
    {
        Task? task;
        CancellationTokenSource? cts;
        lock (_gate)
        {
            task = _flushTask;
            cts = _flushCts;
            _flushTask = null;
            _flushCts = null;
            if (queue is not null) _pendingQueue = queue;
            if (recentSongs is not null) _pendingRecent = recentSongs;
        }
        cts?.Cancel();
        if (task is not null)
        {
            try
            {
                await task.ConfigureAwait(false);
            }
            catch
            {
            }
        }
        await WritePendingAsync().ConfigureAwait(false);
    }

    public void Reset()
    {
        Task? task;
        CancellationTokenSource? cts;
        lock (_gate)
        {
            task = _flushTask;
            cts = _flushCts;
            _flushTask = null;
            _flushCts = null;
            _pendingQueue = null;
            _pendingRecent = null;
        }
        cts?.Cancel();
    }

    private void ScheduleFlushLocked()
    {
        if (_flushTask is not null) return;
        var cts = new CancellationTokenSource();
        _flushCts = cts;
        _flushTask = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(Debounce, cts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            await WritePendingAsync().ConfigureAwait(false);
        });
    }

    private async Task WritePendingAsync()
    {
        PersistedQueue? queue;
        List<Song>? recent;
        lock (_gate)
        {
            queue = _pendingQueue;
            recent = _pendingRecent;
            _pendingQueue = null;
            _pendingRecent = null;
            _flushTask = null;
            _flushCts = null;
        }

        var firstError = false;
        if (queue is not null)
        {
            try
            {
                await Task.Run(() => WriteQueueSnapshot(queue)).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                CTLog.General.Warn($"写入队列失败: {CTLog.Sanitize(error.Message)}");
                lock (_gate)
                {
                    _pendingQueue ??= queue;
                }
                firstError = true;
            }
        }
        if (recent is not null)
        {
            try
            {
                await Task.Run(() => WriteRecentSnapshot(recent)).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                CTLog.General.Warn($"写入最近播放失败: {CTLog.Sanitize(error.Message)}");
                lock (_gate)
                {
                    _pendingRecent ??= recent;
                }
                firstError = true;
            }
        }

        if (firstError)
        {
            bool hasPending;
            lock (_gate)
            {
                _consecutiveWriteFailures += 1;
                hasPending = _pendingQueue is not null || _pendingRecent is not null;
                if (_consecutiveWriteFailures <= MaxAutoRetries && hasPending)
                {
                    ScheduleFlushLocked();
                }
            }
        }
        else
        {
            lock (_gate)
            {
                _consecutiveWriteFailures = 0;
            }
        }
    }

    private void WriteQueueSnapshot(PersistedQueue queue)
    {
        if (QueueWriteOverride is { } custom)
        {
            custom(queue);
            return;
        }
        var data = JsonSerializer.SerializeToUtf8Bytes(queue, JsonDefaults.Options);
        if (data.Length > MaxBytes)
        {
            CTLog.General.Warn($"队列快照 {data.Length} 字节超过上限 {MaxBytes}，跳过落盘");
            return;
        }
        var path = Path.Combine(StoragePaths.Root, "queue.json");
        var temp = path + ".tmp";
        Directory.CreateDirectory(StoragePaths.Root);
        File.WriteAllBytes(temp, data);
        File.Move(temp, path, overwrite: true);
    }

    private void WriteRecentSnapshot(List<Song> recent)
    {
        if (RecentWriteOverride is { } custom)
        {
            custom(recent);
            return;
        }
        var data = JsonSerializer.SerializeToUtf8Bytes(recent, JsonDefaults.Options);
        if (data.Length > MaxBytes)
        {
            CTLog.General.Warn($"最近播放快照 {data.Length} 字节超过上限 {MaxBytes}，跳过落盘");
            return;
        }
        PersistenceStore.Shared.SaveSetting(recent, "recentSongs");
    }
}
