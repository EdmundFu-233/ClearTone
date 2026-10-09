#include "Playback/PlayerController.h"

#include "Core/Logging/CTLog.h"
#include "Core/Models/JsonHelpers.h"
#include "Core/Models/ModelJson.h"
#include "Core/Persistence/AppSettings.h"
#include "Core/Persistence/PersistenceStore.h"
#include "Playback/AudioCacheManager.h"
#include "Providers/Netease/NeteaseProvider.h"

#include <QFileInfo>
#include <QJsonArray>
#include <QJsonObject>

#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

namespace ct {

namespace {

PlaybackState makeState(PlaybackState::Kind kind, const QString& songId = {}, const QString& reason = {})
{
    PlaybackState state;
    state.kind = kind;
    state.songId = songId;
    state.reason = reason;
    return state;
}

QUrl toUrl(const QString& raw)
{
    if (raw.isEmpty()) return QUrl();
    const QUrl parsed(raw);
    if (parsed.isValid() && !parsed.scheme().isEmpty()) return parsed;
    return QUrl::fromLocalFile(raw);
}

} // namespace

PlayerController& PlayerController::shared()
{
    static PlayerController instance;
    return instance;
}

const QList<float>& PlayerController::availableRates()
{
    static const QList<float> rates = {0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f};
    return rates;
}

QString PlayerController::rateLabel(float rate)
{
    if (std::abs(rate - 1.0f) > 0.01f) {
        const double rounded = std::round(static_cast<double>(rate) * 100.0) / 100.0;
        QString text = QString::number(rounded, 'f', 2);
        while (text.endsWith(QLatin1Char('0'))) text.chop(1);
        if (text.endsWith(QLatin1Char('.'))) text.chop(1);
        return text + QStringLiteral("×");
    }
    return QStringLiteral("1×");
}

float PlayerController::resolveRestoredPlaybackRate(float value)
{
    const QList<float>& rates = availableRates();
    for (const float rate : rates) {
        if (rate == value) return value;
    }
    float best = rates.first();
    double bestDistance = std::abs(static_cast<double>(best) - value);
    for (const float rate : rates) {
        const double distance = std::abs(static_cast<double>(rate) - value);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = rate;
        }
    }
    return best;
}

PlayerController::PlayerController()
{
    // 默认接入网易云（与 C# 版 `_provider = NeteaseProvider.Shared` 一致）；
    // AppState 构造时会用注入的 provider 覆盖。
    m_provider = &NeteaseProvider::shared();
    m_recentlyPlayed = PersistenceStore::shared().loadRecentSongs();
    m_songQualityOverrides = loadSongQualityOverrides();
    const bool restored = loadPersistedState();
    AppSettings settings;
    const QJsonValue rawSettings =
        PersistenceStore::shared().loadSetting(QStringLiteral("appSettings"));
    if (rawSettings.isObject()) settings = AppSettings::fromJson(rawSettings.toObject());
    setPreferredQuality(settings.preferredQuality);
    setRequestedQualityValue(songQualityPolicy::effectiveGlobalLevel(m_preferredQuality, m_isAccountVIP));
    if (restored && settings.resumePlaybackOnLaunch) {
        beginRestoredPlayback(false);
    }
}

// MARK: - 播放控制

void PlayerController::playSongs(const QList<Song>& songs, int startAt)
{
    if (songs.isEmpty()) {
        clearQueue();
        return;
    }
    m_queue.replace(songs, startAt);
    notifyQueueChanged();
    playCurrent();
}

void PlayerController::playCurrent()
{
    QueueItem* item = m_queue.currentItem();
    if (item == nullptr) return;
    playSong(item->song);
}

void PlayerController::playSong(const Song& song)
{
    m_consecutiveFailures = 0;
    m_sameSongRetries = 0;
    m_retrySongID = song.id;
    recordHistory(song);
    beginPlay(song, std::nullopt, true);
}

void PlayerController::recordHistory(const Song& song)
{
    QList<Song> history;
    history.reserve(m_recentlyPlayed.size() + 1);
    for (const Song& existing : std::as_const(m_recentlyPlayed)) {
        if (existing.id != song.id) history.append(existing);
    }
    history.prepend(song);
    while (history.size() > 100) history.removeLast();
    m_recentlyPlayed = history;
    PersistenceWriter::shared().scheduleRecent(history);
    if (onRecentlyPlayedChanged) onRecentlyPlayedChanged();
}

void PlayerController::beginPlay(const Song& song, const std::optional<double>& restoreTime, bool autoplay)
{
    m_generation += 1;
    const quint64 generation = m_generation;
    cancelAutoAdvance();
    if (m_loadCts) m_loadCts->cancel();
    m_loadCts = std::make_shared<CancellationTokenSource>();
    const CancellationToken ct = m_loadCts->token();
    if (m_retrySongID != song.id) {
        m_retrySongID = song.id;
        m_sameSongRetries = 0;
    }
    m_isUserSeeking = false;
    setActualQuality(std::nullopt);
    setIsCurrentFromCache(false);
    detachCurrentMedia();
    AudioCacheManager::shared().setCurrentCachedSong(std::nullopt);

    setPlaybackState(autoplay ? makeState(PlaybackState::Kind::Loading, song.id)
                              : makeState(PlaybackState::Kind::Paused, song.id));
    setCurrentSong(song);
    setDuration(song.duration);
    setCurrentTime(restoreTime.value_or(0));
    setBufferedTime(0);
    m_pendingRestoreTime = restoreTime;
    m_pendingAutoplay = autoplay;
    m_pendingUrl.reset();
    persistState();
    m_isLoadInFlight = true;
    m_pendingLoadTask.emplace(loadAndPlay(song, generation, ct));
    m_pendingLoadTask->start();
}

