#include "Playback/AudioEngine.h"

#include "Core/Logging/CTLog.h"
#include "Core/Models/MusicError.h"

#include <QCoreApplication>
#include <QMetaObject>
#include <QThread>

#include <cmath>
#include <utility>

#if defined(CT_HAVE_LIBVLC)
#include <vlc/vlc.h>

#include <atomic>
#endif

#if defined(CT_HAVE_QT_MULTIMEDIA)
#include <QAudioOutput>
#include <QMediaPlayer>
#endif

namespace ct {

#if defined(CT_HAVE_LIBVLC)
namespace {

void invokeOnMainThread(std::function<void()> action)
{
    QCoreApplication* app = QCoreApplication::instance();
    if (app == nullptr || QThread::currentThread() == app->thread()) {
        action();
        return;
    }
    QMetaObject::invokeMethod(app, std::move(action), Qt::QueuedConnection);
}

} // namespace
#endif

#if defined(CT_HAVE_LIBVLC)

class VlcAudioEngine : public AudioEngine {
public:
    VlcAudioEngine()
    {
        m_state = std::make_shared<State>();
        m_instance = libvlc_new(0, nullptr);
        if (m_instance == nullptr) throw MusicException::unknown(QStringLiteral("无法初始化 libVLC"));
        m_player = libvlc_media_player_new(m_instance);
        if (m_player == nullptr) {
            libvlc_release(m_instance);
            m_instance = nullptr;
            throw MusicException::unknown(QStringLiteral("无法创建 libVLC 播放器"));
        }
        libvlc_event_manager_t* manager = libvlc_media_player_event_manager(m_player);
        if (manager != nullptr) {
            const libvlc_event_type_t events[] = {
                libvlc_MediaPlayerPlaying,
                libvlc_MediaPlayerPaused,
                libvlc_MediaPlayerEndReached,
                libvlc_MediaPlayerEncounteredError,
                libvlc_MediaPlayerTimeChanged,
                libvlc_MediaPlayerLengthChanged,
                libvlc_MediaPlayerBuffering,
            };
            for (const libvlc_event_type_t type : events) {
                libvlc_event_attach(manager, type, &VlcAudioEngine::onRawEvent, this);
            }
        }
    }

    ~VlcAudioEngine() override
    {
        if (m_state) {
            m_state->alive.store(false);
            m_state->serial.fetch_add(1);
        }
        if (m_media != nullptr) {
            libvlc_media_release(m_media);
            m_media = nullptr;
        }
        if (m_player != nullptr) {
            libvlc_media_player_release(m_player);
            m_player = nullptr;
        }
        if (m_instance != nullptr) {
            libvlc_release(m_instance);
            m_instance = nullptr;
        }
    }

    void setMediaSource(const QUrl& url, AudioEngineCallbacks callbacks) override
    {
        m_state->callbacks = std::move(callbacks);
        m_state->serial.fetch_add(1);
        if (m_media != nullptr) {
            libvlc_media_release(m_media);
            m_media = nullptr;
        }
        const QByteArray encoded = url.toString(QUrl::FullyEncoded).toUtf8();
        m_media = libvlc_media_new_location(m_instance, encoded.constData());
        if (m_media == nullptr) throw MusicException::unknown(QStringLiteral("无法创建媒体源"));
        libvlc_media_player_set_media(m_player, m_media);
    }

    void play() override { libvlc_media_player_play(m_player); }

    void pause() override { libvlc_media_player_set_pause(m_player, 1); }

    void resume() override { libvlc_media_player_set_pause(m_player, 0); }

    void stop() override
    {
        if (m_state) m_state->serial.fetch_add(1);
        libvlc_media_player_stop_async(m_player);
    }

    void setPosition(double seconds) override
    {
        const libvlc_time_t milliseconds = static_cast<libvlc_time_t>(seconds * 1000.0);
#if defined(LIBVLC_VERSION_MAJOR) && LIBVLC_VERSION_MAJOR >= 4
        libvlc_media_player_set_time(m_player, milliseconds, false);
#else
        libvlc_media_player_set_time(m_player, milliseconds);
#endif
    }

    void setVolume(float volume) override
    {
        libvlc_audio_set_volume(m_player, static_cast<int>(std::lround(volume * 100.0f)));
    }

    void setMuted(bool muted) override { libvlc_audio_set_mute(m_player, muted ? 1 : 0); }

    void setRate(float rate) override { libvlc_media_player_set_rate(m_player, rate); }

    double position() const override
    {
        const libvlc_time_t milliseconds = libvlc_media_player_get_time(m_player);
        return milliseconds > 0 ? milliseconds / 1000.0 : 0.0;
    }

    double duration() const override
    {
        const libvlc_time_t milliseconds = libvlc_media_player_get_length(m_player);
        return milliseconds > 0 ? milliseconds / 1000.0 : 0.0;
    }

private:
    struct State {
        std::atomic<bool> alive{true};
        std::atomic<quint64> serial{0};
        AudioEngineCallbacks callbacks;
    };

    static void onRawEvent(const libvlc_event_t* event, void* userdata)
    {
        static_cast<VlcAudioEngine*>(userdata)->dispatchEvent(event);
    }

