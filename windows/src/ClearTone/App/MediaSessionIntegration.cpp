#include "App/MediaSessionIntegration.h"

#include "Core/Logging/CTLog.h"
#include "Playback/PlayerController.h"

#include <QCoreApplication>
#include <QMetaObject>
#include <QWidget>

namespace ct {

MediaSessionIntegration& MediaSessionIntegration::shared()
{
    static MediaSessionIntegration* instance = new MediaSessionIntegration();
    return *instance;
}

void MediaSessionIntegration::initialize(QWidget* window)
{
    m_window = window;
#ifdef Q_OS_WIN
    if (m_initialized) return;
    m_initialized = true;

    // SMTC 需要 C++/WinRT 的 Windows.Media.SystemMediaTransportControls。当前不引入
    // winrt 头文件，这里只保留与 C# 等价的接入点与事件订阅，补齐实现时填入。
    PlayerController& player = PlayerController::shared();
    m_songSub = player.onSongChanged.subscribe([this] { onPlayerSongChanged(); });
    m_stateSub = player.onStateChanged.subscribe([this] { onPlayerStateChanged(); });
    m_durationSub = player.onDurationChanged.subscribe([this] { updateTimeline(); });
    m_timeSub = player.timeUpdated.subscribe([this](double seconds) { onPlayerTimeUpdated(seconds); });

    refreshMetadata();
    updatePlaybackStatus();
    updateTimeline();
    CTLog::general().debug(QStringLiteral("系统媒体控制（SMTC）实现位待接入 C++/WinRT，当前为空实现"));
#endif
}

void MediaSessionIntegration::refreshMetadata()
{
#ifdef Q_OS_WIN
    if (!m_active) return;
    // 待 C++/WinRT 接入：DisplayUpdater 标题/歌手/专辑与封面。
#endif
}

void MediaSessionIntegration::updatePlaybackStatus()
{
#ifdef Q_OS_WIN
    if (!m_active) return;
    // 待 C++/WinRT 接入：PlaybackStatus 映射。
#endif
}

void MediaSessionIntegration::updateTimeline()
{
#ifdef Q_OS_WIN
    if (!m_active) return;
    // 待 C++/WinRT 接入：UpdateTimelineProperties。
#endif
}

void MediaSessionIntegration::onPlayerSongChanged()
{
    refreshMetadata();
    updatePlaybackStatus();
    updateTimeline();
}

void MediaSessionIntegration::onPlayerStateChanged()
{
    updatePlaybackStatus();
    updateTimeline();
}

void MediaSessionIntegration::onPlayerTimeUpdated(double seconds)
{
    Q_UNUSED(seconds);
    const QDateTime now = QDateTime::currentDateTime();
    if (m_lastTimelineUpdate.isValid() && m_lastTimelineUpdate.msecsTo(now) < 3000) return;
    m_lastTimelineUpdate = now;
    updateTimeline();
}

void MediaSessionIntegration::post(std::function<void()> action)
{
    if (!action) return;
    if (QCoreApplication::instance() == nullptr) {
        action();
        return;
    }
    QMetaObject::invokeMethod(
        QCoreApplication::instance(), [action = std::move(action)] { action(); }, Qt::QueuedConnection);
}

} // namespace ct
