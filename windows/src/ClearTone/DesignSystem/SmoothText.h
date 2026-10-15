#pragma once

#include <QFontMetricsF>
#include <QPainter>
#include <QPainterPath>

namespace ct::ui {

// GDI text on Windows becomes visibly bitmap-like at small sizes. Draw the few
// dense navigation/menu labels from glyph outlines instead; the rest of the UI
// can keep the low-memory GDI font engine.
inline void drawSmoothText(QPainter* painter, const QRect& bounds, const QString& text,
    const QFont& font, const QColor& color, Qt::Alignment alignment = Qt::AlignVCenter | Qt::AlignLeft)
{
    if (bounds.isEmpty() || text.isEmpty()) return;
    const QFontMetricsF metrics(font);
    const qreal width = metrics.horizontalAdvance(text);
    const qreal x = alignment.testFlag(Qt::AlignRight) ? bounds.right() - width
        : alignment.testFlag(Qt::AlignHCenter) ? bounds.left() + (bounds.width() - width) / 2
        : bounds.left();
    const qreal y = bounds.top() + (bounds.height() - metrics.height()) / 2 + metrics.ascent();
    QPainterPath path;
    path.addText(QPointF(x, y), font, text);
    painter->save();
    painter->setClipRect(bounds);
    painter->setRenderHint(QPainter::Antialiasing);
    painter->setPen(Qt::NoPen);
    painter->setBrush(color);
    painter->drawPath(path);
    painter->restore();
}

} // namespace ct::ui
