using ClearTone.Core.Models;
using ClearTone.Playback;
using Xunit;

namespace ClearTone.Tests;

public class PlayQueueTests
{
    private static Song MakeSong(string id) => new()
    {
        Id = id,
        Title = $"Song {id}",
        Artists = { new Artist { Id = "a1", Name = "Artist" } },
        Source = SongSource.Netease,
    };

    [Fact]
    public void TestReplaceAndNavigate()
    {
        var queue = new PlayQueue();
        var songs = Enumerable.Range(1, 5).Select(index => MakeSong($"{index}")).ToList();
        queue.Replace(songs, 2);

        Assert.Equal(5, queue.Count);
        Assert.Equal(2, queue.CurrentIndex);
        Assert.Equal("3", queue.CurrentItem?.Song.Id);

        var next = queue.Next();
        Assert.Equal("4", next?.Song.Id);
        Assert.Equal(3, queue.CurrentIndex);

        var prev = queue.Previous();
        Assert.Equal("3", prev?.Song.Id);
        Assert.Equal(2, queue.CurrentIndex);
    }

    [Fact]
    public void TestSequentialEnd()
    {
        var queue = new PlayQueue();
        queue.Replace(new List<Song> { MakeSong("1"), MakeSong("2") });
        queue.JumpTo(queue.Items[1].Id);

        Assert.Null(queue.HandleEnded());
    }

    [Fact]
    public void TestLoopAll()
    {
        var queue = new PlayQueue { Mode = PlayMode.LoopAll };
        queue.Replace(new List<Song> { MakeSong("1"), MakeSong("2") });
        queue.JumpTo(queue.Items[1].Id);

        var next = queue.HandleEnded();
        Assert.Equal("1", next?.Song.Id);
        Assert.Equal(0, queue.CurrentIndex);
    }

    [Fact]
    public void TestLoopOne()
    {
        var queue = new PlayQueue { Mode = PlayMode.LoopOne };
        queue.Replace(new List<Song> { MakeSong("1") });
        var next = queue.HandleEnded();
        Assert.Equal("1", next?.Song.Id);
    }

    [Fact]
    public void TestShuffleHistory()
    {
        var queue = new PlayQueue { Mode = PlayMode.Shuffle };
        queue.Replace(Enumerable.Range(1, 5).Select(index => MakeSong($"{index}")).ToList());

        var first = queue.CurrentItem;
        var next1 = queue.Next();
        Assert.NotNull(next1);
        Assert.NotEqual(first?.Id, next1?.Id);

        var prev = queue.Previous();
        Assert.Equal(first?.Id, prev?.Id);
    }

    [Fact]
    public void TestRemoveCurrentItem()
    {
        var queue = new PlayQueue();
        queue.Replace(new List<Song> { MakeSong("1"), MakeSong("2"), MakeSong("3") });
        queue.JumpTo(queue.Items[1].Id);

        var removedID = queue.Items[1].Id;
        Assert.True(queue.Remove(removedID));
        Assert.Equal(2, queue.Count);
        Assert.Equal(1, queue.CurrentIndex);
        Assert.Equal("3", queue.CurrentItem?.Song.Id);
    }

    [Fact]
    public void TestHandleEndedEmptyQueue()
    {
        foreach (var mode in Enum.GetValues<PlayMode>())
        {
            var queue = new PlayQueue { Mode = mode };
            queue.Replace(new List<Song>());
            Assert.Null(queue.HandleEnded());
        }
    }

    [Fact]
    public void TestClearQueueStopsNavigation()
    {
        var queue = new PlayQueue { Mode = PlayMode.LoopAll };
        queue.Replace(new List<Song> { MakeSong("1"), MakeSong("2") });
        queue.Clear();

        Assert.Null(queue.HandleEnded());
        Assert.Null(queue.Next());
        Assert.Null(queue.CurrentItem);
    }

    [Fact]
    public void TestMoveKeepsCurrentItem()
    {
        var queue = new PlayQueue();
        queue.Replace(new List<Song> { MakeSong("1"), MakeSong("2"), MakeSong("3") });
        queue.JumpTo(queue.Items[0].Id);

        queue.Move(0, 3);

        Assert.Equal(new[] { "2", "3", "1" }, queue.Items.Select(item => item.Song.Id).ToArray());
        Assert.Equal(2, queue.CurrentIndex);
        Assert.Equal("1", queue.CurrentItem?.Song.Id);
    }

    [Fact]
    public void TestMoveOtherItemKeepsCurrentIndexStable()
    {
        var queue = new PlayQueue();
        queue.Replace(new List<Song> { MakeSong("1"), MakeSong("2"), MakeSong("3") });
        queue.JumpTo(queue.Items[1].Id);

        queue.Move(2, 0);

        Assert.Equal(new[] { "3", "1", "2" }, queue.Items.Select(item => item.Song.Id).ToArray());
        Assert.Equal("2", queue.CurrentItem?.Song.Id);
        Assert.Equal(2, queue.CurrentIndex);
    }

    [Fact]
    public void TestDuplicateEntries()
    {
        var queue = new PlayQueue();
        var song = MakeSong("1");
        queue.Append(song);
        queue.Append(song);
        queue.Append(song);

        Assert.Equal(3, queue.Count);
        Assert.Equal(3, queue.Items.Select(item => item.Id).Distinct().Count());

        var secondID = queue.Items[1].Id;
        queue.Remove(secondID);
        Assert.Equal(2, queue.Count);
    }
}
