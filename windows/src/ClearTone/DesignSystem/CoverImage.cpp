#include "DesignSystem/CoverImage.h"

#include "DesignSystem/CoverImageLoader.h"
#include "DesignSystem/CTTheme.h"

#include <QPainter>
#include <QPainterPath>
#include <QPointer>

namespace ct {

CoverImage::CoverImage(QWidget* parent)
    : QWidget(parent)
{
    setAttribute(Qt::WA_OpaquePaintEvent, false);
}

void CoverImage::setCoverURL(const std::optional<QString>& url, int decodeWidth)
{
    const auto normalized = url && url->isEmpty() ? std::nullopt : url;
    m_decodeWidth = decodeWidth;
    if (m_url == normalized.value_or(QString()) && m_pixmap.isNull() == !normalized) {
        // 同一地址重复设置：只有占位状态才需要重新加载。
        if (m_pixmap.isNull() && normalized) refresh();
        if (!normalized && !m_pixmap.isNull()) clearCover();
        return;
    }
    if (!normalized) {
        clearCover();
        return;
    }
    m_url = *normalized;
    refresh();
}

void CoverImage::clearCover()
{
    if (m_cts) m_cts->cancel();
    m_generation += 1;
    m_url.clear();
    m_pixmap = QPixmap();
    update();
}

void CoverImage::setCornerRadius(double radius)
{
    if (qFuzzyCompare(m_cornerRadius, radius)) return;
    m_cornerRadius = radius;
    update();
}

void CoverImage::refresh()
{
    if (m_cts) m_cts->cancel();
    const int generation = ++m_generation;
    auto source = std::make_shared<CancellationTokenSource>();
    m_cts = source;
    const QString url = m_url;
    const int width = m_decodeWidth;
    QPointer<CoverImage> self(this);
    const auto token = source->token();
    detach(loadCover(self, url, width, generation, token));
}

Task<void> CoverImage::loadCover(
    QPointer<CoverImage> self, QString url, int width, int generation, CancellationToken token)
{
    const auto image = co_await CoverImageLoader::shared().load(url, width, token);
    if (!self) co_return;
    if (!image) co_return;
    self->applyImage(*image, generation);
}

void CoverImage::applyImage(const QImage& image, int generation)
{
    if (generation != m_generation) return;
    m_pixmap = QPixmap::fromImage(image);
    update();
}

void CoverImage::paintEvent(QPaintEvent* event)
{
    Q_UNUSED(event);
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing, true);

    const QRectF bounds = rect();
    QPainterPath clip;
    if (m_cornerRadius > 0) {
        clip.addRoundedRect(bounds, m_cornerRadius, m_cornerRadius);
        painter.setClipPath(clip);
    }

    painter.fillRect(bounds, QColor(128, 128, 128, 0x33));

    if (m_pixmap.isNull()) {
        painter.setPen(CTColors::textSecondary());
        QFont font = painter.font();
        font.setPointSizeF(qMax(10.0, qMin(bounds.width(), bounds.height()) / 4.0));
        painter.setFont(font);
        painter.drawText(bounds, Qt::AlignCenter, QStringLiteral("♪"));
        return;
    }

    const QSizeF target = bounds.size();
    const QSizeF source = m_pixmap.size();
    if (source.isEmpty()) return;
    const double scale = qMax(target.width() / source.width(), target.height() / source.height());
    const QSizeF scaled = source * scale;
    const QRectF sourceRect(QPointF((scaled.width() - target.width()) / scale / 2,
                                 (scaled.height() - target.height()) / scale / 2),
        QSizeF(target.width() / scale, target.height() / scale));
    painter.drawPixmap(bounds, m_pixmap, sourceRect);
}

} // namespace ct