Task<void> PlayerController::loadAndPlay(Song song, quint64 generation, CancellationToken ct)
{
    try {
        const PlayableURL playable = co_await resolvePlayable(song, ct);
        onPlayableResolved(playable, song, generation, ct);
    } catch (const MusicException& error) {
        onPlayableFailed(error, song, generation, ct);
    } catch (const std::exception& error) {
        onPlayableFailed(MusicException::unknown(QString::fromUtf8(error.what())), song, generation, ct);
    }
}

Task<PlayableURL> PlayerController::resolvePlayable(const Song& song, CancellationToken ct)
{
    if (song.source == SongSource::Local) {
        if (!song.localFileURL || song.localFileURL->isEmpty()) throw MusicException::fileNotFound();
        const QUrl localUrl = toUrl(*song.localFileURL);
        if (!QFileInfo::exists(localUrl.toLocalFile())) throw MusicException::fileNotFound();
        PlayableURL playable;
        playable.url = localUrl.toString();
        AudioQuality quality;
        quality.level = QualityLevel::Unknown;
        quality.isActual = true;
        playable.quality = quality;
        co_return playable;
    }

    const std::optional<QualityLevel> overridden = qualityOverrideFor(song.id);
    const QualityLevel level = songQualityPolicy::effectiveLevel(overridden, m_requestedQuality);
    if (songQualityPolicy::useLocalCache(overridden.has_value())) {
        if (auto cached = AudioCacheManager::shared().cachedItem(song.id)) {
            AudioCacheManager::shared().setCurrentCachedSong(song.id);
            PlayableURL playable;
            playable.url = cached->url.toString();
            AudioQuality quality;
            quality.level = QualityLevel::Unknown;
            quality.bitrate = cached->bitrateKbps;
            quality.isActual = true;
            quality.codec = cached->formatName;
            playable.quality = quality;
            playable.isCached = true;
            co_return playable;
        }
    }

    if (m_provider == nullptr) throw MusicException::unknown(QStringLiteral("未设置音乐提供者"));
    PlayableURL remote = co_await m_provider->fetchPlayableURL(song.id, level, ct);
    if (!remote.quality.bitrate) {
        remote.quality.bitrate = songQualityPolicy::derivedBitrateKbps(remote.sizeBytes, song.duration);
    }
    if (songQualityPolicy::shouldWriteCache(overridden.has_value(), remote.isPreview)) {
        AudioCacheManager::shared().cacheInBackground(song.id, toUrl(remote.url), song.duration);
    }
    co_return remote;
}

void PlayerController::onPlayableResolved(
    const PlayableURL& playable, const Song& song, quint64 generation, CancellationToken ct)
{
    if (generation != m_generation || ct.isCancellationRequested()) return;
    if (m_playbackState.songId != song.id) return;
    m_isLoadInFlight = false;
    setActualQuality(playable.quality);
    setIsCurrentFromCache(playable.isCached);
    CTLog::playback().info(QStringLiteral("播放源: %1 id=%2 质量=%3")
                               .arg(playable.isCached ? QStringLiteral("缓存") : QStringLiteral("在线"), song.id,
                                   quality::displayName(playable.quality.level)));
    if (m_pendingAutoplay) {
        startPlayback(toUrl(playable.url), song, generation);
    } else {
        m_pendingUrl = toUrl(playable.url);
    }
}

void PlayerController::onPlayableFailed(
    const MusicException& error, const Song& song, quint64 generation, CancellationToken ct)
{
    if (generation == m_generation) m_isLoadInFlight = false;
    if (generation != m_generation || ct.isCancellationRequested()) return;
    handlePlayError(error, song);
}

