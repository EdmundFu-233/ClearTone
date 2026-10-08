#pragma once

#include <QUrl>

#include <functional>
#include <memory>

namespace ct {

struct AudioEngineCallbacks {
    std::function<void()> onPlaying;
    std::function<void()> onPaused;
    std::function<void()> onEndReached;
    std::function<void()> onError;
    std::function<void(double)> onTimeChanged;
    std::function<void(double)> onDurationChanged;
    std::function<void(float)> onBuffering;
};

class AudioEngine {
public:
    virtual ~AudioEngine() = default;

    virtual void setMediaSource(const QUrl& url, AudioEngineCallbacks callbacks) = 0;
    virtual void play() = 0;
    virtual void pause() = 0;
    virtual void resume() = 0;
    virtual void stop() = 0;
    virtual void setPosition(double seconds) = 0;
    virtual void setVolume(float volume) = 0;
    virtual void setMuted(bool muted) = 0;
    virtual void setRate(float rate) = 0;
    virtual double position() const = 0;
    virtual double duration() const = 0;
};

std::unique_ptr<AudioEngine> createDefaultAudioEngine();

} // namespace ct
