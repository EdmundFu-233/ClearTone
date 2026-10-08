#pragma once

#include "Core/Models/MusicModels.h"

#include <QJsonObject>
#include <QString>

namespace ct {

enum class CTThemeMode {
    System,
    Dark,
    Light,
};

enum class CloseBehavior {
    KeepPlaying,
    MinimizeToMenuBar,
    Quit,
};

namespace closeBehavior {
QString displayName(CloseBehavior behavior);
QString help(CloseBehavior behavior);
} // namespace closeBehavior

enum class PerformanceMode {
    Auto,
    Saver,
    Quality,
    Static,
};

namespace performanceMode {
QString displayName(PerformanceMode mode);
} // namespace performanceMode

enum class SpectrumMode {
    Ambient,
    Off,
};

namespace spectrumMode {
QString displayName(SpectrumMode mode);
} // namespace spectrumMode

struct AppSettings {
    CTThemeMode themeMode = CTThemeMode::System;
    bool resumePlaybackOnLaunch = false;
    CloseBehavior closeBehavior = CloseBehavior::KeepPlaying;
    bool menuBarAlwaysVisible = false;
    bool miniPlayerAlwaysOnTop = true;
    PerformanceMode performanceMode = PerformanceMode::Auto;
    SpectrumMode spectrumMode = SpectrumMode::Ambient;
    double lyricOffset = 0;
    QualityLevel preferredQuality = QualityLevel::Unknown;
    bool audioCacheEnabled = true;

    QJsonObject toJson() const;
    static AppSettings fromJson(const QJsonObject& object);
};

} // namespace ct