void PlayerController::startPlayback(const QUrl& url, const Song& song, quint64 generation)
{
    detachCurrentMedia();
    if (playbackStartOverride) {
        setPlaybackState(makeState(PlaybackState::Kind::Loading, song.id));
        playbackStartOverride(url);
        return;
    }
    try {
        ensureEngine();
    } catch (const MusicException& error) {
        handlePlayError(MusicException::unknown(error.message()), song);
        return;
    }
    applyVolumeToPlayer();
    setPlaybackState(makeState(PlaybackState::Kind::Loading, song.id));

    const QString songId = song.id;
    AudioEngineCallbacks callbacks;
    callbacks.onPlaying = [this, generation, songId] { onEnginePlaying(generation, songId); };
    callbacks.onPaused = [this, generation, songId] { onEnginePaused(generation, songId); };
    callbacks.onEndReached = [this, generation, songId] { onEngineEndReached(generation, songId); };
    callbacks.onError = [this, generation, songId] { onEngineError(generation, songId); };
    callbacks.onTimeChanged = [this, generation](double seconds) { onEngineTimeChanged(generation, seconds); };
    callbacks.onDurationChanged = [this, generation](double seconds) {
        onEngineLengthChanged(generation, seconds);
    };
    callbacks.onBuffering = [this, generation, songId](float cache) {
        onEngineBuffering(generation, songId, cache);
    };

    try {
        m_engine->setMediaSource(url, std::move(callbacks));
    } catch (const MusicException& error) {
        handlePlayError(MusicException::unknown(error.message()), song);
        return;
    }
    m_hasActiveMedia = true;
    m_engine->play();
    m_engine->setRate(m_playbackRate);
}

void PlayerController::ensureEngine()
{
    if (m_engineStarted) return;
    if (!m_engine) m_engine = createDefaultAudioEngine();
    if (!m_engine) throw MusicException::unknown(QStringLiteral("无法初始化音频引擎"));
    m_engineStarted = true;
}

void PlayerController::detachCurrentMedia()
{
    if (m_engine && m_engineStarted) {
        try {
            m_engine->stop();
        } catch (...) {
        }
    }
    m_hasActiveMedia = false;
}

void PlayerController::teardownPlayer()
{
    detachCurrentMedia();
    m_engineStarted = false;
}

void PlayerController::applyVolumeToPlayer()
{
    if (!m_engine || !m_engineStarted) return;
    const PlaybackVolumePolicy::Output output = PlaybackVolumePolicy::resolve(m_volume, m_isMuted);
    m_engine->setVolume(output.volume);
    m_engine->setMuted(output.isMuted);
}

void PlayerController::setVolume(float value)
{
    if (m_volume == value) return;
    m_volume = value;
    applyVolumeToPlayer();
    if (onVolumeChanged) onVolumeChanged();
}

void PlayerController::setMuted(bool value)
{
    if (m_isMuted == value) return;
    m_isMuted = value;
    applyVolumeToPlayer();
    if (onVolumeChanged) onVolumeChanged();
}

void PlayerController::setEngine(std::unique_ptr<AudioEngine> engine)
{
    m_engine = std::move(engine);
    m_engineStarted = false;
    m_hasActiveMedia = false;
}

// MARK: - 引擎事件

void PlayerController::onEnginePlaying(quint64 generation, const QString& songId)
{
    if (generation != m_generation) return;
    if (m_playbackState.songId != songId) return;
    m_consecutiveFailures = 0;

    if (m_engine && m_engineStarted) {
        const double actual = m_engine->duration();
        if (std::isfinite(actual) && actual > 1 && std::abs(actual - m_duration) > 0.5) {
            CTLog::playback().info(QStringLiteral("时长校正: %1s → %2s")
                                       .arg(m_duration, 0, 'f', 0)
                                       .arg(actual, 0, 'f', 0));
            setDuration(actual);
        }
    }

    if (m_pendingRestoreTime && *m_pendingRestoreTime > 1 && m_duration > 0
        && *m_pendingRestoreTime < m_duration) {
        const double target = std::min(*m_pendingRestoreTime, std::max(m_duration - 0.5, 0.0));
        m_isUserSeeking = true;
        if (m_engine) m_engine->setPosition(target);
        m_isUserSeeking = false;
        setCurrentTime(*m_pendingRestoreTime);
        if (timeUpdated) timeUpdated(*m_pendingRestoreTime);
    }
    m_pendingRestoreTime.reset();

    setPlaybackState(m_pendingAutoplay ? makeState(PlaybackState::Kind::Playing, songId)
                                       : makeState(PlaybackState::Kind::Paused, songId));
    updateNowPlayingInfo();
}

void PlayerController::onEnginePaused(quint64 generation, const QString& songId)
{
    if (generation != m_generation) return;
    if (m_playbackState.songId != songId) return;
    if (m_playbackState.kind == PlaybackState::Kind::Failed) return;
    if (m_pendingAutoplay) return;
    setPlaybackState(makeState(PlaybackState::Kind::Paused, songId));
}

void PlayerController::onEngineEndReached(quint64 generation, const QString& songId)
{
    if (generation != m_generation) return;
    if (m_playbackState.songId != songId) return;
    setPlaybackState(makeState(PlaybackState::Kind::Ended, songId));
    handleTrackEnded();
}

void PlayerController::onEngineError(quint64 generation, const QString& songId)
{
    if (generation != m_generation) return;
    if (!m_currentSong || m_currentSong->id != songId) return;
    handlePlayError(MusicException::unknown(QStringLiteral("播放中断")), *m_currentSong);
}

void PlayerController::onEngineTimeChanged(quint64 generation, double seconds)
{
    if (generation != m_generation) return;
    if (m_isUserSeeking || !m_currentSong) return;
    if (!std::isfinite(seconds)) return;
    setCurrentTime(seconds);
    if (timeUpdated) timeUpdated(seconds);
    persistProgressThrottled();
}

