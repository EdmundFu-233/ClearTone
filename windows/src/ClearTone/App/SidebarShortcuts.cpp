#include "App/SidebarShortcuts.h"

namespace ct {

const QList<QChar> SidebarShortcuts::DigitKeys = {
    QChar(QLatin1Char('1')),
    QChar(QLatin1Char('2')),
    QChar(QLatin1Char('3')),
    QChar(QLatin1Char('4')),
    QChar(QLatin1Char('5')),
    QChar(QLatin1Char('6')),
    QChar(QLatin1Char('7')),
    QChar(QLatin1Char('8')),
    QChar(QLatin1Char('9')),
    QChar(QLatin1Char('0')),
};

std::optional<QChar> SidebarShortcuts::keyForIndex(int index)
{
    if (index < 0 || index >= DigitKeys.size()) return std::nullopt;
    return DigitKeys.at(index);
}

} // namespace ct
