using System.Security.Cryptography;
using System.Text;
using Avalonia.Media.Imaging;
using ClearTone.Core.Logging;
using ClearTone.Core.Persistence;

namespace ClearTone.DesignSystem;

public sealed class CoverImageLoader
{
    public static readonly CoverImageLoader Shared = new();

    private readonly HttpClient _client;
    private readonly object _gate = new();
    private readonly Dictionary<string, Bitmap> _memory = new(StringComparer.Ordinal);
    private readonly LinkedList<string> _lru = new();
    private readonly Dictionary<string, Task<Bitmap?>> _inFlight = new(StringComparer.Ordinal);
    private const int MemoryLimit = 200;

    public CoverImageLoader()
    {
        var handler = new SocketsHttpHandler
        {
            UseCookies = false,
            UseProxy = false,
            ConnectTimeout = TimeSpan.FromSeconds(8),
        };
        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
        _client.DefaultRequestHeaders.TryAddWithoutValidation(
            "User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36");
    }

    public Task<Bitmap?> LoadAsync(string url, int decodeWidth = 0, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(url)) return Task.FromResult<Bitmap?>(null);
        var key = $"{url}|{decodeWidth}";

        lock (_gate)
        {
            if (_memory.TryGetValue(key, out var cached))
            {
                _lru.Remove(key);
                _lru.AddFirst(key);
                return Task.FromResult<Bitmap?>(cached);
            }
            if (_inFlight.TryGetValue(key, out var pending)) return pending;
        }

        var task = LoadCoreAsync(key, url, decodeWidth, ct);
        lock (_gate)
        {
            _inFlight[key] = task;
        }
        _ = task.ContinueWith(_ =>
        {
            lock (_gate)
            {
                _inFlight.Remove(key);
            }
        }, TaskScheduler.Default);
        return task;
    }

    private async Task<Bitmap?> LoadCoreAsync(string key, string url, int decodeWidth, CancellationToken ct)
    {
        try
        {
            var bytes = await ReadBytesAsync(url, ct).ConfigureAwait(false);
            if (bytes is null || bytes.Length == 0) return null;
            var bitmap = Decode(bytes, decodeWidth);
            if (bitmap is null) return null;
            lock (_gate)
            {
                _memory[key] = bitmap;
                _lru.AddFirst(key);
                while (_lru.Count > MemoryLimit)
                {
                    var oldest = _lru.Last;
                    if (oldest is null) break;
                    _lru.RemoveLast();
                    _memory.Remove(oldest.Value);
                }
            }
            return bitmap;
        }
        catch (Exception error)
        {
            CTLog.General.Debug($"封面加载失败 {url}: {CTLog.Sanitize(error.Message)}");
            return null;
        }
    }

    public async Task<byte[]?> LoadBytesAsync(string url, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(url)) return null;
        try
        {
            return await ReadBytesAsync(url, ct).ConfigureAwait(false);
        }
        catch
        {
            return null;
        }
    }

    private async Task<byte[]?> ReadBytesAsync(string url, CancellationToken ct)
    {
        var cachePath = DiskCachePath(url);
        try
        {
            if (File.Exists(cachePath))
            {
                return await File.ReadAllBytesAsync(cachePath, ct).ConfigureAwait(false);
            }
        }
        catch
        {
        }

        var bytes = await _client.GetByteArrayAsync(url, ct).ConfigureAwait(false);
        try
        {
            var directory = Path.GetDirectoryName(cachePath);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            var temp = cachePath + ".tmp";
            await File.WriteAllBytesAsync(temp, bytes, ct).ConfigureAwait(false);
            File.Move(temp, cachePath, overwrite: true);
        }
        catch
        {
        }
        return bytes;
    }

    private static Bitmap? Decode(byte[] bytes, int decodeWidth)
    {
        try
        {
            using var stream = new MemoryStream(bytes);
            return decodeWidth > 0 ? Bitmap.DecodeToWidth(stream, decodeWidth) : new Bitmap(stream);
        }
        catch
        {
            return null;
        }
    }

    private static string DiskCachePath(string url)
    {
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(url))).ToLowerInvariant();
        return Path.Combine(StoragePaths.Root, "CoverCache", hash[..2], hash + ".img");
    }
}