void PlayerController::onEngineLengthChanged(quint64 generation, double seconds)
{
    if (generation != m_generation) return;
    if (m_playbackState.songId.isEmpty()) return;
    if (!std::isfinite(seconds) || seconds <= 1) return;
    if (std::abs(seconds - m_duration) > 0.5) setDuration(seconds);
}

void PlayerController::onEngineBuffering(quint64 generation, const QString& songId, float cache)
{
    if (generation != m_generation) return;
    if (m_playbackState.songId != songId) return;
    if (cache < 100) {
        if (m_pendingAutoplay && m_playbackState.kind != PlaybackState::Kind::Paused
            && m_playbackState.kind != PlaybackState::Kind::Failed) {
            setPlaybackState(makeState(PlaybackState::Kind::Buffering, songId));
        }
    } else if (m_playbackState.kind == PlaybackState::Kind::Buffering
        || m_playbackState.kind == PlaybackState::Kind::Loading) {
        setPlaybackState(m_pendingAutoplay ? makeState(PlaybackState::Kind::Playing, songId)
                                           : makeState(PlaybackState::Kind::Paused, songId));
    }
}

void PlayerController::raisePlayingForTesting()
{
    if (!m_currentSong) return;
    onEnginePlaying(m_generation, m_currentSong->id);
}

void PlayerController::raiseTimeChangedForTesting(double seconds)
{
    onEngineTimeChanged(m_generation, seconds);
}

void PlayerController::raiseEndReachedForTesting()
{
    if (!m_currentSong) return;
    onEngineEndReached(m_generation, m_currentSong->id);
}

void PlayerController::raiseErrorForTesting()
{
    if (!m_currentSong) return;
    onEngineError(m_generation, m_currentSong->id);
}

void PlayerController::raiseBufferingForTesting(float cache)
{
    if (!m_currentSong) return;
    onEngineBuffering(m_generation, m_currentSong->id, cache);
}

// MARK: - 播放控制（续）

void PlayerController::pause()
{
    m_pendingAutoplay = false;
    cancelAutoAdvance();
    if (m_engine && m_engineStarted) m_engine->pause();
    if (m_playbackState.kind == PlaybackState::Kind::Failed) {
        updateNowPlayingPlaybackState();
        return;
    }
    if (!m_playbackState.songId.isEmpty()) {
        setPlaybackState(makeState(PlaybackState::Kind::Paused, m_playbackState.songId));
    }
    if (m_currentSong) persistState();
    updateNowPlayingPlaybackState();
}

void PlayerController::resume()
{
    if (m_playbackState.kind == PlaybackState::Kind::Failed) {
        retryAfterFailure();
        return;
    }
    if (isPreparingPlayback()) {
        m_pendingAutoplay = true;
        if (!m_playbackState.songId.isEmpty()) {
            setPlaybackState(makeState(PlaybackState::Kind::Loading, m_playbackState.songId));
        }
        updateNowPlayingPlaybackState();
        return;
    }
    if (!m_currentSong) {
        if (m_queue.currentItem() != nullptr) {
            playCurrent();
        } else if (!m_queue.items.isEmpty()) {
            m_queue.jumpTo(m_queue.items.first().id);
            notifyQueueChanged();
            playCurrent();
        }
        return;
    }
    if (m_pendingUrl) {
        m_pendingAutoplay = true;
        startPlayback(*m_pendingUrl, *m_currentSong, m_generation);
        updateNowPlayingPlaybackState();
        return;
    }
    if (!m_engine || !m_engineStarted) {
        beginRestoredPlayback(true);
        return;
    }
    if (m_duration > 0 && m_currentTime >= std::max(m_duration - 0.5, 0.0)) {
        beginPlay(*m_currentSong, std::nullopt, true);
        return;
    }
    m_pendingAutoplay = true;
    m_engine->resume();
    if (!m_playbackState.songId.isEmpty()) {
        setPlaybackState(makeState(PlaybackState::Kind::Playing, m_playbackState.songId));
    }
    updateNowPlayingPlaybackState();
}

bool PlayerController::isPreparingPlayback() const
{
    if (!m_currentSong) return false;
    return m_isLoadInFlight || m_playbackState.isLoading();
}

void PlayerController::beginRestoredPlayback(bool autoplay)
{
    if (!m_currentSong) return;
    if (m_engine && m_engineStarted) return;
    beginPlay(*m_currentSong, m_currentTime > 0 ? std::optional<double>(m_currentTime) : std::nullopt, autoplay);
}

void PlayerController::resumeFromPersistence()
{
    beginRestoredPlayback(false);
}

void PlayerController::togglePlayPause()
{
    switch (m_playbackState.kind) {
    case PlaybackState::Kind::Playing:
    case PlaybackState::Kind::Buffering:
        pause();
        break;
    case PlaybackState::Kind::Loading:
        if (m_pendingAutoplay) {
            pause();
        } else {
            resume();
        }
        break;
    case PlaybackState::Kind::Failed:
        retryAfterFailure();
        break;
    default:
        resume();
        break;
    }
}

