#pragma once

#include <QColor>
#include <QWidget>

class QPainter;
class QTimer;

namespace ct {

class AmbientBackground : public QWidget {
    Q_OBJECT

public:
    explicit AmbientBackground(QWidget* parent = nullptr);

    void reloadAnimationPolicy();

protected:
    void paintEvent(QPaintEvent* event) override;
    void showEvent(QShowEvent* event) override;
    void hideEvent(QHideEvent* event) override;

private:
    void drawBlob(QPainter& painter, const QColor& color, double cx, double cy, double radius) const;

    QTimer* m_timer = nullptr;
    double m_t = 0;
    bool m_animated = true;
};

} // namespace ct
