#include "DesignSystem/CTTheme.h"

#include <QGuiApplication>
#include <QStyleHints>

#include <cmath>

namespace ct {

const QColor CTColors::ImmersiveBase = QColor(0x12, 0x12, 0x17);

const QColor CTColors::DarkBackground = QColor(QStringLiteral("#111216"));
const QColor CTColors::DarkPanel = QColor(QStringLiteral("#191B21"));
const QColor CTColors::DarkOverlay = QColor(QStringLiteral("#22252D"));
const QColor CTColors::DarkTextPrimary = QColor(QStringLiteral("#F4F4F6"));
const QColor CTColors::DarkTextSecondary = QColor(QStringLiteral("#A6ABB7"));
const QColor CTColors::DarkAccent = QColor(QStringLiteral("#EF6A67"));

const QColor CTColors::LightBackground = QColor(QStringLiteral("#F5F4F1"));
const QColor CTColors::LightPanel = QColor(QStringLiteral("#FFFFFF"));
const QColor CTColors::LightOverlay = QColor(QStringLiteral("#EEEEEC"));
const QColor CTColors::LightTextPrimary = QColor(QStringLiteral("#20232A"));
const QColor CTColors::LightTextSecondary = QColor(QStringLiteral("#626976"));
const QColor CTColors::LightAccent = QColor(QStringLiteral("#C84045"));

bool CTColors::isDark()
{
    if (QStyleHints* hints = QGuiApplication::styleHints()) {
        return hints->colorScheme() == Qt::ColorScheme::Dark;
    }
    return false;
}

QColor CTColors::background() { return isDark() ? DarkBackground : LightBackground; }
QColor CTColors::panel() { return isDark() ? DarkPanel : LightPanel; }
QColor CTColors::overlay() { return isDark() ? DarkOverlay : LightOverlay; }
QColor CTColors::textPrimary() { return isDark() ? DarkTextPrimary : LightTextPrimary; }
QColor CTColors::textSecondary() { return isDark() ? DarkTextSecondary : LightTextSecondary; }
QColor CTColors::accent() { return isDark() ? DarkAccent : LightAccent; }

QString CTFormatting::time(double seconds)
{
    if (!std::isfinite(seconds) || seconds < 0) seconds = 0;
    const int total = static_cast<int>(std::floor(seconds));
    int minutes = total / 60;
    const int secs = total % 60;
    if (minutes >= 60) {
        const int hours = minutes / 60;
        minutes %= 60;
        return QStringLiteral("%1:%2:%3")
            .arg(hours)
            .arg(minutes, 2, 10, QLatin1Char('0'))
            .arg(secs, 2, 10, QLatin1Char('0'));
    }
    return QStringLiteral("%1:%2").arg(minutes).arg(secs, 2, 10, QLatin1Char('0'));
}

namespace {

QString oneDecimal(double value)
{
    QString text = QString::number(value, 'f', 1);
    if (text.endsWith(QLatin1String(".0"))) text.chop(2);
    return text;
}

} // namespace

QString CTFormatting::count(int value)
{
    if (value >= 100000000) return oneDecimal(value / 100000000.0) + QStringLiteral("亿");
    if (value >= 10000) return oneDecimal(value / 10000.0) + QStringLiteral("万");
    return QString::number(value);
}

} // namespace ct