void PlayerController::retryAfterFailure()
{
    m_consecutiveFailures = 0;
    m_sameSongRetries = 0;
    if (m_currentSong) {
        beginPlay(*m_currentSong, std::nullopt, true);
    } else {
        playCurrent();
    }
}

void PlayerController::next()
{
    QueueItem* item = m_queue.next();
    if (item == nullptr) return;
    notifyQueueChanged();
    playSong(item->song);
}

void PlayerController::previous()
{
    if (m_hasActiveMedia && m_currentTime > 3) {
        seek(0);
        return;
    }
    QueueItem* item = m_queue.previous();
    if (item == nullptr) return;
    notifyQueueChanged();
    playSong(item->song);
}

void PlayerController::previewSeek(double time)
{
    if (!std::isfinite(time)) return;
    m_isUserSeeking = true;
    setCurrentTime(time);
    if (timeUpdated) timeUpdated(time);
}

void PlayerController::commitSeek(double time)
{
    if (!std::isfinite(time)) return;
    m_isUserSeeking = true;
    setCurrentTime(time);
    if (timeUpdated) timeUpdated(time);
    m_seekToken += 1;
    if (m_engine && m_engineStarted && m_hasActiveMedia) {
        m_engine->setPosition(std::max(0.0, time));
    } else if (m_pendingUrl) {
        m_pendingRestoreTime = time;
    }
    m_isUserSeeking = false;
    updateNowPlayingElapsedTime();
    if (m_currentSong) persistState();
}

void PlayerController::seek(double time)
{
    commitSeek(time);
}

void PlayerController::seekBy(double seconds)
{
    const double upper = m_duration > 0 ? m_duration : std::numeric_limits<double>::max();
    const double target = std::min(std::max(0.0, m_currentTime + seconds), upper);
    commitSeek(target);
}

void PlayerController::setPlayMode(PlayMode mode)
{
    m_queue.mode = mode;
    notifyQueueChanged();
    persistState();
}

void PlayerController::cyclePlayMode()
{
    PlayMode next;
    switch (m_queue.mode) {
    case PlayMode::Sequential:
        next = PlayMode::LoopAll;
        break;
    case PlayMode::LoopAll:
        next = PlayMode::LoopOne;
        break;
    case PlayMode::LoopOne:
        next = PlayMode::Shuffle;
        break;
    default:
        next = PlayMode::Sequential;
        break;
    }
    setPlayMode(next);
}

void PlayerController::appendToQueue(const Song& song)
{
    m_queue.append(song);
    notifyQueueChanged();
    persistState();
}

void PlayerController::appendToQueue(const QList<Song>& songs)
{
    if (songs.isEmpty()) return;
    m_queue.appendRange(songs);
    notifyQueueChanged();
    persistState();
}

void PlayerController::insertNext(const Song& song)
{
    m_queue.insertNext(song);
    notifyQueueChanged();
    persistState();
}

void PlayerController::insertNext(const QList<Song>& songs)
{
    if (songs.isEmpty()) return;
    if (m_queue.currentIndex < 0) {
        m_queue.appendRange(songs);
    } else {
        for (int index = songs.size() - 1; index >= 0; --index) {
            m_queue.insertNext(songs[index]);
        }
    }
    notifyQueueChanged();
    persistState();
}

void PlayerController::removeFromQueue(const QUuid& itemID)
{
    const bool wasCurrent = m_currentSong && m_queue.currentItem() && m_queue.currentItem()->id == itemID;
    const bool removedLastCurrent = wasCurrent && m_queue.currentIndex == m_queue.items.size() - 1;
    if (!m_queue.remove(itemID)) return;
    notifyQueueChanged();
    persistState();
    if (!wasCurrent) return;
    if (removedLastCurrent) {
        stopPlayback();
    } else if (m_queue.currentItem() != nullptr) {
        playSong(m_queue.currentItem()->song);
    } else {
        stopPlayback();
    }
}

void PlayerController::clearQueue()
{
    m_queue.clear();
    notifyQueueChanged();
    stopPlayback();
}

void PlayerController::moveQueueItems(int fromIndex, int toIndex)
{
    m_queue.move(fromIndex, toIndex);
    notifyQueueChanged();
    persistState();
}

void PlayerController::jumpTo(const QUuid& itemID)
{
    if (m_queue.jumpTo(itemID) && m_queue.currentItem() != nullptr) {
        notifyQueueChanged();
        playSong(m_queue.currentItem()->song);
    }
}

// MARK: - 音质

void PlayerController::setRequestedQuality(QualityLevel level)
{
    const QualityLevel resolved = songQualityPolicy::effectiveGlobalLevel(level, m_isAccountVIP);
    if (m_preferredQuality == level && m_requestedQuality == resolved) return;
    setPreferredQuality(level);
    setRequestedQualityValue(resolved);
    persistState();
    if (m_currentSong && m_playbackState.songId == m_currentSong->id
        && !qualityOverrideFor(m_currentSong->id)) {
        reloadCurrentSongForQualityChange();
    }
}

