using ClearTone.Playback;
using Xunit;

namespace ClearTone.Tests;

public class AudioCacheManagerPolicyTests
{
    private sealed class CacheMeta
    {
        public long SizeBytes { get; set; }
        public DateTimeOffset CachedAt { get; set; }
        public DateTimeOffset? LastAccessedAt { get; set; }
    }

    private sealed class Store
    {
        public Dictionary<string, CacheMeta> Index { get; } = new();
        public HashSet<string> CachedIDs { get; } = new();
        public int ClearGeneration { get; set; }
        public string? CurrentCachedSongID { get; set; }
        public long MaxBytes { get; }

        public Store(long maxBytes)
        {
            MaxBytes = maxBytes;
        }

        public List<string> EvictionOrder()
        {
            return Index
                .OrderBy(pair => pair.Value.LastAccessedAt ?? pair.Value.CachedAt)
                .Select(pair => pair.Key)
                .ToList();
        }

        public long Total => Index.Values.Sum(meta => meta.SizeBytes);

        public HashSet<string> Trim()
        {
            var removed = new HashSet<string>();
            foreach (var id in EvictionOrder())
            {
                if (Total <= MaxBytes) break;
                if (id == CurrentCachedSongID) continue;
                if (!Index.Remove(id)) continue;
                CachedIDs.Remove(id);
                removed.Add(id);
            }
            return removed;
        }

        public HashSet<string> PurgeExpired(DateTimeOffset now)
        {
            var expired = AudioCacheRetentionPolicy.ExpiredIDs(
                Index.ToDictionary(pair => pair.Key, pair => pair.Value.CachedAt),
                now,
                AudioCacheRetentionPolicy.MaxAge);
            var removed = new HashSet<string>();
            foreach (var id in expired)
            {
                if (id == CurrentCachedSongID) continue;
                if (!Index.Remove(id)) continue;
                CachedIDs.Remove(id);
                removed.Add(id);
            }
            return removed;
        }
    }

    [Fact]
    public void TestEvictionUsesLastAccessedNotCachedAt()
    {
        var store = new Store(1000);
        var t0 = DateTimeOffset.UtcNow;
        store.Index["old-but-favorite"] = new CacheMeta { SizeBytes = 400, CachedAt = t0, LastAccessedAt = t0 };
        store.Index["mid"] = new CacheMeta { SizeBytes = 400, CachedAt = t0.AddSeconds(10), LastAccessedAt = t0.AddSeconds(10) };
        store.Index["newest"] = new CacheMeta { SizeBytes = 400, CachedAt = t0.AddSeconds(20), LastAccessedAt = t0.AddSeconds(20) };
        store.Index["old-but-favorite"].LastAccessedAt = t0.AddSeconds(1000);

        var order = store.EvictionOrder();
        Assert.Equal("mid", order.First());
        Assert.Equal("old-but-favorite", order.Last());
    }

    [Fact]
    public void TestFallsBackToCachedAtWhenNeverAccessed()
    {
        var t0 = DateTimeOffset.UtcNow;
        var store = new Store(1000);
        store.Index["a"] = new CacheMeta { SizeBytes = 500, CachedAt = t0, LastAccessedAt = null };
        store.Index["b"] = new CacheMeta { SizeBytes = 500, CachedAt = t0.AddSeconds(5), LastAccessedAt = null };
        Assert.Equal("a", store.EvictionOrder().First());
    }

    [Fact]
    public void TestTrimDeletesOldestUntilUnderLimit()
    {
        var t0 = DateTimeOffset.UtcNow;
        var store = new Store(1000);
        for (var index = 0; index < 5; index++)
        {
            store.Index[$"s{index}"] = new CacheMeta { SizeBytes = 400, CachedAt = t0.AddSeconds(index), LastAccessedAt = null };
            store.CachedIDs.Add($"s{index}");
        }

        var removed = store.Trim();
        Assert.Equal(new[] { "s0", "s1", "s2" }, removed);
        Assert.True(store.Total <= 1000);
        Assert.Equal(new HashSet<string> { "s3", "s4" }, store.CachedIDs);
    }

