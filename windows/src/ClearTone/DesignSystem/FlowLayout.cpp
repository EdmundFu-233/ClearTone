#include "DesignSystem/FlowLayout.h"
#include <QWidget>

namespace ct {

FlowLayout::FlowLayout(QWidget* parent, int spacing) : QLayout(parent)
{
    setContentsMargins(0, 0, 0, 0);
    setSpacing(spacing);
}

FlowLayout::~FlowLayout()
{
    while (auto* item = takeAt(0)) delete item;
}

void FlowLayout::addItem(QLayoutItem* item) { m_items.append(item); }
int FlowLayout::count() const { return m_items.size(); }
QLayoutItem* FlowLayout::itemAt(int index) const { return m_items.value(index); }
QLayoutItem* FlowLayout::takeAt(int index)
{
    return index >= 0 && index < m_items.size() ? m_items.takeAt(index) : nullptr;
}
Qt::Orientations FlowLayout::expandingDirections() const { return Qt::Horizontal; }
bool FlowLayout::hasHeightForWidth() const { return true; }
int FlowLayout::heightForWidth(int width) const { return arrange(QRect(0, 0, width, 0), true); }
QSize FlowLayout::sizeHint() const { return minimumSize(); }
QSize FlowLayout::minimumSize() const
{
    QSize size;
    for (auto* item : m_items) size = size.expandedTo(item->minimumSize());
    const auto margins = contentsMargins();
    return size + QSize(margins.left() + margins.right(), margins.top() + margins.bottom());
}
void FlowLayout::setGeometry(const QRect& rect)
{
    QLayout::setGeometry(rect);
    arrange(rect, false);
}
int FlowLayout::arrange(const QRect& rect, bool measure) const
{
    const auto margins = contentsMargins();
    const QRect area = rect.marginsRemoved(margins);
    bool fluid = !m_items.isEmpty();
    for (auto* item : m_items)
        fluid = fluid && item->widget() && item->widget()->property("ctFluidCard").toBool();
    const int columns = qMax(1, qMin(static_cast<int>(m_items.size()), (area.width() + spacing()) / (160 + spacing())));
    const int cellWidth = qMin(216, (area.width() - (columns - 1) * spacing()) / columns);
    int x = area.x(), y = area.y(), rowHeight = 0;
    for (auto* item : m_items) {
        if (item->isEmpty()) continue;
        QSize size = item->sizeHint();
        if (fluid) size.setWidth(cellWidth);
        size.setWidth(qMin(size.width(), qMax(0, area.width())));
        if (x > area.x() && x + size.width() > area.x() + area.width()) {
            x = area.x();
            y += rowHeight + spacing();
            rowHeight = 0;
        }
        if (item->hasHeightForWidth()) size.setHeight(item->heightForWidth(size.width()));
        if (!measure) item->setGeometry(QRect(QPoint(x, y), size));
        x += size.width() + spacing();
        rowHeight = qMax(rowHeight, size.height());
    }
    return y + rowHeight - rect.y() + margins.bottom();
}

}