void PlayerController::setAccountIsVIP(bool value)
{
    if (value == m_isAccountVIP) return;
    m_isAccountVIP = value;
    if (onQualityChanged) onQualityChanged();
    const QualityLevel resolved = songQualityPolicy::effectiveGlobalLevel(m_preferredQuality, m_isAccountVIP);
    if (resolved == m_requestedQuality) return;
    setRequestedQualityValue(resolved);
    if (m_currentSong && m_playbackState.songId == m_currentSong->id
        && !qualityOverrideFor(m_currentSong->id)) {
        reloadCurrentSongForQualityChange();
    }
}

void PlayerController::setQualityOverride(std::optional<QualityLevel> level, const QString& songID)
{
    const std::optional<QualityLevel> normalized =
        (level && *level == QualityLevel::Unknown) ? std::nullopt : level;
    if (normalized == qualityOverrideFor(songID)) return;
    if (normalized) {
        m_songQualityOverrides.removeIf(
            [&songID](const SongQualityOverride& entry) { return entry.songID == songID; });
        SongQualityOverride entry;
        entry.songID = songID;
        entry.level = *normalized;
        entry.updatedAt = QDateTime::currentDateTime();
        m_songQualityOverrides.prepend(entry);
        while (m_songQualityOverrides.size() > maxSongQualityOverrides) {
            m_songQualityOverrides.removeLast();
        }
    } else {
        m_songQualityOverrides.removeIf(
            [&songID](const SongQualityOverride& entry) { return entry.songID == songID; });
    }
    saveSongQualityOverrides();
    if (onQualityChanged) onQualityChanged();
    if (m_currentSong && m_currentSong->id == songID) {
        reloadCurrentSongForQualityChange();
    }
}

std::optional<QualityLevel> PlayerController::qualityOverrideFor(const QString& songID) const
{
    for (const SongQualityOverride& entry : m_songQualityOverrides) {
        if (entry.songID == songID) return entry.level;
    }
    return std::nullopt;
}

QualityLevel PlayerController::effectiveQualityFor(const QString& songID) const
{
    return songQualityPolicy::effectiveLevel(qualityOverrideFor(songID), m_requestedQuality);
}

void PlayerController::reloadCurrentSongForQualityChange()
{
    if (!m_currentSong) return;
    const double time = m_currentTime;
    const bool autoplay =
        m_playbackState.isPlaying() || m_playbackState.isBuffering() || m_pendingAutoplay;
    beginPlay(*m_currentSong, time > 0 ? std::optional<double>(time) : std::nullopt, autoplay);
}

QList<SongQualityOverride> PlayerController::loadSongQualityOverrides()
{
    const QJsonValue raw =
        PersistenceStore::shared().loadSetting(QString::fromLatin1(songQualityOverridesKey));
    QList<SongQualityOverride> overrides;
    const QJsonArray array = json::array(raw);
    for (const QJsonValue& value : array) {
        if (!value.isObject()) continue;
        const QJsonObject object = value.toObject();
        SongQualityOverride entry;
        entry.songID = json::optionalIDString(object.value(QStringLiteral("songID"))).value_or(QString());
        if (entry.songID.isEmpty()) continue;
        entry.level = qualityLevelFromJson(object.value(QStringLiteral("level")), QualityLevel::Unknown);
        entry.updatedAt =
            json::parseDateTime(object.value(QStringLiteral("updatedAt"))).value_or(QDateTime::currentDateTime());
        overrides.append(entry);
    }
    return overrides;
}

void PlayerController::saveSongQualityOverrides()
{
    QJsonArray array;
    for (const SongQualityOverride& entry : std::as_const(m_songQualityOverrides)) {
        QJsonObject object;
        object[QStringLiteral("songID")] = entry.songID;
        object[QStringLiteral("level")] = qualityLevelToJson(entry.level);
        object[QStringLiteral("updatedAt")] = json::dateTimeToJson(entry.updatedAt);
        array.append(object);
    }
    PersistenceStore::shared().saveSetting(
        QString::fromLatin1(songQualityOverridesKey), QJsonValue(array));
}

void PlayerController::setPlaybackRate(float rate)
{
    const float clamped = std::min(std::max(rate, 0.25f), 3.0f);
    if (std::abs(clamped - m_playbackRate) < 0.0001f) return;
    setPlaybackRateValue(clamped);
    if (m_engine && m_engineStarted) {
        m_engine->setRate(clamped);
    }
    persistState();
    updateNowPlayingInfo();
}

// MARK: - 睡眠定时器

void PlayerController::setSleepTimer(double minutes)
{
    if (m_sleepTimerCts) {
        m_sleepTimerCts->cancel();
        m_sleepTimerCts.reset();
    }
    if (minutes <= 0) {
        setSleepTimerEndDate(std::nullopt);
        setSleepTimerRemaining(0);
        return;
    }
    const QDateTime end = QDateTime::currentDateTime().addMSecs(static_cast<qint64>(minutes * 60000.0));
    setSleepTimerEndDate(end);
    setSleepTimerRemaining(minutes * 60);
    auto cts = std::make_shared<CancellationTokenSource>();
    m_sleepTimerCts = cts;
    ct::detach(sleepTimerLoop(end, cts->token()));
}

