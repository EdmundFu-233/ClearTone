namespace ClearTone.Playback;

public static class AudioCacheRetentionPolicy
{
    public static readonly TimeSpan MaxAge = TimeSpan.FromDays(7);

    public static bool IsExpired(DateTimeOffset cachedAt, DateTimeOffset now, TimeSpan maxAge)
    {
        var elapsed = now - cachedAt;
        if (elapsed < TimeSpan.Zero) return false;
        return elapsed >= maxAge;
    }

    public static bool IsExpired(DateTimeOffset cachedAt) =>
        IsExpired(cachedAt, DateTimeOffset.UtcNow, MaxAge);

    public static HashSet<string> ExpiredIDs(
        IReadOnlyDictionary<string, DateTimeOffset> cachedAtByID,
        DateTimeOffset now,
        TimeSpan maxAge)
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (id, cachedAt) in cachedAtByID)
        {
            if (IsExpired(cachedAt, now, maxAge)) result.Add(id);
        }
        return result;
    }

    public static HashSet<string> ExpiredIDs(IReadOnlyDictionary<string, DateTimeOffset> cachedAtByID) =>
        ExpiredIDs(cachedAtByID, DateTimeOffset.UtcNow, MaxAge);
}
