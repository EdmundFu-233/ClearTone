using ClearTone.Core.Persistence;

namespace ClearTone.Shell;

public static class CloseBehaviorPolicy
{
    public static bool ShouldQuitOnClose(AppSettings settings) =>
        settings.CloseBehavior == CloseBehavior.Quit;

    public static bool TrayIconShouldBeVisible(AppSettings settings, bool hasVisibleWindows)
    {
        if (settings.MenuBarAlwaysVisible) return true;
        return settings.CloseBehavior != CloseBehavior.Quit && !hasVisibleWindows;
    }
}