void PlayerController::cancelSleepTimer()
{
    setSleepTimer(0);
}

Task<void> PlayerController::sleepTimerLoop(QDateTime end, CancellationToken ct)
{
    while (!ct.isCancellationRequested()) {
        const double remaining = QDateTime::currentDateTime().msecsTo(end) / 1000.0;
        if (remaining <= 0) break;
        try {
            co_await ct::Delay(1000, ct);
        } catch (const MusicException&) {
            co_return;
        }
        const double value = remaining;
        setSleepTimerRemaining(std::max(0.0, value));
    }
    if (ct.isCancellationRequested()) co_return;
    setSleepTimerEndDate(std::nullopt);
    setSleepTimerRemaining(0);
    pause();
}

// MARK: - 结束 / 失败处理

void PlayerController::handleTrackEnded()
{
    m_consecutiveFailures = 0;
    QueueItem* item = m_queue.handleEnded();
    if (item != nullptr) {
        notifyQueueChanged();
        playSong(item->song);
    } else {
        setPlaybackState(makeState(PlaybackState::Kind::Idle));
        updateNowPlayingPlaybackState();
    }
}

void PlayerController::handlePlayError(const MusicException& error, const Song& song)
{
    if (m_playbackState.kind == PlaybackState::Kind::Failed && m_playbackState.songId == song.id) return;

    const QString message = error.userFacingMessage();
    setPlaybackState(makeState(PlaybackState::Kind::Failed, song.id, message));
    CTLog::playback().error(QStringLiteral("播放失败 [%1]: %2").arg(song.title, message));
    if (onError) onError(song.id, message);

    m_consecutiveFailures += 1;
    if (m_consecutiveFailures >= maxConsecutiveFailures) {
        CTLog::playback().warn(
            QStringLiteral("连续失败 %1 次，停止自动切换").arg(m_consecutiveFailures));
        return;
    }

    const quint64 generation = m_generation;
    cancelAutoAdvance();
    auto cts = std::make_shared<CancellationTokenSource>();
    m_autoAdvanceCts = cts;
    ct::detach(autoAdvanceAfterFailure(song, generation, cts->token()));
}

Task<void> PlayerController::autoAdvanceAfterFailure(Song song, quint64 generation, CancellationToken ct)
{
    const bool refreshUrl = m_currentSong && song.id == m_currentSong->id && m_sameSongRetries < 1;
    if (refreshUrl) {
        m_sameSongRetries += 1;
        try {
            co_await ct::Delay(800, ct);
        } catch (const MusicException&) {
            co_return;
        }
        if (generation != m_generation) co_return;
        const std::optional<double> resumeTime =
            m_currentTime > 3 ? std::optional<double>(m_currentTime) : std::nullopt;
        beginPlay(song, resumeTime, true);
        co_return;
    }

    try {
        co_await ct::Delay(1500, ct);
    } catch (const MusicException&) {
        co_return;
    }
    if (generation != m_generation) co_return;
    if (m_consecutiveFailures >= maxConsecutiveFailures) co_return;
    QueueItem* item = m_queue.next();
    if (item == nullptr) {
        setPlaybackState(makeState(PlaybackState::Kind::Idle));
        updateNowPlayingPlaybackState();
        co_return;
    }
    notifyQueueChanged();
    beginPlay(item->song, std::nullopt, true);
}

void PlayerController::cancelAutoAdvance()
{
    if (m_autoAdvanceCts) {
        m_autoAdvanceCts->cancel();
        m_autoAdvanceCts.reset();
    }
}

// MARK: - 持久化

PersistedQueue PlayerController::makeSnapshot() const
{
    const PlaybackVolumePolicy::Output output = PlaybackVolumePolicy::resolve(m_volume, m_isMuted);
    return PersistedQueue::from(
        m_queue, m_currentTime, output.volume, output.isMuted, m_requestedQuality, m_playbackRate);
}

void PlayerController::persistState()
{
    m_lastProgressSaveAt = QDateTime::currentDateTime();
    PersistenceWriter::shared().schedule(makeSnapshot());
}

void PlayerController::persistProgressThrottled()
{
    if (m_lastProgressSaveAt.isValid()
        && m_lastProgressSaveAt.msecsTo(QDateTime::currentDateTime()) < progressSaveIntervalMs) {
        return;
    }
    persistState();
}

void PlayerController::persistNow()
{
    PersistenceWriter::shared().persistAndFlush(makeSnapshot(), m_recentlyPlayed);
}

bool PlayerController::loadPersistedState()
{
    const auto data = PersistenceStore::shared().loadQueue();
    if (!data) return false;
    m_queue = data->toPlayQueue();
    const PlaybackVolumePolicy::Output output = PlaybackVolumePolicy::resolve(data->volume, data->isMuted);
    setVolume(output.volume);
    setMuted(output.isMuted);
    setRequestedQualityValue(data->requestedQuality);
    setPlaybackRateValue(resolveRestoredPlaybackRate(data->playbackRate));
    setCurrentSong(m_queue.currentItem() != nullptr ? std::optional<Song>(m_queue.currentItem()->song)
                                                   : std::nullopt);
    setDuration(m_currentSong ? m_currentSong->duration : 0);
    setCurrentTime(data->currentTime);
    if (m_currentSong) {
        setPlaybackState(makeState(PlaybackState::Kind::Paused, m_currentSong->id));
    }
    notifyQueueChanged();
    return m_currentSong.has_value();
}

