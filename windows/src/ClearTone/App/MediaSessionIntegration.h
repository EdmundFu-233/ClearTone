#pragma once

#include <QDateTime>
#include <QString>

#include <functional>

class QWidget;

namespace ct {

// 系统媒体控制接入（对应 C# App/MediaSessionIntegration.cs）。
// Windows 上使用 SMTC；其它平台为 no-op。
class MediaSessionIntegration {
public:
    static MediaSessionIntegration& shared();

    void initialize(QWidget* window);
    bool isActive() const { return m_active; }

    void refreshMetadata();
    void updatePlaybackStatus();
    void updateTimeline();

private:
    MediaSessionIntegration() = default;

    void onPlayerSongChanged();
    void onPlayerStateChanged();
    void onPlayerTimeUpdated(double seconds);
    void post(std::function<void()> action);

    QWidget* m_window = nullptr;
    bool m_active = false;
    QDateTime m_lastTimelineUpdate;

#ifdef Q_OS_WIN
    bool m_initialized = false;
    QString m_thumbnailSongID;
    int m_songSub = 0;
    int m_stateSub = 0;
    int m_durationSub = 0;
    int m_timeSub = 0;
#endif
};

} // namespace ct
