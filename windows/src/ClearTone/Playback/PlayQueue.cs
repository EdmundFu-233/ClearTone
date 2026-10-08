using ClearTone.Core.Models;

namespace ClearTone.Playback;

public abstract record PlaybackState
{
    public abstract string? SongId { get; }

    public sealed record Idle : PlaybackState
    {
        public override string? SongId => null;
    }

    public sealed record Loading(string Id) : PlaybackState
    {
        public override string? SongId => Id;
    }

    public sealed record Playing(string Id) : PlaybackState
    {
        public override string? SongId => Id;
    }

    public sealed record Paused(string Id) : PlaybackState
    {
        public override string? SongId => Id;
    }

    public sealed record Buffering(string Id) : PlaybackState
    {
        public override string? SongId => Id;
    }

    public sealed record Ended(string Id) : PlaybackState
    {
        public override string? SongId => Id;
    }

    public sealed record Failed(string Id, string Reason) : PlaybackState
    {
        public override string? SongId => Id;
    }

    public bool IsPlaying => this is Playing;

    public bool IsPlayIntentActive => this is Playing or Buffering or Loading;

    public bool IsBuffering => this is Buffering;

    public bool IsLoading => this is Loading;
}

public enum PlayMode
{
    Sequential,
    LoopAll,
    LoopOne,
    Shuffle,
}

public static class PlayModeExtensions
{
    public static string DisplayName(this PlayMode mode) => mode switch
    {
        PlayMode.Sequential => "顺序播放",
        PlayMode.LoopAll => "列表循环",
        PlayMode.LoopOne => "单曲循环",
        _ => "随机播放",
    };

    public static string Glyph(this PlayMode mode) => mode switch
    {
        PlayMode.Sequential => "arrow.right",
        PlayMode.LoopAll => "repeat",
        PlayMode.LoopOne => "repeat.1",
        _ => "shuffle",
    };
}

public sealed class QueueItem : IEquatable<QueueItem>
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public Song Song { get; set; } = new();
    public DateTimeOffset AddedAt { get; set; } = DateTimeOffset.Now;

    public bool Equals(QueueItem? other) => other is not null && Id == other.Id;

    public override bool Equals(object? obj) => Equals(obj as QueueItem);

    public override int GetHashCode() => Id.GetHashCode();
}

internal sealed class ShuffleHistory
{
    private readonly List<Guid> _stack = new();
    private readonly HashSet<Guid> _set = new();

    public bool IsEmpty => _stack.Count == 0;
    public int Count => _stack.Count;

    public void Append(Guid id)
    {
        _stack.Add(id);
        _set.Add(id);
    }

    public Guid? PopLast()
    {
        if (_stack.Count == 0) return null;
        var id = _stack[^1];
        _stack.RemoveAt(_stack.Count - 1);
        if (!_stack.Contains(id)) _set.Remove(id);
        return id;
    }

    public bool Contains(Guid id) => _set.Contains(id);

    public void RemoveAll()
    {
        _stack.Clear();
        _set.Clear();
    }

    public void RemoveAllWhere(Func<Guid, bool> predicate)
    {
        _stack.RemoveAll(id => predicate(id));
        _set.Clear();
        foreach (var id in _stack) _set.Add(id);
    }
}

public sealed class PlayQueue
{
    public List<QueueItem> Items { get; private set; } = new();
    public int CurrentIndex { get; private set; } = -1;
    public PlayMode Mode { get; set; } = PlayMode.Sequential;

    private readonly ShuffleHistory _shuffleHistory = new();

    public QueueItem? CurrentItem =>
        CurrentIndex >= 0 && CurrentIndex < Items.Count ? Items[CurrentIndex] : null;

    public bool IsEmpty => Items.Count == 0;
    public int Count => Items.Count;

    public bool HasNext
    {
        get
        {
            if (Items.Count == 0) return false;
            return Mode switch
            {
                PlayMode.LoopOne => true,
                PlayMode.LoopAll => true,
                PlayMode.Sequential => CurrentIndex < Items.Count - 1,
                _ => true,
            };
        }
    }

    public bool HasPrevious
    {
        get
        {
            if (Items.Count == 0) return false;
            return Mode switch
            {
                PlayMode.LoopOne => true,
                PlayMode.Shuffle => !_shuffleHistory.IsEmpty,
                _ => CurrentIndex > 0,
            };
        }
    }

    public void Replace(IReadOnlyList<Song> songs, int startAt = 0)
    {
        Items = songs.Select(song => new QueueItem { Song = song }).ToList();
        CurrentIndex = Items.Count == 0 ? -1 : Math.Max(0, Math.Min(startAt, Items.Count - 1));
        _shuffleHistory.RemoveAll();
    }

    public void Append(Song song)
    {
        Items.Add(new QueueItem { Song = song });
        if (CurrentIndex == -1) CurrentIndex = 0;
    }

    public void AppendRange(IReadOnlyList<Song> songs)
    {
        Items.AddRange(songs.Select(song => new QueueItem { Song = song }));
        if (CurrentIndex == -1 && Items.Count > 0) CurrentIndex = 0;
    }

    public void InsertNext(Song song)
    {
        var item = new QueueItem { Song = song };
        if (CurrentIndex == -1)
        {
            Items.Add(item);
            CurrentIndex = 0;
        }
        else
        {
            Items.Insert(CurrentIndex + 1, item);
        }
    }

