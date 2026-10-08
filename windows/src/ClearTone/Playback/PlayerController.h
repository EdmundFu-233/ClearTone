#pragma once

#include "Core/Async.h"
#include "Core/Event.h"
#include "Core/Models/MusicModels.h"
#include "Core/Models/MusicProvider.h"
#include "Playback/AudioEngine.h"
#include "Playback/PlayQueue.h"
#include "Playback/PlaybackVolumePolicy.h"
#include "Playback/PlayingSourceInfo.h"
#include "Playback/SongQuality.h"

#include <QDateTime>
#include <QList>
#include <QString>
#include <QUuid>
#include <QUrl>

#include <functional>
#include <memory>
#include <optional>

namespace ct {

class PlayerController {
public:
    static PlayerController& shared();

    static const QList<float>& availableRates();
    static QString rateLabel(float rate);
    static float resolveRestoredPlaybackRate(float value);

    const PlaybackState& playbackState() const { return m_playbackState; }
    double duration() const { return m_duration; }
    float volume() const { return m_volume; }
    void setVolume(float value);
    bool isMuted() const { return m_isMuted; }
    void setMuted(bool value);
    PlayQueue& queue() { return m_queue; }
    const PlayQueue& queue() const { return m_queue; }
    const std::optional<Song>& currentSong() const { return m_currentSong; }
    const QList<Song>& recentlyPlayed() const { return m_recentlyPlayed; }
    QualityLevel preferredQuality() const { return m_preferredQuality; }
    QualityLevel requestedQuality() const { return m_requestedQuality; }
    bool isAccountVIP() const { return m_isAccountVIP; }
    const std::optional<AudioQuality>& actualQuality() const { return m_actualQuality; }
    bool isCurrentFromCache() const { return m_isCurrentFromCache; }
    const QList<SongQualityOverride>& songQualityOverrides() const { return m_songQualityOverrides; }
    float playbackRate() const { return m_playbackRate; }
    std::optional<QDateTime> sleepTimerEndDate() const { return m_sleepTimerEndDate; }
    double sleepTimerRemaining() const { return m_sleepTimerRemaining; }
    double currentTime() const { return m_currentTime; }
    double bufferedTime() const { return m_bufferedTime; }
    std::optional<PlayingSourceInfo> playingSource() const;
    bool isRateAdjusted() const;
    QString playbackRateLabel() const;
    bool currentSongUsesOverride() const;

    Event<> onStateChanged;
    Event<> onSongChanged;
    Event<> onQueueChanged;
    Event<> onPositionChanged;
    Event<double> timeUpdated;
    Event<> onDurationChanged;
    Event<> onVolumeChanged;
    Event<> onQualityChanged;
    Event<> onPlaybackRateChanged;
    Event<> onSleepTimerChanged;
    Event<> onRecentlyPlayedChanged;
    Event<const QString&, const QString&> onError;

    void setProvider(IMusicProvider* provider) { m_provider = provider; }
    IMusicProvider* provider() const { return m_provider; }
    void setEngine(std::unique_ptr<AudioEngine> engine);
    AudioEngine* engine() const { return m_engine.get(); }

    std::function<void(const QUrl&)> playbackStartOverride;

    void playSongs(const QList<Song>& songs, int startAt = 0);
    void playCurrent();
    void playSong(const Song& song);
    void pause();
    void resume();
    void resumeFromPersistence();
    void togglePlayPause();
    void next();
    void previous();
    void previewSeek(double time);
    void commitSeek(double time);
    void seek(double time);
    void seekBy(double seconds);
    void setPlayMode(PlayMode mode);
    void cyclePlayMode();
    void appendToQueue(const Song& song);
    void appendToQueue(const QList<Song>& songs);
    void insertNext(const Song& song);
    void insertNext(const QList<Song>& songs);
    void removeFromQueue(const QUuid& itemID);
    void clearQueue();
    void moveQueueItems(int fromIndex, int toIndex);
    void jumpTo(const QUuid& itemID);
    void setRequestedQuality(QualityLevel level);
    void setAccountIsVIP(bool value);
    void setQualityOverride(std::optional<QualityLevel> level, const QString& songID);
    std::optional<QualityLevel> qualityOverrideFor(const QString& songID) const;
    QualityLevel effectiveQualityFor(const QString& songID) const;
    void setPlaybackRate(float rate);
    void setSleepTimer(double minutes);
    void cancelSleepTimer();
    void persistNow();

    bool isLoadInFlight() const { return m_isLoadInFlight; }
    Task<void>* pendingLoadTask() { return m_pendingLoadTask ? &*m_pendingLoadTask : nullptr; }

    void raisePlayingForTesting();
    void raiseTimeChangedForTesting(double seconds);
    void raiseEndReachedForTesting();
    void raiseErrorForTesting();
    void raiseBufferingForTesting(float cache);

private:
    PlayerController();

