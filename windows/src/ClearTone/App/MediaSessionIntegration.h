#pragma once

#include <QDateTime>
#include <QAbstractNativeEventFilter>
#include <QPointer>
#include <QSet>
#include <QString>

#include <functional>

class QWidget;

namespace ct {

// Windows media keys (global hotkeys while a song is selected, plus foreground
// WM_APPCOMMAND); SMTC metadata/timeline remains unavailable with MinGW.
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

    QPointer<QWidget> m_window;
    bool m_active = false;
    QDateTime m_lastTimelineUpdate;

#ifdef Q_OS_WIN
    bool m_initialized = false;
    QString m_thumbnailSongID;
    int m_songSub = 0;
    int m_stateSub = 0;
    int m_durationSub = 0;
    int m_timeSub = 0;
    QSet<int> m_registeredHotkeys;
#endif
};

} // namespace ct