    public bool Remove(Guid itemID)
    {
        var index = Items.FindIndex(item => item.Id == itemID);
        if (index < 0) return false;
        Items.RemoveAt(index);
        _shuffleHistory.RemoveAllWhere(id => id == itemID);
        if (index < CurrentIndex)
        {
            CurrentIndex -= 1;
        }
        else if (index == CurrentIndex && CurrentIndex >= Items.Count)
        {
            CurrentIndex = Items.Count - 1;
        }
        return true;
    }

    public void Clear()
    {
        Items.Clear();
        CurrentIndex = -1;
        _shuffleHistory.RemoveAll();
    }

    public void Move(int fromIndex, int toIndex)
    {
        if (fromIndex < 0 || fromIndex >= Items.Count) return;
        if (toIndex < 0) return;
        if (toIndex >= Items.Count) toIndex = Items.Count - 1;
        if (fromIndex == toIndex) return;

        var currentID = CurrentItem?.Id;
        var item = Items[fromIndex];
        Items.RemoveAt(fromIndex);
        Items.Insert(toIndex, item);
        if (currentID is { } id)
        {
            var newIndex = Items.FindIndex(candidate => candidate.Id == id);
            if (newIndex >= 0) CurrentIndex = newIndex;
        }
    }

    public bool JumpTo(Guid itemID)
    {
        var index = Items.FindIndex(item => item.Id == itemID);
        if (index < 0) return false;
        if (Mode == PlayMode.Shuffle && CurrentItem is { } current)
        {
            _shuffleHistory.Append(current.Id);
        }
        CurrentIndex = index;
        return true;
    }

    public QueueItem? Next()
    {
        if (Items.Count == 0) return null;
        if (Mode == PlayMode.Shuffle && CurrentItem is { } current)
        {
            _shuffleHistory.Append(current.Id);
        }

        switch (Mode)
        {
            case PlayMode.LoopOne:
                return CurrentItem;
            case PlayMode.Sequential:
                if (CurrentIndex >= Items.Count - 1) return null;
                CurrentIndex += 1;
                return CurrentItem;
            case PlayMode.LoopAll:
                CurrentIndex = (CurrentIndex + 1) % Items.Count;
                return CurrentItem;
            default:
                var remaining = Enumerable.Range(0, Items.Count)
                    .Where(index => index != CurrentIndex && !_shuffleHistory.Contains(Items[index].Id))
                    .ToList();
                if (remaining.Count > 0)
                {
                    CurrentIndex = remaining[Random.Shared.Next(remaining.Count)];
                }
                else
                {
                    _shuffleHistory.RemoveAll();
                    var candidates = Enumerable.Range(0, Items.Count).Where(index => index != CurrentIndex).ToList();
                    if (candidates.Count == 0) return CurrentItem;
                    CurrentIndex = candidates[Random.Shared.Next(candidates.Count)];
                }
                return CurrentItem;
        }
    }

    public QueueItem? Previous()
    {
        if (Items.Count == 0) return null;

        switch (Mode)
        {
            case PlayMode.LoopOne:
                return CurrentItem;
            case PlayMode.Shuffle:
                if (_shuffleHistory.PopLast() is { } lastID)
                {
                    var index = Items.FindIndex(item => item.Id == lastID);
                    if (index >= 0)
                    {
                        CurrentIndex = index;
                        return CurrentItem;
                    }
                }
                return CurrentItem;
            default:
                if (CurrentIndex <= 0) return null;
                CurrentIndex -= 1;
                return CurrentItem;
        }
    }

    public QueueItem? HandleEnded()
    {
        if (Items.Count == 0) return null;
        switch (Mode)
        {
            case PlayMode.LoopOne:
                return CurrentItem;
            case PlayMode.Sequential:
                if (CurrentIndex >= Items.Count - 1) return null;
                CurrentIndex += 1;
                return CurrentItem;
            case PlayMode.LoopAll:
                CurrentIndex = (CurrentIndex + 1) % Items.Count;
                return CurrentItem;
            default:
                return Next();
        }
    }
}

public sealed class PersistedQueue
{
    public List<QueueItem> Items { get; set; } = new();
    public int CurrentIndex { get; set; } = -1;
    public PlayMode Mode { get; set; } = PlayMode.Sequential;
    public double CurrentTime { get; set; }
    public float Volume { get; set; }
    public bool IsMuted { get; set; }
    public QualityLevel RequestedQuality { get; set; } = QualityLevel.Unknown;
    public float PlaybackRate { get; set; } = 1.0f;

    public static PersistedQueue From(
        PlayQueue queue,
        double currentTime,
        float volume,
        bool isMuted,
        QualityLevel requestedQuality,
        float playbackRate)
    {
        return new PersistedQueue
        {
            Items = queue.Items.ToList(),
            CurrentIndex = queue.CurrentIndex,
            Mode = queue.Mode,
            CurrentTime = currentTime,
            Volume = volume,
            IsMuted = isMuted,
            RequestedQuality = requestedQuality,
            PlaybackRate = playbackRate,
        };
    }

    public PlayQueue ToPlayQueue()
    {
        var queue = new PlayQueue { Mode = Mode };
        queue.Replace(Items.Select(item => item.Song).ToList(), 0);
        for (var i = 0; i < Items.Count && i < queue.Items.Count; i++)
        {
            queue.Items[i].Id = Items[i].Id;
        }
        if (CurrentIndex >= 0 && CurrentIndex < queue.Items.Count)
        {
            queue.JumpTo(queue.Items[CurrentIndex].Id);
        }
        return queue;
    }
}
