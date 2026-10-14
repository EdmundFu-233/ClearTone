#include "App/MediaSessionIntegration.h"

#include "Playback/PlayerController.h"

#include <QCoreApplication>
#include <QMetaObject>
#include <QWidget>
#include <utility>
#ifdef Q_OS_WIN
#include <windows.h>
#endif

namespace ct {

MediaSessionIntegration& MediaSessionIntegration::shared()
{
    static MediaSessionIntegration* instance = new MediaSessionIntegration();
    return *instance;
}

MediaSessionIntegration::~MediaSessionIntegration()
{
#ifdef Q_OS_WIN
    for (int id : std::as_const(m_registeredHotkeys)) UnregisterHotKey(nullptr, id);
    if (m_initialized && QCoreApplication::instance())
        QCoreApplication::instance()->removeNativeEventFilter(this);
#endif
}

void MediaSessionIntegration::initialize(QWidget* window)
{
    m_window = window;
#ifdef Q_OS_WIN
    if (m_initialized) return;
    m_initialized = true;

    // MinGW does not ship C++/WinRT SMTC headers. Register the standard media
    // keys while ClearTone has a song, with WM_APPCOMMAND as a foreground fallback.
    QCoreApplication::instance()->installNativeEventFilter(this);
    PlayerController& player = PlayerController::shared();
    m_songSub = player.onSongChanged.subscribe([this] { onPlayerSongChanged(); updateMediaHotkeys(); });
    m_stateSub = player.onStateChanged.subscribe([this] { onPlayerStateChanged(); });
    m_durationSub = player.onDurationChanged.subscribe([this] { updateTimeline(); });
    m_timeSub = player.timeUpdated.subscribe([this](double seconds) { onPlayerTimeUpdated(seconds); });

    refreshMetadata();
    updatePlaybackStatus();
    updateTimeline();
    updateMediaHotkeys();
#endif
}

void MediaSessionIntegration::updateMediaHotkeys()
{
#ifdef Q_OS_WIN
    const bool hasSong = PlayerController::shared().currentSong().has_value();
    constexpr int firstId = 0x4354;
    const UINT keys[] = {VK_MEDIA_PLAY_PAUSE, VK_MEDIA_NEXT_TRACK, VK_MEDIA_PREV_TRACK, VK_MEDIA_STOP};
    for (int i = 0; i < 4; ++i) {
        const int id = firstId + i;
        if (hasSong && !m_registeredHotkeys.contains(id)) {
            if (RegisterHotKey(nullptr, id, MOD_NOREPEAT, keys[i])) m_registeredHotkeys.insert(id);
        } else if (!hasSong && m_registeredHotkeys.remove(id)) {
            UnregisterHotKey(nullptr, id);
        }
    }
    m_active = hasSong;
#endif
}

bool MediaSessionIntegration::nativeEventFilter(const QByteArray& eventType, void* message, qintptr* result)
{
#ifdef Q_OS_WIN
    auto* msg = static_cast<MSG*>(message);
    int command = 0;
    if (eventType == QByteArrayLiteral("windows_dispatcher_MSG") && msg->message == WM_HOTKEY
        && m_registeredHotkeys.contains(static_cast<int>(msg->wParam))) {
        command = static_cast<int>(msg->wParam) - 0x4354 + 1;
    } else if (eventType == QByteArrayLiteral("windows_generic_MSG") && msg->message == WM_APPCOMMAND
        && m_window && GetAncestor(msg->hwnd, GA_ROOT) == reinterpret_cast<HWND>(m_window->winId())) {
        switch (GET_APPCOMMAND_LPARAM(msg->lParam)) {
        case APPCOMMAND_MEDIA_PLAY_PAUSE: command = 1; break;
        case APPCOMMAND_MEDIA_NEXTTRACK: command = 2; break;
        case APPCOMMAND_MEDIA_PREVIOUSTRACK: command = 3; break;
        case APPCOMMAND_MEDIA_STOP: command = 4; break;
        case APPCOMMAND_MEDIA_PLAY: command = 5; break;
        case APPCOMMAND_MEDIA_PAUSE: command = 6; break;
        default: break;
        }
    }
    if (command && PlayerController::shared().currentSong()) {
        PlayerController& player = PlayerController::shared();
        switch (command) {
        case 1: player.togglePlayPause(); break;
        case 2: player.next(); break;
        case 3: player.previous(); break;
        case 4: case 6: player.pause(); break;
        case 5: player.resume(); break;
        }
        *result = 0;
        return true;
    }
#else
    Q_UNUSED(eventType);
    Q_UNUSED(message);
    Q_UNUSED(result);
#endif
    return false;
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
