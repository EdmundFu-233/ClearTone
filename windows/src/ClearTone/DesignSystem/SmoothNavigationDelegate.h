#pragma once

#include <QStyledItemDelegate>

namespace ct::ui {

class SmoothNavigationDelegate : public QStyledItemDelegate {
public:
    using QStyledItemDelegate::QStyledItemDelegate;
    void paint(QPainter* painter, const QStyleOptionViewItem& option,
        const QModelIndex& index) const override;
};

} // namespace ct::ui
