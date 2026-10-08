#include "DesignSystem/AmbientBackground.h"

#include "Core/Persistence/AppSettings.h"
#include "Core/Persistence/PersistenceStore.h"
#include "DesignSystem/CTTheme.h"

#include <QJsonValue>
#include <QPainter>
#include <QRadialGradient>
#include <QTimer>

#include <cmath>

namespace ct {

namespace {

QColor ambientAccent() { return QColor(0xEF, 0x6A, 0x67); }
QColor ambientViolet() { return QColor(0x7A, 0x6A, 0xF0); }
QColor ambientTeal() { return QColor(0x3F, 0xB6, 0xC9); }

} // namespace

AmbientBackground::AmbientBackground(QWidget* parent)
    : QWidget(parent)
{
    setAttribute(Qt::WA_OpaquePaintEvent);
    setAutoFillBackground(false);

    m_timer = new QTimer(this);
    m_timer->setInterval(50);
    connect(m_timer, &QTimer::timeout, this, [this] {
        m_t += 0.02;
        update();
    });
    reloadAnimationPolicy();
}

void AmbientBackground::reloadAnimationPolicy()
{
    const QJsonValue stored = PersistenceStore::shared().loadSetting(QStringLiteral("appSettings"));
    const AppSettings settings =
        stored.isObject() ? AppSettings::fromJson(stored.toObject()) : AppSettings();
    m_animated = settings.spectrumMode != SpectrumMode::Off
        && settings.performanceMode != PerformanceMode::Static;
    if (m_animated && isVisible()) m_timer->start();
    else m_timer->stop();
}

void AmbientBackground::showEvent(QShowEvent* event)
{
    QWidget::showEvent(event);
    reloadAnimationPolicy();
}

void AmbientBackground::hideEvent(QHideEvent* event)
{
    m_timer->stop();
    QWidget::hideEvent(event);
}

void AmbientBackground::paintEvent(QPaintEvent* event)
{
    Q_UNUSED(event);
    const double w = width();
    const double h = height();
    if (w <= 1 || h <= 1) {
        QPainter painter(this);
        painter.fillRect(rect(), CTColors::ImmersiveBase);
        return;
    }

    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing, true);
    painter.fillRect(rect(), CTColors::ImmersiveBase);

    drawBlob(painter, ambientAccent(),
        w * (0.30 + 0.08 * std::sin(m_t * 0.53)),
        h * (0.28 + 0.06 * std::cos(m_t * 0.61)), w * 0.42);
    drawBlob(painter, ambientViolet(),
        w * (0.72 + 0.07 * std::cos(m_t * 0.47 + 1.7)),
        h * (0.36 + 0.07 * std::sin(m_t * 0.71 + 0.9)), w * 0.38);
    drawBlob(painter, ambientTeal(),
        w * (0.52 + 0.09 * std::sin(m_t * 0.39 + 3.1)),
        h * (0.74 + 0.06 * std::cos(m_t * 0.55 + 2.2)), w * 0.36);
}

void AmbientBackground::drawBlob(
    QPainter& painter, const QColor& color, double cx, double cy, double radius) const
{
    const QPointF center(cx, cy);

    QRadialGradient soft(center, radius);
    QColor softInner = color;
    softInner.setAlpha(56);
    QColor softOuter = color;
    softOuter.setAlpha(0);
    soft.setColorAt(0, softInner);
    soft.setColorAt(1, softOuter);
    painter.setBrush(soft);
    painter.setPen(Qt::NoPen);
    painter.drawEllipse(center, radius, radius);

    QRadialGradient core(center, radius * 0.55);
    QColor coreInner = color;
    coreInner.setAlpha(36);
    QColor coreOuter = color;
    coreOuter.setAlpha(0);
    core.setColorAt(0, coreInner);
    core.setColorAt(1, coreOuter);
    painter.setBrush(core);
    painter.drawEllipse(center, radius * 0.55, radius * 0.55);
}

} // namespace ct
