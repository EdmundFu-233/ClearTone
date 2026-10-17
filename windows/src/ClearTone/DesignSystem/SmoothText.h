#pragma once

#include <QFont>
#include <QHash>
#include <QImage>
#include <QPainter>

namespace ct::ui {

inline void drawSmoothText(QPainter* painter, const QRect& bounds, const QString& text,
    const QFont& font, const QColor& color, Qt::Alignment alignment = Qt::AlignVCenter | Qt::AlignLeft)
{
    if (!painter || bounds.isEmpty() || text.isEmpty()) return;
    if (bounds.width() > 640 || bounds.height() > 96) {
        painter->save();
        painter->setRenderHint(QPainter::TextAntialiasing, true);
        painter->setFont(font);
        painter->setPen(color);
        painter->drawText(bounds, static_cast<int>(alignment | Qt::TextSingleLine), text);
        painter->restore();
        return;
    }

    constexpr int scale = 2;
    const qreal dpr = painter->device() ? painter->device()->devicePixelRatioF() : 1.0;
    const qreal totalScale = dpr * scale;
    const QSize pixelSize(qMax(1, qRound(bounds.width() * totalScale)),
        qMax(1, qRound(bounds.height() * totalScale)));

    const QString cacheKey = QStringLiteral("%1|%2x%3|%4|%5|%6|%7")
                                 .arg(text)
                                 .arg(pixelSize.width())
                                 .arg(pixelSize.height())
                                 .arg(font.pixelSize() > 0 ? font.pixelSize() : qRound(font.pointSizeF() * 10))
                                 .arg(static_cast<int>(font.weight()))
                                 .arg(color.rgba())
                                 .arg(static_cast<int>(alignment));

    static QHash<QString, QImage> glyphCache;
    auto it = glyphCache.constFind(cacheKey);
    if (it == glyphCache.constEnd()) {
        if (glyphCache.size() >= 128) glyphCache.clear();
        QImage buffer(pixelSize, QImage::Format_ARGB32_Premultiplied);
        buffer.fill(Qt::transparent);

        QFont scaledFont = font;
        if (font.pixelSize() > 0) {
            scaledFont.setPixelSize(font.pixelSize() * scale);
        } else {
            scaledFont.setPointSizeF(qMax(9.0, font.pointSizeF()) * scale);
        }
        scaledFont.setStyleStrategy(QFont::PreferAntialias);
        scaledFont.setHintingPreference(QFont::PreferNoHinting);

        QPainter bufPainter(&buffer);
        bufPainter.setRenderHint(QPainter::Antialiasing, true);
        bufPainter.setRenderHint(QPainter::TextAntialiasing, true);
        bufPainter.scale(dpr, dpr);
        bufPainter.setFont(scaledFont);
        bufPainter.setPen(color);
        const QRect scaledBounds(0, 0, bounds.width() * scale, bounds.height() * scale);
        bufPainter.drawText(scaledBounds, static_cast<int>(alignment | Qt::TextSingleLine), text);
        bufPainter.end();

        it = glyphCache.insert(cacheKey, std::move(buffer));
    }

    painter->save();
    painter->setRenderHint(QPainter::SmoothPixmapTransform, true);
    painter->drawImage(bounds, *it);
    painter->restore();
}

} // namespace ct::ui
