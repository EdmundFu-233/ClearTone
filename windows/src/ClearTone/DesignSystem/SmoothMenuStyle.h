#pragma once

#include <QProxyStyle>

namespace ct::ui {

class SmoothMenuStyle : public QProxyStyle {
public:
    explicit SmoothMenuStyle(QStyle* base) : QProxyStyle(base) {}
    void drawControl(ControlElement element, const QStyleOption* option, QPainter* painter,
        const QWidget* widget = nullptr) const override;
    void drawItemText(QPainter* painter, const QRect& rect, int flags, const QPalette& pal,
        bool enabled, const QString& text,
        QPalette::ColorRole textRole = QPalette::NoRole) const override;
};

} // namespace ct::ui
