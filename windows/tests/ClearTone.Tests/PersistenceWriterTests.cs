using ClearTone.Core.Models;
using ClearTone.Core.Persistence;
using ClearTone.Playback;
using Xunit;

namespace ClearTone.Tests;

public class PersistenceWriterTests : IDisposable
{
    public PersistenceWriterTests()
    {
        PersistenceWriter.Shared.Reset();
    }

    public void Dispose()
    {
        PersistenceWriter.Shared.Reset();
    }

    private static Song MakeSong(string id) => new()
    {
        Id = id,
        Title = $"歌-{id}",
        Artists = { new Artist { Id = $"a{id}", Name = "人" } },
        Source = SongSource.Netease,
    };

    private static PersistedQueue MakeQueue(IReadOnlyList<string> itemIDs, double currentTime = 0)
    {
        return new PersistedQueue
        {
            Items = itemIDs.Select(id => new QueueItem { Song = MakeSong(id) }).ToList(),
            CurrentIndex = itemIDs.Count == 0 ? -1 : 0,
            Mode = PlayMode.Sequential,
            CurrentTime = currentTime,
            Volume = 0.8f,
            IsMuted = false,
            RequestedQuality = QualityLevel.ExHigh,
        };
    }

    [Fact]
    public async Task TestQueueOnlyScheduleIsActuallyPersisted()
    {
        var queue = MakeQueue(new[] { "1", "2", "3" }, 42);
        PersistenceWriter.Shared.Schedule(queue);
        await PersistenceWriter.Shared.FlushNowAsync();

        var loaded = PersistenceStore.Shared.LoadQueue();
        Assert.NotNull(loaded);
        Assert.Equal(new[] { "1", "2", "3" }, loaded!.Items.Select(item => item.Song.Id).ToArray());
        Assert.Equal(42, loaded.CurrentTime, 3);
    }

    [Fact]
    public async Task TestRecentOnlyScheduleIsActuallyPersisted()
    {
        var songs = new List<Song> { MakeSong("r1"), MakeSong("r2") };
        PersistenceWriter.Shared.ScheduleRecent(songs);
        await PersistenceWriter.Shared.FlushNowAsync();

        var loaded = PersistenceStore.Shared.LoadRecentSongs();
        Assert.Equal(new[] { "r1", "r2" }, loaded.Select(song => song.Id).ToArray());
    }

    [Fact]
    public async Task TestQueueAndRecentCanBeScheduledIndependently()
    {
        PersistenceWriter.Shared.ScheduleRecent(new List<Song> { MakeSong("only-recent") });
        await PersistenceWriter.Shared.FlushNowAsync();
        Assert.Equal(new[] { "only-recent" }, PersistenceStore.Shared.LoadRecentSongs().Select(song => song.Id).ToArray());

        PersistenceWriter.Shared.Schedule(MakeQueue(new[] { "q1" }));
        await PersistenceWriter.Shared.FlushNowAsync();
        Assert.Equal(new[] { "q1" }, PersistenceStore.Shared.LoadQueue()?.Items.Select(item => item.Song.Id).ToArray());
        Assert.Equal(new[] { "only-recent" }, PersistenceStore.Shared.LoadRecentSongs().Select(song => song.Id).ToArray());
    }

    [Fact]
    public async Task TestEmptyQueueIsPersisted()
    {
        PersistenceWriter.Shared.Schedule(MakeQueue(new[] { "stale" }));
        await PersistenceWriter.Shared.FlushNowAsync();
        Assert.Equal(1, PersistenceStore.Shared.LoadQueue()?.Items.Count);

        PersistenceWriter.Shared.Schedule(MakeQueue(Array.Empty<string>()));
        await PersistenceWriter.Shared.FlushNowAsync();
        var loaded = PersistenceStore.Shared.LoadQueue();
        Assert.NotNull(loaded);
        Assert.True(loaded!.Items.Count == 0);
        Assert.Equal(-1, loaded.CurrentIndex);
    }

    [Fact]
    public async Task TestRepeatedQueueOnlySchedulesAllReachDisk()
    {
        for (var round = 1; round <= 3; round++)
        {
            PersistenceWriter.Shared.Schedule(
                MakeQueue(Enumerable.Range(1, round).Select(index => $"{index}").ToList()));
            await PersistenceWriter.Shared.FlushNowAsync();
        }
        var loaded = PersistenceStore.Shared.LoadQueue();
        Assert.NotNull(loaded);
        Assert.Equal(3, loaded!.Items.Count);
    }

