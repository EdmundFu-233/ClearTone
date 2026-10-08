using System.Runtime.CompilerServices;
using Xunit;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace ClearTone.Tests;

public static class TestStorage
{
    public static string Root { get; private set; } = "";

    [ModuleInitializer]
    internal static void Initialize()
    {
        var root = Path.Combine(Path.GetTempPath(), "cleartone-tests-" + Guid.NewGuid().ToString("N"));
        if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        Directory.CreateDirectory(root);
        Root = root;
        Environment.SetEnvironmentVariable("CLEARTONE_STORAGE_DIR", root);
        Environment.SetEnvironmentVariable("CLEARTONE_TEST_STORAGE_DIR", root);
        _ = ClearTone.Playback.PlayerController.Shared;
    }
}