    void recordHistory(const Song& song);
    void beginPlay(const Song& song, const std::optional<double>& restoreTime, bool autoplay);
    Task<void> loadAndPlay(Song song, quint64 generation, CancellationToken ct);
    Task<PlayableURL> resolvePlayable(const Song& song, CancellationToken ct);
    void onPlayableResolved(
        const PlayableURL& playable, const Song& song, quint64 generation, CancellationToken ct);
    void onPlayableFailed(
        const MusicException& error, const Song& song, quint64 generation, CancellationToken ct);
    void startPlayback(const QUrl& url, const Song& song, quint64 generation);
    void ensureEngine();
    void applyVolumeToPlayer();
    void detachCurrentMedia();
    void teardownPlayer();

    void onEnginePlaying(quint64 generation, const QString& songId);
    void onEnginePaused(quint64 generation, const QString& songId);
    void onEngineEndReached(quint64 generation, const QString& songId);
    void onEngineError(quint64 generation, const QString& songId);
    void onEngineTimeChanged(quint64 generation, double seconds);
    void onEngineLengthChanged(quint64 generation, double seconds);
    void onEngineBuffering(quint64 generation, const QString& songId, float cache);

    void handleTrackEnded();
    void handlePlayError(const MusicException& error, const Song& song);
    Task<void> autoAdvanceAfterFailure(Song song, quint64 generation, CancellationToken ct);
    Task<void> sleepTimerLoop(QDateTime end, CancellationToken ct);
    void cancelAutoAdvance();
    void retryAfterFailure();
    bool isPreparingPlayback() const;
    void beginRestoredPlayback(bool autoplay);
    void reloadCurrentSongForQualityChange();

    PersistedQueue makeSnapshot() const;
    void persistState();
    void persistProgressThrottled();
    bool loadPersistedState();
    void stopPlayback();
    void notifyQueueChanged();
    void updateNowPlayingInfo();
    void updateNowPlayingElapsedTime();
    void updateNowPlayingPlaybackState();

    void setPlaybackState(PlaybackState state);
    void setCurrentSong(std::optional<Song> song);
    void setDuration(double value);
    void setCurrentTime(double value);
    void setBufferedTime(double value);
    void setPreferredQuality(QualityLevel value);
    void setRequestedQualityValue(QualityLevel value);
    void setActualQuality(std::optional<AudioQuality> value);
    void setIsCurrentFromCache(bool value);
    void setPlaybackRateValue(float value);
    void setSleepTimerEndDate(std::optional<QDateTime> value);
    void setSleepTimerRemaining(double value);

    QList<SongQualityOverride> loadSongQualityOverrides();
    void saveSongQualityOverrides();

    static constexpr int maxConsecutiveFailures = 3;
    static constexpr int maxSongQualityOverrides = 200;
    static constexpr int progressSaveIntervalMs = 5000;
    static constexpr const char* songQualityOverridesKey = "songQualityOverrides";

    PlaybackState m_playbackState;
    double m_duration = 0;
    float m_volume = PlaybackVolumePolicy::defaultVolume();
    bool m_isMuted = false;
    std::optional<Song> m_currentSong;
    double m_currentTime = 0;
    double m_bufferedTime = 0;
    QualityLevel m_preferredQuality = songQualityPolicy::autoLevel;
    QualityLevel m_requestedQuality = songQualityPolicy::autoLevel;
    bool m_isAccountVIP = false;
    std::optional<AudioQuality> m_actualQuality;
    bool m_isCurrentFromCache = false;
    float m_playbackRate = 1.0f;
    std::optional<QDateTime> m_sleepTimerEndDate;
    double m_sleepTimerRemaining = 0;

    PlayQueue m_queue;
    QList<Song> m_recentlyPlayed;
    QList<SongQualityOverride> m_songQualityOverrides;

    IMusicProvider* m_provider = nullptr;
    std::unique_ptr<AudioEngine> m_engine;
    bool m_engineStarted = false;
    bool m_hasActiveMedia = false;

    quint64 m_generation = 0;
    int m_consecutiveFailures = 0;
    QString m_retrySongID;
    int m_sameSongRetries = 0;
    std::shared_ptr<CancellationTokenSource> m_loadCts;
    std::shared_ptr<CancellationTokenSource> m_autoAdvanceCts;
    std::shared_ptr<CancellationTokenSource> m_sleepTimerCts;
    quint64 m_seekToken = 0;
    bool m_isUserSeeking = false;
    bool m_isLoadInFlight = false;
    std::optional<double> m_pendingRestoreTime;
    std::optional<QUrl> m_pendingUrl;
    bool m_pendingAutoplay = true;
    QDateTime m_lastProgressSaveAt;
    std::optional<Task<void>> m_pendingLoadTask;
};

} // namespace ct
