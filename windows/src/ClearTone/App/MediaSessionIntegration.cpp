#include "App/MediaSessionIntegration.h"

#include "Playback/PlayerController.h"
#include "Core/Logging/CTLog.h"

#include <QCoreApplication>
#include <QMetaObject>
#include <QWidget>
#include <utility>
#ifdef Q_OS_WIN
#include <windows.h>
#ifdef CT_HAS_SMTC
#include <roapi.h>
#include <systemmediatransportcontrolsinterop.h>
#endif
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

    // Prefer a real Windows media session: media keys are routed to the active
    // player, even when another app already owns the global VK_MEDIA_* hotkeys.
#ifdef CT_HAS_SMTC
    try {
        winrt::init_apartment(winrt::apartment_type::single_threaded);
        const winrt::hstring name(L"Windows.Media.SystemMediaTransportControls");
        ISystemMediaTransportControlsInterop* interop = nullptr;
        const HRESULT factory = RoGetActivationFactory(reinterpret_cast<HSTRING>(winrt::get_abi(name)),
            __uuidof(ISystemMediaTransportControlsInterop), reinterpret_cast<void**>(&interop));
        if (SUCCEEDED(factory)) {
            void* raw = nullptr;
            const HRESULT session = interop->GetForWindow(reinterpret_cast<HWND>(window->winId()),
                winrt::guid_of<winrt::Windows::Media::SystemMediaTransportControls>(), &raw);
            interop->Release();
            if (SUCCEEDED(session)) {
                m_controls = {raw, winrt::take_ownership_from_abi};
                m_controls.IsPlayEnabled(true);
                m_controls.IsPauseEnabled(true);
                m_controls.IsNextEnabled(true);
                m_controls.IsPreviousEnabled(true);
                m_controls.IsStopEnabled(true);
                m_controls.ButtonPressed([this](auto const&, auto const& args) {
                    const auto button = args.Button();
                    post([this, button] {
                        using winrt::Windows::Media::SystemMediaTransportControlsButton;
                        switch (button) {
                        case SystemMediaTransportControlsButton::Play: handleMediaCommand(5); break;
                        case SystemMediaTransportControlsButton::Pause: handleMediaCommand(6); break;
                        case SystemMediaTransportControlsButton::Next: handleMediaCommand(2); break;
                        case SystemMediaTransportControlsButton::Previous: handleMediaCommand(3); break;
                        case SystemMediaTransportControlsButton::Stop: handleMediaCommand(4); break;
                        default: break;
                        }
                    });
                });
                CTLog::general().info(QStringLiteral("Windows 媒体会话已接入"));
            }
        }
    } catch (const winrt::hresult_error&) {
        CTLog::general().warn(QStringLiteral("Windows 媒体会话不可用，回退到媒体快捷键"));
    }
#endif
    QCoreApplication::instance()->installNativeEventFilter(this);
    PlayerController& player = PlayerController::shared();
    m_songSub = player.onSongChanged.subscribe([this] { updateMediaHotkeys(); onPlayerSongChanged(); });
    m_stateSub = player.onStateChanged.subscribe([this] { onPlayerStateChanged(); });
    m_durationSub = player.onDurationChanged.subscribe([this] { updateTimeline(); });
    m_timeSub = player.timeUpdated.subscribe([this](double seconds) { onPlayerTimeUpdated(seconds); });

    updateMediaHotkeys();
    refreshMetadata();
    updatePlaybackStatus();
    updateTimeline();
#endif
}

void MediaSessionIntegration::updateMediaHotkeys()
{
#ifdef Q_OS_WIN
    const bool hasSong = PlayerController::shared().currentSong().has_value();
#ifdef CT_HAS_SMTC
    if (m_controls) {
        try {
            m_controls.IsEnabled(hasSong);
            m_active = hasSong;
            return;
        } catch (const winrt::hresult_error&) {
            CTLog::general().warn(QStringLiteral("Windows 媒体会话已失效，回退到媒体快捷键"));
            m_controls = nullptr;
        }
    }
#endif
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
        handleMediaCommand(command);
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

void MediaSessionIntegration::handleMediaCommand(int command)
{
    if (!PlayerController::shared().currentSong()) return;
    PlayerController& player = PlayerController::shared();
    switch (command) {
    case 1: player.togglePlayPause(); break;
    case 2: player.next(); break;
    case 3: player.previous(); break;
    case 4: case 6: player.pause(); break;
    case 5: player.resume(); break;
    }
}

void MediaSessionIntegration::refreshMetadata()
{
#ifdef Q_OS_WIN
#ifdef CT_HAS_SMTC
    if (!m_controls || !m_active) return;
    const auto& song = PlayerController::shared().currentSong();
    if (!song) return;
    try {
        auto display = m_controls.DisplayUpdater();
        display.Type(winrt::Windows::Media::MediaPlaybackType::Music);
        const auto properties = display.MusicProperties();
        properties.Title(winrt::hstring(song->title.toStdWString()));
        properties.Artist(winrt::hstring(song->artistNames().toStdWString()));
        properties.AlbumTitle(winrt::hstring(song->album ? song->album->name.toStdWString() : L""));
        display.Update();
    } catch (const winrt::hresult_error&) {}
#endif
#endif
}

void MediaSessionIntegration::updatePlaybackStatus()
{
#ifdef Q_OS_WIN
#ifdef CT_HAS_SMTC
    if (!m_controls || !m_active) return;
    using winrt::Windows::Media::MediaPlaybackStatus;
    const auto state = PlayerController::shared().playbackState();
    try {
        m_controls.PlaybackStatus(state.isPlaying() || state.isPlayIntentActive()
            ? MediaPlaybackStatus::Playing : MediaPlaybackStatus::Paused);
    } catch (const winrt::hresult_error&) {}
#endif
#endif
}

void MediaSessionIntegration::updateTimeline()
{
#ifdef Q_OS_WIN
#ifdef CT_HAS_SMTC
    if (!m_controls || !m_active) return;
    const PlayerController& player = PlayerController::shared();
    try {
        winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties timeline;
        timeline.StartTime(std::chrono::milliseconds(0));
        timeline.EndTime(std::chrono::milliseconds(qMax<qint64>(0, qRound64(player.duration() * 1000))));
        timeline.Position(std::chrono::milliseconds(qMax<qint64>(0, qRound64(player.currentTime() * 1000))));
        m_controls.UpdateTimelineProperties(timeline);
    } catch (const winrt::hresult_error&) {}
#endif
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
