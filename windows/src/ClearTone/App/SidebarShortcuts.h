#pragma once

#include <QChar>
#include <QList>

#include <optional>

namespace ct {

class SidebarShortcuts {
public:
    static const QList<QChar> DigitKeys;

    static std::optional<QChar> keyForIndex(int index);
};

} // namespace ct