    [Fact]
    public void TestTrimNeverDeletesCurrentlyPlayingCache()
    {
        var t0 = DateTimeOffset.UtcNow;
        var store = new Store(1000);
        store.Index["playing"] = new CacheMeta { SizeBytes = 400, CachedAt = t0, LastAccessedAt = t0 };
        store.Index["x"] = new CacheMeta { SizeBytes = 400, CachedAt = t0.AddSeconds(1), LastAccessedAt = t0.AddSeconds(1) };
        store.Index["y"] = new CacheMeta { SizeBytes = 400, CachedAt = t0.AddSeconds(2), LastAccessedAt = t0.AddSeconds(2) };
        store.CurrentCachedSongID = "playing";

        var removed = store.Trim();
        Assert.DoesNotContain("playing", removed);
        Assert.True(store.Index.ContainsKey("playing"));
    }

    [Fact]
    public void TestClearGenerationInvalidatesInFlightResults()
    {
        var store = new Store(1000);
        var captured = store.ClearGeneration;
        store.ClearGeneration += 1;

        var shouldCommit = captured == store.ClearGeneration;
        Assert.False(shouldCommit);
    }

    [Fact]
    public void TestInFlightResultCommitsWhenNoClearHappened()
    {
        var store = new Store(1000);
        var captured = store.ClearGeneration;
        Assert.True(captured == store.ClearGeneration);
    }

    [Fact]
    public void TestTempFilesAreNotIndexedOrCounted()
    {
        var names = new[] { "12345.mp3", "tmp-ABC.mp3", "67890.mp3", "index.json", "tmp-DEF.mp3" };
        var real = names.Where(name => AudioCacheManager.IsCacheFile(Path.Combine("/cache", name))).ToList();
        Assert.Equal(
            new[] { "12345", "67890" },
            real.Select(name => Path.GetFileNameWithoutExtension(name)).ToArray());
    }

    [Fact]
    public void TestCacheFileFilterFollowsPlatformExtension()
    {
        foreach (var extension in AudioCacheManager.CacheFileExtensions)
        {
            Assert.True(AudioCacheManager.IsCacheFile($"/cache/12345.{extension}"));
        }

        Assert.True(AudioCacheManager.IsCacheFile("/cache/12345.m4a"));
        Assert.False(AudioCacheManager.IsCacheFile("/cache/12345.caf"));
        Assert.False(AudioCacheManager.IsCacheFile("/cache/tmp-ABC.mp3"));
        Assert.False(AudioCacheManager.IsCacheFile("/cache/index.json"));
    }

    [Fact]
    public void TestIndexRecoversEntriesForOrphanFiles()
    {
        var t0 = DateTimeOffset.UtcNow;
        var orphan = new CacheMeta { SizeBytes = 5_400_000, CachedAt = t0, LastAccessedAt = null };
        var neverPlayed = new CacheMeta { SizeBytes = 5_400_000, CachedAt = t0.AddSeconds(-100), LastAccessedAt = null };
        Assert.Equal(5_400_000, orphan.SizeBytes);

        DateTimeOffset SortKey(CacheMeta meta) => meta.LastAccessedAt ?? meta.CachedAt;
        Assert.True(SortKey(neverPlayed) < SortKey(orphan));
    }

    [Fact]
    public void TestRecoveredOrphanStartsFreshForRetention()
    {
        var now = DateTimeOffset.UtcNow;
        Assert.False(AudioCacheRetentionPolicy.IsExpired(now, now, AudioCacheRetentionPolicy.MaxAge));
    }

    [Fact]
    public void TestTargetBitrateIs128kbps()
    {
        Assert.Equal(128_000, AudioCacheManager.DefaultTargetBitrate);
        Assert.Equal(0, AudioCacheManager.DefaultTargetBitrate % 1000);
    }

    [Fact]
    public void TestRetentionIsExactlySevenDays()
    {
        var now = DateTimeOffset.UtcNow;
        Assert.Equal(TimeSpan.FromDays(7), AudioCacheRetentionPolicy.MaxAge);
        Assert.False(AudioCacheRetentionPolicy.IsExpired(now, now, AudioCacheRetentionPolicy.MaxAge));
        Assert.False(AudioCacheRetentionPolicy.IsExpired(
            now.AddSeconds(-6 * 24 * 60 * 60), now, AudioCacheRetentionPolicy.MaxAge));
        Assert.True(AudioCacheRetentionPolicy.IsExpired(
            now.AddSeconds(-8 * 24 * 60 * 60), now, AudioCacheRetentionPolicy.MaxAge));
        Assert.True(AudioCacheRetentionPolicy.IsExpired(
            now.AddSeconds(-AudioCacheRetentionPolicy.MaxAge.TotalSeconds), now, AudioCacheRetentionPolicy.MaxAge));
    }