    void dispatchEvent(const libvlc_event_t* event)
    {
        const int type = static_cast<int>(event->type);
        double value = 0;
        switch (type) {
        case libvlc_MediaPlayerTimeChanged:
            value = event->u.media_player_time_changed.new_time / 1000.0;
            break;
        case libvlc_MediaPlayerLengthChanged:
            value = event->u.media_player_length_changed.new_length / 1000.0;
            break;
        case libvlc_MediaPlayerBuffering:
            value = event->u.media_player_buffering.new_cache;
            break;
        default:
            break;
        }
        const std::shared_ptr<State> state = m_state;
        const quint64 serial = state->serial.load();
        invokeOnMainThread([state, serial, type, value] {
            if (!state->alive.load()) return;
            if (serial != state->serial.load()) return;
            AudioEngineCallbacks& callbacks = state->callbacks;
            switch (type) {
            case libvlc_MediaPlayerPlaying:
                if (callbacks.onPlaying) callbacks.onPlaying();
                break;
            case libvlc_MediaPlayerPaused:
                if (callbacks.onPaused) callbacks.onPaused();
                break;
            case libvlc_MediaPlayerEndReached:
                if (callbacks.onEndReached) callbacks.onEndReached();
                break;
            case libvlc_MediaPlayerEncounteredError:
                if (callbacks.onError) callbacks.onError();
                break;
            case libvlc_MediaPlayerTimeChanged:
                if (callbacks.onTimeChanged) callbacks.onTimeChanged(value);
                break;
            case libvlc_MediaPlayerLengthChanged:
                if (callbacks.onDurationChanged) callbacks.onDurationChanged(value);
                break;
            case libvlc_MediaPlayerBuffering:
                if (callbacks.onBuffering) callbacks.onBuffering(static_cast<float>(value));
                break;
            default:
                break;
            }
        });
    }

    std::shared_ptr<State> m_state;
    libvlc_instance_t* m_instance = nullptr;
    libvlc_media_player_t* m_player = nullptr;
    libvlc_media_t* m_media = nullptr;
};

#endif // CT_HAVE_LIBVLC

#if defined(CT_HAVE_QT_MULTIMEDIA)

class QtMultimediaAudioEngine : public AudioEngine {
public:
    QtMultimediaAudioEngine()
    {
        m_player = new QMediaPlayer();
        m_output = new QAudioOutput(m_player);
        m_player->setAudioOutput(m_output);

        QObject::connect(m_player, &QMediaPlayer::playbackStateChanged, m_player,
            [this](QMediaPlayer::PlaybackState state) {
                if (state == QMediaPlayer::PlayingState) {
                    if (m_callbacks.onPlaying) m_callbacks.onPlaying();
                } else if (state == QMediaPlayer::PausedState) {
                    if (m_callbacks.onPaused) m_callbacks.onPaused();
                }
            });
        QObject::connect(m_player, &QMediaPlayer::mediaStatusChanged, m_player,
            [this](QMediaPlayer::MediaStatus status) {
                if (status == QMediaPlayer::EndOfMedia && m_callbacks.onEndReached) m_callbacks.onEndReached();
            });
        QObject::connect(m_player, &QMediaPlayer::errorOccurred, m_player,
            [this](QMediaPlayer::Error, const QString&) {
                if (m_callbacks.onError) m_callbacks.onError();
            });
        QObject::connect(m_player, &QMediaPlayer::positionChanged, m_player, [this](qint64 milliseconds) {
            if (m_callbacks.onTimeChanged) m_callbacks.onTimeChanged(milliseconds / 1000.0);
        });
        QObject::connect(m_player, &QMediaPlayer::durationChanged, m_player, [this](qint64 milliseconds) {
            if (m_callbacks.onDurationChanged) m_callbacks.onDurationChanged(milliseconds / 1000.0);
        });
        QObject::connect(m_player, &QMediaPlayer::bufferProgressChanged, m_player, [this](float progress) {
            if (m_callbacks.onBuffering) m_callbacks.onBuffering(progress * 100.0f);
        });
    }

    ~QtMultimediaAudioEngine() override { delete m_player; }

    void setMediaSource(const QUrl& url, AudioEngineCallbacks callbacks) override
    {
        m_callbacks = std::move(callbacks);
        m_player->setSource(url);
    }

    void play() override { m_player->play(); }

    void pause() override { m_player->pause(); }

    void resume() override { m_player->play(); }

    void stop() override { m_player->stop(); }

    void setPosition(double seconds) override
    {
        m_player->setPosition(static_cast<qint64>(seconds * 1000.0));
    }

    void setVolume(float volume) override { m_output->setVolume(volume); }

    void setMuted(bool muted) override { m_output->setMuted(muted); }

    void setRate(float rate) override { m_player->setPlaybackRate(rate); }

    double position() const override { return m_player->position() / 1000.0; }

    double duration() const override { return m_player->duration() / 1000.0; }

private:
    QMediaPlayer* m_player = nullptr;
    QAudioOutput* m_output = nullptr;
    AudioEngineCallbacks m_callbacks;
};

#endif // CT_HAVE_QT_MULTIMEDIA

std::unique_ptr<AudioEngine> createDefaultAudioEngine()
{
#if defined(CT_HAVE_LIBVLC)
    try {
        return std::make_unique<VlcAudioEngine>();
    } catch (const MusicException& error) {
        CTLog::playback().warn(QStringLiteral("libVLC 初始化失败，改用 Qt Multimedia: %1").arg(error.message()));
    }
#endif
#if defined(CT_HAVE_QT_MULTIMEDIA)
    return std::make_unique<QtMultimediaAudioEngine>();
#else
    return nullptr;
#endif
}

} // namespace ct
