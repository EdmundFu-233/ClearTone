#include "App/CloseBehaviorPolicy.h"

namespace ct {

bool CloseBehaviorPolicy::shouldQuitOnClose(const AppSettings& settings)
{
    return settings.closeBehavior == CloseBehavior::Quit;
}

bool CloseBehaviorPolicy::trayIconShouldBeVisible(const AppSettings& settings, bool hasVisibleWindows)
{
    if (settings.menuBarAlwaysVisible) return true;
    if (settings.closeBehavior != CloseBehavior::Quit) return true;
    return hasVisibleWindows;
}

} // namespace ct
