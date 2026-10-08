namespace ClearTone.Core.Persistence;

public static class StoragePaths
{
    public static string Root { get; } = ResolveRoot();

    private static string ResolveRoot()
    {
        var overrideDir = Environment.GetEnvironmentVariable("CLEARTONE_STORAGE_DIR")
            ?? Environment.GetEnvironmentVariable("CLEARTONE_TEST_STORAGE_DIR");
        if (!string.IsNullOrEmpty(overrideDir)) return overrideDir;
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "ClearTone");
    }
}
