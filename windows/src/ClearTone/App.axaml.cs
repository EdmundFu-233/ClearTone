using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Avalonia.Platform;
using ClearTone.Core.Networking;
using ClearTone.Playback;
using ClearTone.Shell;

namespace ClearTone;

public partial class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var mainWindow = new MainWindow
            {
                Icon = new WindowIcon(AssetLoader.Open(new Uri("avares://ClearTone/Assets/appicon.png"))),
            };
            desktop.MainWindow = mainWindow;
            desktop.ShutdownMode = ShutdownMode.OnMainWindowClose;
            TrayIconManager.Initialize(mainWindow);
            desktop.Exit += (_, _) =>
            {
                try
                {
                    PlayerController.Shared.PersistNowAsync().GetAwaiter().GetResult();
                }
                catch
                {
                }
                try
                {
                    HelperProcessManager.Shared.Stop();
                }
                catch
                {
                }
            };
        }
        base.OnFrameworkInitializationCompleted();
    }
}
