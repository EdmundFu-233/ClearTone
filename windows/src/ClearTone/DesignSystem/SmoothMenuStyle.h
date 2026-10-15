#pragma once

#include <QProxyStyle>

namespace ct::ui {

class SmoothMenuStyle : public QProxyStyle {
public:
    explicit SmoothMenuStyle(QStyle* base) : QProxyStyle(base) {}
    void drawControl(ControlElement element, const QStyleOption* option, QPainter* painter,
        const QWidget* widget = nullptr) const override;
};

} // namespace ct::ui
