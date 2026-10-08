using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Platform;
using ClearTone.Core.Persistence;
using ClearTone.Playback;

namespace ClearTone.Shell;

public static class TrayIconManager
{
    private static TrayIcon? _tray;
    private static Window? _mainWindow;

    public static void Initialize(Window mainWindow)
    {
        if (_tray is not null) return;
        _mainWindow = mainWindow;

        var tray = new TrayIcon
        {
            Icon = new WindowIcon(AssetLoader.Open(new Uri("avares://ClearTone/Assets/trayicon.png"))),
            ToolTipText = "澄音 ClearTone",
            IsVisible = false,
        };

        var showWindow = new NativeMenuItem { Header = "显示主窗口" };
        showWindow.Click += (_, _) => ShowMainWindow();

        var miniPlayer = new NativeMenuItem { Header = "迷你播放器" };
        miniPlayer.Click += (_, _) => MiniPlayerWindow.Toggle();

        var playPause = new NativeMenuItem { Header = "播放·暂停" };
        playPause.Click += (_, _) => PlayerController.Shared.TogglePlayPause();

        var previous = new NativeMenuItem { Header = "上一首" };
        previous.Click += (_, _) => PlayerController.Shared.Previous();

        var next = new NativeMenuItem { Header = "下一首" };
        next.Click += (_, _) => PlayerController.Shared.Next();

        var settings = new NativeMenuItem { Header = "设置" };
        settings.Click += (_, _) =>
        {
            AppState.Shared.SwitchToTopLevel(Page.Settings);
            ShowMainWindow();
        };

        var quit = new NativeMenuItem { Header = "退出应用" };
        quit.Click += (_, _) =>
            (Application.Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.Shutdown();

        var menu = new NativeMenu();
        menu.Items.Add(showWindow);
        menu.Items.Add(miniPlayer);
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(playPause);
        menu.Items.Add(previous);
        menu.Items.Add(next);
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(settings);
        menu.Items.Add(quit);
        menu.Opening += (_, _) =>
        {
            playPause.Header = PlayerController.Shared.PlaybackState.IsPlayIntentActive ? "暂停" : "播放";
        };

        tray.Menu = menu;
        tray.Clicked += (_, _) => ShowMainWindow();

        TrayIcon.SetIcons(Application.Current!, new TrayIcons { tray });
        _tray = tray;
    }

    public static void ShowTray()
    {
        if (_tray is null) return;
        _tray.IsVisible = true;
    }

    public static void HideTray()
    {
        if (_tray is null) return;
        _tray.IsVisible = false;
    }

    public static void RefreshVisibility()
    {
        if (_tray is null) return;
        var settings = PersistenceStore.Shared.LoadSetting<AppSettings>("appSettings") ?? new AppSettings();
        if (CloseBehaviorPolicy.TrayIconShouldBeVisible(settings, HasVisibleWindows()))
        {
            ShowTray();
        }
        else
        {
            HideTray();
        }
    }

    private static void ShowMainWindow()
    {
        if (_mainWindow is null) return;
        _mainWindow.Show();
        _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
        RefreshVisibility();
    }

    private static bool HasVisibleWindows()
    {
        if (Application.Current?.ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime desktop) return false;
        foreach (var window in desktop.Windows)
        {
            if (window is MiniPlayerWindow) continue;
            if (window.IsVisible) return true;
        }
        return false;
    }
}
