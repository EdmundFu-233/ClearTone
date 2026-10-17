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

void SmoothMenuStyle::drawItemText(QPainter* painter, const QRect& rect, int flags,
    const QPalette& pal, bool enabled, const QString& text, QPalette::ColorRole textRole) const
{
    if (!painter || text.isEmpty() || rect.isEmpty()) return;
    const QFont& font = painter->font();
    if (font.family().compare(QStringLiteral("lucide"), Qt::CaseInsensitive) == 0
        || (flags & Qt::TextWordWrap) != 0 || text.contains(QLatin1Char('\n'))) {
        QProxyStyle::drawItemText(painter, rect, flags, pal, enabled, text, textRole);
        return;
    }
    const QColor color = textRole != QPalette::NoRole
        ? pal.color(enabled ? QPalette::Active : QPalette::Disabled, textRole)
        : painter->pen().color();
    QString clean = text;
    if ((flags & (Qt::TextShowMnemonic | Qt::TextHideMnemonic)) != 0 && clean.contains(QLatin1Char('&'))) {
        clean = clean.replace(QStringLiteral("&&"), QStringLiteral("\x01"))
                    .remove(QLatin1Char('&'))
                    .replace(QLatin1Char('\x01'), QLatin1Char('&'));
    }
    Qt::Alignment align = static_cast<Qt::Alignment>(
        flags & (Qt::AlignHorizontal_Mask | Qt::AlignVertical_Mask));
    if ((align & Qt::AlignHorizontal_Mask) == 0) align |= Qt::AlignLeft;
    if ((align & Qt::AlignVertical_Mask) == 0) align |= Qt::AlignTop;
    drawSmoothText(painter, rect, clean, font, color, align);
}

} // namespace ct::ui
