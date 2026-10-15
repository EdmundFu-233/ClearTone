#pragma once

#include <QDateTime>
#include <QAbstractNativeEventFilter>
#include <QPointer>
#include <QSet>
#include <QString>

#include <functional>
#if defined(Q_OS_WIN) && defined(CT_HAS_SMTC)
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#endif

class QWidget;

namespace ct {

// Windows SMTC media session and a media-key fallback when the SDK/session is unavailable.
class MediaSessionIntegration : public QAbstractNativeEventFilter {
public:
    static MediaSessionIntegration& shared();
    ~MediaSessionIntegration() override;

    void initialize(QWidget* window);
    bool isActive() const { return m_active; }

    void refreshMetadata();
    void updatePlaybackStatus();
    void updateTimeline();
    bool nativeEventFilter(const QByteArray& eventType, void* message, qintptr* result) override;

private:
    MediaSessionIntegration() = default;

    void onPlayerSongChanged();
    void onPlayerStateChanged();
    void onPlayerTimeUpdated(double seconds);
    void post(std::function<void()> action);
    void updateMediaHotkeys();
    void handleMediaCommand(int command);

    QPointer<QWidget> m_window;
    bool m_active = false;
    QDateTime m_lastTimelineUpdate;

#ifdef Q_OS_WIN
    bool m_initialized = false;
    int m_songSub = 0;
    int m_stateSub = 0;
    int m_durationSub = 0;
    int m_timeSub = 0;
    QSet<int> m_registeredHotkeys;
#ifdef CT_HAS_SMTC
    winrt::Windows::Media::SystemMediaTransportControls m_controls{nullptr};
#endif
#endif
};

} // namespace ct