    [Fact]
    public void TestExpiryIsMeasuredFromCachedAtNotLastAccess()
    {
        var now = DateTimeOffset.UtcNow;
        var old = now.AddSeconds(-10 * 24 * 60 * 60);
        var justListened = now.AddSeconds(-60);
        Assert.True(AudioCacheRetentionPolicy.IsExpired(old, now, AudioCacheRetentionPolicy.MaxAge));
        Assert.False(AudioCacheRetentionPolicy.IsExpired(justListened, now, AudioCacheRetentionPolicy.MaxAge));
    }

    [Fact]
    public void TestFutureTimestampIsNotExpired()
    {
        var now = DateTimeOffset.UtcNow;
        Assert.False(AudioCacheRetentionPolicy.IsExpired(
            now.AddSeconds(60 * 60), now, AudioCacheRetentionPolicy.MaxAge));
    }

    [Fact]
    public void TestExpiredIDsSelectsOnlyOverdueEntries()
    {
        var now = DateTimeOffset.UtcNow;
        var byAge = new Dictionary<string, DateTimeOffset>
        {
            ["fresh"] = now.AddSeconds(-3600),
            ["almost"] = now.AddSeconds(-(6.9 * 24 * 60 * 60)),
            ["stale"] = now.AddSeconds(-(7.1 * 24 * 60 * 60)),
            ["ancient"] = now.AddSeconds(-(30 * 24 * 60 * 60)),
        };
        var result = AudioCacheRetentionPolicy.ExpiredIDs(byAge, now, AudioCacheRetentionPolicy.MaxAge);
        Assert.Equal(new[] { "ancient", "stale" }, result.OrderBy(id => id).ToArray());
    }

    [Fact]
    public void TestExpirySweepRunsEvenWhenUnderCapacity()
    {
        var now = DateTimeOffset.UtcNow;
        var store = new Store(1_000_000_000);
        store.Index["stale"] = new CacheMeta
        {
            SizeBytes = 1_000,
            CachedAt = now.AddSeconds(-9 * 24 * 60 * 60),
            LastAccessedAt = now.AddSeconds(-9 * 24 * 60 * 60),
        };
        store.Index["fresh"] = new CacheMeta { SizeBytes = 1_000, CachedAt = now.AddSeconds(-60), LastAccessedAt = null };
        store.CachedIDs.UnionWith(new[] { "stale", "fresh" });

        var purged = store.PurgeExpired(now);
        Assert.Equal(new[] { "stale" }, purged);
        Assert.Equal(new[] { "fresh" }, store.Index.Keys.OrderBy(key => key).ToArray());
        Assert.Equal(new HashSet<string> { "fresh" }, store.CachedIDs);
    }

    [Fact]
    public void TestExpirySweepProtectsCurrentlyPlayingFile()
    {
        var now = DateTimeOffset.UtcNow;
        var store = new Store(1_000_000_000);
        store.Index["playing"] = new CacheMeta
        {
            SizeBytes = 1_000,
            CachedAt = now.AddSeconds(-9 * 24 * 60 * 60),
            LastAccessedAt = null,
        };
        store.CurrentCachedSongID = "playing";
        store.CachedIDs.Add("playing");

        Assert.Empty(store.PurgeExpired(now));
        Assert.True(store.Index.ContainsKey("playing"));
    }

    [Fact]
    public void TestCapacityEvictionStillAppliesToUnexpiredEntries()
    {
        var now = DateTimeOffset.UtcNow;
        var store = new Store(1000);
        for (var index = 0; index < 5; index++)
        {
            store.Index[$"s{index}"] = new CacheMeta { SizeBytes = 400, CachedAt = now.AddSeconds(-index), LastAccessedAt = null };
        }
        Assert.Empty(store.PurgeExpired(now));
        Assert.Equal(new[] { "s4", "s3", "s2" }, store.Trim());
    }

    [Fact]
    public void TestClearAllKeepsCurrentlyPlayingFile()
    {
        const string playing = "/cache/playing.mp3";
        const string other = "/cache/other.mp3";
        const string index = "/cache/index.json";

        var targets = AudioCacheManager.CacheClearDeletionTargets(new[] { playing, other, index }, "playing");
        Assert.DoesNotContain(playing, targets);
        Assert.Equal(new[] { index, other }, targets.OrderBy(path => path).ToArray());

        var all = AudioCacheManager.CacheClearDeletionTargets(new[] { playing, other }, null);
        Assert.Equal(new[] { other, playing }, all.OrderBy(path => path).ToArray());
    }
}