void PlayerController::stopPlayback()
{
    m_generation += 1;
    cancelAutoAdvance();
    if (m_loadCts) {
        m_loadCts->cancel();
        m_loadCts.reset();
    }
    m_pendingLoadTask.reset();
    m_isLoadInFlight = false;
    m_isUserSeeking = false;
    teardownPlayer();
    setCurrentSong(std::nullopt);
    setDuration(0);
    setCurrentTime(0);
    setBufferedTime(0);
    m_pendingRestoreTime.reset();
    m_pendingUrl.reset();
    setActualQuality(std::nullopt);
    setIsCurrentFromCache(false);
    AudioCacheManager::shared().setCurrentCachedSong(std::nullopt);
    m_retrySongID.clear();
    m_sameSongRetries = 0;
    setPlaybackState(makeState(PlaybackState::Kind::Idle));
    updateNowPlayingPlaybackState();
    persistState();
}

void PlayerController::notifyQueueChanged()
{
    if (onQueueChanged) onQueueChanged();
}

void PlayerController::updateNowPlayingInfo() {}

void PlayerController::updateNowPlayingElapsedTime() {}

void PlayerController::updateNowPlayingPlaybackState() {}

// MARK: - 状态写入

void PlayerController::setPlaybackState(PlaybackState state)
{
    if (m_playbackState.kind == state.kind && m_playbackState.songId == state.songId
        && m_playbackState.reason == state.reason) {
        return;
    }
    m_playbackState = std::move(state);
    if (onStateChanged) onStateChanged();
}

void PlayerController::setCurrentSong(std::optional<Song> song)
{
    if (m_currentSong == song) return;
    m_currentSong = std::move(song);
    if (onSongChanged) onSongChanged();
}

void PlayerController::setDuration(double value)
{
    if (m_duration == value) return;
    m_duration = value;
    if (onDurationChanged) onDurationChanged();
}

void PlayerController::setCurrentTime(double value)
{
    if (m_currentTime == value) return;
    m_currentTime = value;
    if (onPositionChanged) onPositionChanged();
}

void PlayerController::setBufferedTime(double value)
{
    if (m_bufferedTime == value) return;
    m_bufferedTime = value;
    if (onPositionChanged) onPositionChanged();
}

void PlayerController::setPreferredQuality(QualityLevel value)
{
    if (m_preferredQuality == value) return;
    m_preferredQuality = value;
    if (onQualityChanged) onQualityChanged();
}

void PlayerController::setRequestedQualityValue(QualityLevel value)
{
    if (m_requestedQuality == value) return;
    m_requestedQuality = value;
    if (onQualityChanged) onQualityChanged();
}

void PlayerController::setActualQuality(std::optional<AudioQuality> value)
{
    if (m_actualQuality == value) return;
    m_actualQuality = std::move(value);
    if (onQualityChanged) onQualityChanged();
}

void PlayerController::setIsCurrentFromCache(bool value)
{
    if (m_isCurrentFromCache == value) return;
    m_isCurrentFromCache = value;
    if (onQualityChanged) onQualityChanged();
}

void PlayerController::setPlaybackRateValue(float value)
{
    if (m_playbackRate == value) return;
    m_playbackRate = value;
    if (onPlaybackRateChanged) onPlaybackRateChanged();
}

void PlayerController::setSleepTimerEndDate(std::optional<QDateTime> value)
{
    if (m_sleepTimerEndDate == value) return;
    m_sleepTimerEndDate = std::move(value);
    if (onSleepTimerChanged) onSleepTimerChanged();
}

void PlayerController::setSleepTimerRemaining(double value)
{
    if (m_sleepTimerRemaining == value) return;
    m_sleepTimerRemaining = value;
    if (onSleepTimerChanged) onSleepTimerChanged();
}

// MARK: - 只读派生

std::optional<PlayingSourceInfo> PlayerController::playingSource() const
{
    if (!m_currentSong) return std::nullopt;
    const auto meta = AudioCacheManager::shared().meta(m_currentSong->id);
    return playingSourceFormatter::describe(m_actualQuality, m_requestedQuality, m_isCurrentFromCache,
        meta ? std::optional<QString>(meta->formatName) : std::nullopt,
        meta ? std::optional<int>(meta->bitrateKbps) : std::nullopt,
        AudioCacheManager::shared().cachingSongIDs().contains(m_currentSong->id));
}

bool PlayerController::isRateAdjusted() const
{
    return std::abs(m_playbackRate - 1.0f) > 0.01f;
}

QString PlayerController::playbackRateLabel() const
{
    return isRateAdjusted() ? rateLabel(m_playbackRate) : QString();
}

bool PlayerController::currentSongUsesOverride() const
{
    return m_currentSong && qualityOverrideFor(m_currentSong->id).has_value();
}

} // namespace ct
