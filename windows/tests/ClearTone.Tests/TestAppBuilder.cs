using Avalonia;
using Avalonia.Headless;
using ClearTone;

[assembly: AvaloniaTestApplication(typeof(ClearTone.Tests.TestAppBuilder))]

namespace ClearTone.Tests;

public class TestAppBuilder
{
    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>().UseHeadless(new AvaloniaHeadlessPlatformOptions());
}
