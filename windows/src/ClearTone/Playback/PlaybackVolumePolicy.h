#pragma once

#include <QtGlobal>

#include <optional>

namespace ct {

class PlaybackVolumePolicy {
public:
    enum class Platform {
        IOS,
        MacOS,
        Windows,
    };

    struct Output {
        float volume;
        bool isMuted;
    };

    static constexpr float iosDefaultVolume = 1.0f;
    static constexpr float desktopDefaultVolume = 0.8f;

    static Platform currentPlatform()
    {
#if defined(Q_OS_IOS)
        return Platform::IOS;
#elif defined(Q_OS_WIN)
        return Platform::Windows;
#else
        return Platform::MacOS;
#endif
    }

    static float defaultVolume(std::optional<Platform> platform = std::nullopt)
    {
        return (platform.value_or(currentPlatform()) == Platform::IOS) ? iosDefaultVolume
                                                                       : desktopDefaultVolume;
    }

    static Output resolve(float volume, bool isMuted, std::optional<Platform> platform = std::nullopt)
    {
        if (platform.value_or(currentPlatform()) == Platform::IOS) return {iosDefaultVolume, false};
        return {volume, isMuted};
    }
};

} // namespace ct
