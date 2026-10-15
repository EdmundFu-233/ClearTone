#include "DesignSystem/SmoothMenuStyle.h"

#include "DesignSystem/SmoothText.h"

#include <QPainter>
#include <QStyleOptionMenuItem>

namespace ct::ui {

void SmoothMenuStyle::drawControl(ControlElement element, const QStyleOption* option,
    QPainter* painter, const QWidget* widget) const
{
    if (element != CE_MenuItem) {
        QProxyStyle::drawControl(element, option, painter, widget);
        return;
    }
    const auto* item = qstyleoption_cast<const QStyleOptionMenuItem*>(option);
    if (!item || item->menuItemType == QStyleOptionMenuItem::Separator) {
        QProxyStyle::drawControl(element, option, painter, widget);
        return;
    }
    QStyleOptionMenuItem background(*item);
    background.text.clear();
    QProxyStyle::drawControl(element, &background, painter, widget);
    const QStringList parts = item->text.split(QLatin1Char('\t'));
    const QString label = QString(parts.first()).replace(QStringLiteral("&&"), QStringLiteral("\x01"))
        .remove(QLatin1Char('&')).replace(QLatin1Char('\x01'), QLatin1Char('&'));
    const QColor color = item->palette.color(item->state.testFlag(State_Enabled)
            ? QPalette::Active : QPalette::Disabled,
        item->state.testFlag(State_Selected) ? QPalette::HighlightedText : QPalette::Text);
    const QRect inner = item->rect.adjusted(24, 0, -24, 0);
    drawSmoothText(painter, inner, label, item->font, color);
    if (parts.size() > 1)
        drawSmoothText(painter, inner, parts.last(), item->font, color,
            Qt::AlignVCenter | Qt::AlignRight);
}

} // namespace ct::ui
