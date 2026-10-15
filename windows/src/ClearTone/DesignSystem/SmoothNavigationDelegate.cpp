#include "DesignSystem/SmoothNavigationDelegate.h"

#include "DesignSystem/SmoothText.h"

#include <QApplication>
#include <QPainter>
#include <QStyle>

namespace ct::ui {

void SmoothNavigationDelegate::paint(QPainter* painter, const QStyleOptionViewItem& option,
    const QModelIndex& index) const
{
    QStyleOptionViewItem background(option);
    initStyleOption(&background, index);
    const QString text = background.text;
    background.text.clear();
    const QStyle* style = background.widget ? background.widget->style() : QApplication::style();
    style->drawControl(QStyle::CE_ItemViewItem, &background, painter, background.widget);
    const QRect textRect = style->subElementRect(QStyle::SE_ItemViewItemText, &background, background.widget);
    const bool selected = option.state.testFlag(QStyle::State_Selected);
    const bool enabled = option.state.testFlag(QStyle::State_Enabled);
    const QPalette::ColorGroup group = enabled ? QPalette::Active : QPalette::Disabled;
    drawSmoothText(painter, textRect, text, option.font,
        option.palette.color(group, selected ? QPalette::HighlightedText : QPalette::Text));
}

} // namespace ct::ui
