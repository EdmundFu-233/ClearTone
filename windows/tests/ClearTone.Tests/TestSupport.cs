using ClearTone.Core.Search;
using Xunit.Sdk;

namespace ClearTone.Tests;

public sealed class TestGate
{
    private readonly TaskCompletionSource _source = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public Task WaitAsync() => _source.Task;

    public void Open() => _source.TrySetResult();
}

public static class TestPolling
{
    public static async Task UntilAsync(Func<bool> condition, string message, int timeoutMs = 5000)
    {
        var deadline = Environment.TickCount64 + timeoutMs;
        while (!condition())
        {
            if (Environment.TickCount64 > deadline) throw new XunitException(message);
            await Task.Delay(10).ConfigureAwait(false);
        }
    }
}

public sealed class InMemorySearchAssistPersistence : ISearchAssistPersistence
{
    public List<string> StoredHistory { get; set; } = new();

    public int SaveCount { get; private set; }

    public List<string> LoadHistory() => new(StoredHistory);

    public void SaveHistory(List<string> history)
    {
        StoredHistory = new List<string>(history);
        SaveCount += 1;
    }
}