    [Fact]
    public async Task TestPersistAndFlushWritesSnapshotGivenAsArgument()
    {
        await PersistenceWriter.Shared.PersistAndFlushAsync(
            MakeQueue(new[] { "quit-1" }),
            new List<Song> { MakeSong("quit-recent") });
        Assert.Equal(new[] { "quit-1" }, PersistenceStore.Shared.LoadQueue()?.Items.Select(item => item.Song.Id).ToArray());
        Assert.Equal(new[] { "quit-recent" }, PersistenceStore.Shared.LoadRecentSongs().Select(song => song.Id).ToArray());
    }

    [Fact]
    public async Task TestPersistAndFlushWithNilArgumentsKeepsExistingData()
    {
        await PersistenceWriter.Shared.PersistAndFlushAsync(
            MakeQueue(new[] { "keep" }),
            new List<Song> { MakeSong("keep-recent") });
        await PersistenceWriter.Shared.PersistAndFlushAsync(null, null);
        Assert.Equal(new[] { "keep" }, PersistenceStore.Shared.LoadQueue()?.Items.Select(item => item.Song.Id).ToArray());
        Assert.Equal(new[] { "keep-recent" }, PersistenceStore.Shared.LoadRecentSongs().Select(song => song.Id).ToArray());
    }

    [Fact]
    public void TestStorageRootHonoursTestOverride()
    {
        var expected = Environment.GetEnvironmentVariable("CLEARTONE_TEST_STORAGE_DIR");
        Assert.False(string.IsNullOrEmpty(expected));
        Assert.Equal(expected, PersistenceStore.Shared.StorageRoot);
    }

    [Fact(Skip = "Windows source has no DemoAudioGenerator.directory equivalent")]
    public void TestTestAudioDirectoryIsIsolatedToo()
    {
    }

    [Fact]
    public async Task TestNaNSnapshotIsStillWritten()
    {
        var writer = PersistenceWriter.Shared;
        writer.Schedule(MakeQueue(new[] { "sentinel" }, 7));
        await writer.FlushNowAsync();
        var sentinel = PersistenceStore.Shared.LoadQueue();
        Assert.NotNull(sentinel);
        Assert.Equal(new[] { "sentinel" }, sentinel!.Items.Select(item => item.Song.Id).ToArray());

        writer.Schedule(MakeQueue(new[] { "1", "2" }, double.NaN));
        await writer.FlushNowAsync();

        var loaded = PersistenceStore.Shared.LoadQueue();
        Assert.NotNull(loaded);
        Assert.Equal(new[] { "1", "2" }, loaded!.Items.Select(item => item.Song.Id).ToArray());
        Assert.True(double.IsNaN(loaded.CurrentTime));
        Assert.Equal(0.8, (double)loaded.Volume, 3);
    }

    [Fact]
    public async Task TestNaNSnapshotDoesNotWedgeLaterWrites()
    {
        var writer = PersistenceWriter.Shared;
        writer.Schedule(MakeQueue(new[] { "bad" }, double.NaN));
        await writer.FlushNowAsync();
        writer.Schedule(MakeQueue(new[] { "good" }, 42));
        await writer.FlushNowAsync();

        var loaded = PersistenceStore.Shared.LoadQueue();
        Assert.NotNull(loaded);
        Assert.Equal(new[] { "good" }, loaded!.Items.Select(item => item.Song.Id).ToArray());
        Assert.Equal(42, loaded.CurrentTime, 3);
    }

    [Fact]
    public void TestSettingWithNonFiniteFloatKeepsOtherFields()
    {
        const string key = "nanProbe";
        try
        {
            var settings = new AppSettings { LyricOffset = double.NaN, ThemeMode = CTThemeMode.Dark };
            PersistenceStore.Shared.SaveSetting(settings, key);

            var loaded = PersistenceStore.Shared.LoadSetting<AppSettings>(key);
            Assert.NotNull(loaded);
            Assert.Equal(CTThemeMode.Dark, loaded!.ThemeMode);
            Assert.True(double.IsNaN(loaded.LyricOffset));
        }
        finally
        {
            PersistenceStore.Shared.RemoveSetting(key);
        }
    }
}
