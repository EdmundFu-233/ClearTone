#include "App/MiniPlayerWindow.h"

#include "Core/Persistence/AppSettings.h"
#include "Core/Persistence/PersistenceStore.h"
#include "DesignSystem/CTTheme.h"
#include "DesignSystem/CoverImage.h"
#include "DesignSystem/L10n.h"
#include "Features/Shared/UIComponents.h"
#include "Playback/PlayerController.h"

#include <QCloseEvent>
#include <QFrame>
#include <QGridLayout>
#include <QGuiApplication>
#include <QHBoxLayout>
#include <QJsonObject>
#include <QJsonValue>
#include <QLabel>
#include <QMouseEvent>
#include <QPushButton>
#include <QScreen>
#include <QSlider>
#include <QVBoxLayout>
#include <QWindow>

#include <algorithm>
#include <cmath>

namespace ct {

namespace {

AppSettings loadAppSettings()
{
    const QJsonValue value = PersistenceStore::shared().loadSetting(QStringLiteral("appSettings"));
    if (value.isObject()) return AppSettings::fromJson(value.toObject());
    return AppSettings{};
}

QPushButton* makeGlyphButton(const QString& glyph, const QString& tip, double size)
{
    auto* button = new QPushButton(glyph);
    button->setFlat(true);
    button->setCursor(Qt::PointingHandCursor);
    button->setToolTip(tip);
    button->setFixedSize(32, 32);
    button->setStyleSheet(QStringLiteral(
        "QPushButton { background: transparent; border: none; color: %1; font-size: %2px;"
        " font-family: 'Segoe MDL2 Assets', 'Segoe Fluent Icons'; }"
        "QPushButton:hover { background: %3; border-radius: 6px; }")
                              .arg(CTColors::textPrimary().name())
                              .arg(size)
                              .arg(CTColors::overlay().name()));
    return button;
}

void setElidedText(QLabel* label, const QString& text, int width)
{
    label->setText(label->fontMetrics().elidedText(text, Qt::ElideRight, width));
}

} // namespace

MiniPlayerWindow* MiniPlayerWindow::s_instance = nullptr;

MiniPlayerWindow::MiniPlayerWindow(const AppSettings& settings)
    : QWidget(nullptr)
    , m_player(&PlayerController::shared())
{
    setWindowFlags(Qt::Tool | Qt::FramelessWindowHint);
    if (settings.miniPlayerAlwaysOnTop) setWindowFlag(Qt::WindowStaysOnTopHint, true);
    setAttribute(Qt::WA_TranslucentBackground);
    setFixedWidth(300);
    setWindowTitle(QStringLiteral("迷你播放器"));

    buildUi();

    PlayerController& player = *m_player;
    m_songSub = player.onSongChanged.subscribe([this] { refresh(); });
    m_stateSub = player.onStateChanged.subscribe([this] { refresh(); });
    m_queueSub = player.onQueueChanged.subscribe([this] { refresh(); });
    m_durationSub = player.onDurationChanged.subscribe([this] { updateProgress(); });
    m_timeSub = player.timeUpdated.subscribe([this](double) {
        if (!m_dragging) updateProgress();
    });

    refresh();
}

MiniPlayerWindow::~MiniPlayerWindow()
{
    m_player->onSongChanged.unsubscribe(m_songSub);
    m_player->onStateChanged.unsubscribe(m_stateSub);
    m_player->onQueueChanged.unsubscribe(m_queueSub);
    m_player->onDurationChanged.unsubscribe(m_durationSub);
    m_player->timeUpdated.unsubscribe(m_timeSub);
    if (s_instance == this) s_instance = nullptr;
}

void MiniPlayerWindow::toggle()
{
    if (s_instance != nullptr) {
        if (s_instance->isVisible()) {
            s_instance->hide();
            return;
        }
        s_instance->show();
        s_instance->raise();
        s_instance->activateWindow();
        return;
    }

    auto* window = new MiniPlayerWindow(loadAppSettings());
    s_instance = window;
    window->show();
    window->positionBottomRight();
    window->raise();
    window->activateWindow();
}

void MiniPlayerWindow::closeEvent(QCloseEvent* event)
{
    event->ignore();
    hide();
}

void MiniPlayerWindow::mousePressEvent(QMouseEvent* event)
{
    if (event->button() == Qt::LeftButton) {
        if (QWindow* handle = windowHandle()) {
            handle->startSystemMove();
            event->accept();
            return;
        }
    }
    QWidget::mousePressEvent(event);
}

void MiniPlayerWindow::buildUi()
{
    auto* surface = new QFrame(this);
    surface->setObjectName(QStringLiteral("miniSurface"));
    surface->setStyleSheet(QStringLiteral("#miniSurface { background: %1; border-radius: %2px;"
                                          " border: 1px solid %3; }")
                               .arg(CTColors::panel().name())
                               .arg(CTRadius::Medium)
                               .arg(CTColors::overlay().name()));

    auto* outer = new QVBoxLayout(this);
    outer->setContentsMargins(0, 0, 0, 0);
    outer->addWidget(surface);

    auto* root = new QVBoxLayout(surface);
    root->setContentsMargins(12, 12, 12, 12);
    root->setSpacing(CTSpacing::Sm);

    auto* info = new QWidget(surface);
    auto* infoLayout = new QGridLayout(info);
    infoLayout->setContentsMargins(0, 0, 0, 0);
    infoLayout->setSpacing(CTSpacing::Sm);

    m_cover = new CoverImage(info);
    m_cover->setFixedSize(48, 48);
    m_cover->setCornerRadius(CTRadius::Small);
    infoLayout->addWidget(m_cover, 0, 0);

    auto* text = new QWidget(info);
    auto* textLayout = new QVBoxLayout(text);
    textLayout->setContentsMargins(0, 0, 0, 0);
    textLayout->setSpacing(2);
    m_title = ui::titleLabel(QStringLiteral("未在播放"), CTTypography::Body, true);
    m_artist = ui::secondaryLabel(QString());
    textLayout->addWidget(m_title);
    textLayout->addWidget(m_artist);
    infoLayout->addWidget(text, 0, 1);

    auto* close = makeGlyphButton(QStringLiteral("\uE711"), QStringLiteral("隐藏迷你播放器"), 12);
    QObject::connect(close, &QPushButton::clicked, this, [this] { hide(); });
    infoLayout->addWidget(close, 0, 2);
    infoLayout->setColumnStretch(1, 1);

    root->addWidget(info);

    m_progress = new QSlider(Qt::Horizontal, surface);
    m_progress->setRange(0, 100);
    m_progress->setFixedHeight(3);
    m_progress->setStyleSheet(QStringLiteral(
        "QSlider { background: transparent; }"
        "QSlider::groove:horizontal { height: 3px; background: %1; border-radius: 1px; }"
        "QSlider::sub-page:horizontal { background: %2; border-radius: 1px; }"
        "QSlider::handle:horizontal { width: 9px; margin: -4px 0; background: %2; border-radius: 4px; }")
                                  .arg(CTColors::overlay().name(), CTColors::accent().name()));
    QObject::connect(m_progress, &QSlider::sliderPressed, this, &MiniPlayerWindow::onProgressPressed);
    QObject::connect(m_progress, &QSlider::sliderReleased, this, &MiniPlayerWindow::onProgressReleased);
    QObject::connect(
        m_progress, &QSlider::valueChanged, this, &MiniPlayerWindow::onProgressValueChanged);
    root->addWidget(m_progress);

    auto* controls = new QWidget(surface);
    auto* controlsLayout = new QHBoxLayout(controls);
    controlsLayout->setContentsMargins(0, 0, 0, 0);
    controlsLayout->setSpacing(CTSpacing::Xl);
    m_previous = makeGlyphButton(QStringLiteral("\uE892"), L10n::Common::Previous, 14);
    m_playPause = makeGlyphButton(QStringLiteral("\uE768"), QStringLiteral("播放/暂停"), 20);
    m_next = makeGlyphButton(QStringLiteral("\uE893"), L10n::Common::Next, 14);
    QObject::connect(m_previous, &QPushButton::clicked, this, [this] { m_player->previous(); });
    QObject::connect(m_playPause, &QPushButton::clicked, this, [this] { m_player->togglePlayPause(); });
    QObject::connect(m_next, &QPushButton::clicked, this, [this] { m_player->next(); });
    controlsLayout->addStretch(1);
    controlsLayout->addWidget(m_previous);
    controlsLayout->addWidget(m_playPause);
    controlsLayout->addWidget(m_next);
    controlsLayout->addStretch(1);
    root->addWidget(controls);
}

void MiniPlayerWindow::refresh()
{
    const auto& song = m_player->currentSong();
    setElidedText(m_title, song ? song->title : QStringLiteral("未在播放"), 170);
    setElidedText(m_artist, song ? song->artistNames() : QString(), 170);
    m_cover->setCoverURL(song ? song->coverURL : std::optional<QString>(), 96);
    m_playPause->setText(
        m_player->playbackState().isPlayIntentActive() ? QStringLiteral("\uE769")
                                                       : QStringLiteral("\uE768"));
    m_previous->setEnabled(m_player->queue().hasPrevious());
    m_next->setEnabled(m_player->queue().hasNext());
    updateProgress();
}

void MiniPlayerWindow::updateProgress()
{
    const double duration = m_player->duration();
    m_syncingProgress = true;
    if (duration > 0) {
        const double percent =
            std::clamp(m_player->currentTime() / duration * 100.0, 0.0, 100.0);
        m_progress->setValue(static_cast<int>(std::lround(percent)));
    } else {
        m_progress->setValue(0);
    }
    m_syncingProgress = false;
}

void MiniPlayerWindow::onProgressPressed() { m_dragging = true; }

void MiniPlayerWindow::onProgressReleased()
{
    if (!m_dragging) return;
    m_dragging = false;
    const double duration = m_player->duration();
    if (duration > 0) {
        m_player->commitSeek(m_progress->value() / 100.0 * duration);
    } else {
        updateProgress();
    }
}

void MiniPlayerWindow::onProgressValueChanged(int value)
{
    if (!m_dragging || m_syncingProgress) return;
    const double duration = m_player->duration();
    if (duration <= 0) return;
    m_player->previewSeek(value / 100.0 * duration);
}

void MiniPlayerWindow::positionBottomRight()
{
    adjustSize();
    const QScreen* screen = QGuiApplication::primaryScreen();
    if (screen == nullptr) return;
    const QRect area = screen->availableGeometry();
    const int margin = 12;
    move(qMax(area.left(), area.right() - width() - margin),
        qMax(area.top(), area.bottom() - height() - margin));
}

} // namespace ct
