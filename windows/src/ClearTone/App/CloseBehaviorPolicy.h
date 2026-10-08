#pragma once

#include "Core/Persistence/AppSettings.h"

namespace ct {

class CloseBehaviorPolicy {
public:
    static bool shouldQuitOnClose(const AppSettings& settings);

    static bool trayIconShouldBeVisible(const AppSettings& settings, bool hasVisibleWindows);
};

} // namespace ct
