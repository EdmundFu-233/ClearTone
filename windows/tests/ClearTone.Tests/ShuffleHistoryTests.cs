using ClearTone.Playback;
using Xunit;

namespace ClearTone.Tests;

public class ShuffleHistoryTests
{
    [Fact]
    public void TestAppendKeepsStackAndSetInSync()
    {
        var history = new ShuffleHistory();
        var a = Guid.NewGuid();
        var b = Guid.NewGuid();
        var c = Guid.NewGuid();
        history.Append(a);
        history.Append(b);
        history.Append(c);

        Assert.Equal(3, history.Count);
        Assert.True(history.Contains(a));
        Assert.True(history.Contains(b));
        Assert.True(history.Contains(c));
        Assert.False(history.Contains(Guid.NewGuid()));

        Assert.Equal(c, history.PopLast());
        Assert.Equal(b, history.PopLast());
        Assert.Equal(a, history.PopLast());
    }

    [Fact]
    public void TestPopLastRemovesFromBothStructures()
    {
        var history = new ShuffleHistory();
        var a = Guid.NewGuid();
        var b = Guid.NewGuid();
        history.Append(a);
        history.Append(b);

        Assert.Equal(b, history.PopLast());
        Assert.False(history.Contains(b));
        Assert.True(history.Contains(a));
        Assert.Equal(1, history.Count);
    }

    [Fact]
    public void TestPopLastOnEmptyReturnsNil()
    {
        var history = new ShuffleHistory();
        Assert.Null(history.PopLast());
        Assert.True(history.IsEmpty);
    }

    [Fact]
    public void TestDuplicateAppendIsIdempotentInSet()
    {
        var history = new ShuffleHistory();
        var a = Guid.NewGuid();
        history.Append(a);
        history.Append(a);

        Assert.Equal(2, history.Count);
        Assert.True(history.Contains(a));
        Assert.Equal(a, history.PopLast());
        Assert.True(history.Contains(a));
    }

    [Fact]
    public void TestRemoveAllWherePrunesBothStructures()
    {
        var history = new ShuffleHistory();
        var keep = Guid.NewGuid();
        var drop = Guid.NewGuid();
        var drop2 = Guid.NewGuid();
        history.Append(keep);
        history.Append(drop);
        history.Append(drop2);
        history.RemoveAllWhere(id => id == drop || id == drop2);

        Assert.Equal(1, history.Count);
        Assert.False(history.Contains(drop));
        Assert.False(history.Contains(drop2));
        Assert.True(history.Contains(keep));
        Assert.Equal(keep, history.PopLast());
    }

    [Fact]
    public void TestRemoveAllClearsBoth()
    {
        var history = new ShuffleHistory();
        history.Append(Guid.NewGuid());
        history.Append(Guid.NewGuid());
        history.RemoveAll();

        Assert.True(history.IsEmpty);
        Assert.Equal(0, history.Count);
        Assert.False(history.Contains(Guid.NewGuid()));
    }

    [Fact]
    public void TestSetAlwaysMirrorsStackMembership()
    {
        var history = new ShuffleHistory();
        var ids = Enumerable.Range(0, 20).Select(_ => Guid.NewGuid()).ToList();
        foreach (var id in ids) history.Append(id);

        var random = new Random(20261007);
        var removed = new HashSet<Guid>(ids.Where(_ => random.Next(2) == 0));
        history.RemoveAllWhere(removed.Contains);

        var expected = ids.Where(id => !removed.Contains(id)).ToList();
        foreach (var id in ids)
        {
            Assert.Equal(expected.Contains(id), history.Contains(id));
        }

        var drained = new List<Guid>();
        while (history.PopLast() is { } id) drained.Add(id);
        drained.Reverse();
        Assert.Equal(expected, drained);
    }

    [Fact]
    public void TestContainsIsConstantTimeNotLinear()
    {
        var history = new ShuffleHistory();
        var ids = Enumerable.Range(0, 5000).Select(_ => Guid.NewGuid()).ToList();
        foreach (var id in ids) history.Append(id);

        var found = false;
        foreach (var id in ids)
        {
            if (history.Contains(id)) found = true;
        }

        Assert.True(found);
        Assert.True(history.Contains(ids[4999]));
    }
}
