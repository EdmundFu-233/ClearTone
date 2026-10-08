#include "App/CloseBehaviorPolicy.h"

namespace ct {

bool CloseBehaviorPolicy::shouldQuitOnClose(const AppSettings& settings)
{
    return settings.closeBehavior == CloseBehavior::Quit;
}

bool CloseBehaviorPolicy::trayIconShouldBeVisible(const AppSettings& settings, bool hasVisibleWindows)
{
    if (settings.menuBarAlwaysVisible) return true;
    return settings.closeBehavior != CloseBehavior::Quit && !hasVisibleWindows;
}

} // namespace ct
