#include "Core/Persistence/AppSettings.h"

#include "Core/Models/JsonHelpers.h"
#include "Core/Models/ModelJson.h"

#include <cmath>
#include <functional>
#include <limits>

namespace ct {

namespace {

QString camelCase(const QString& value)
{
    if (value.isEmpty()) return value;
    QString result = value;
    result[0] = result[0].toLower();
    return result;
}

template <typename Enum, typename Parse>
Enum enumField(const QJsonObject& root, const QString& name, Enum fallback, Parse parse)
{
    const QJsonValue value = root.value(name);
    if (!value.isString()) return fallback;
    const auto parsed = parse(value.toString());
    return parsed.value_or(fallback);
}

std::optional<CTThemeMode> parseThemeMode(const QString& raw)
{
    if (raw.compare(QLatin1String("system"), Qt::CaseInsensitive) == 0) return CTThemeMode::System;
    if (raw.compare(QLatin1String("dark"), Qt::CaseInsensitive) == 0) return CTThemeMode::Dark;
    if (raw.compare(QLatin1String("light"), Qt::CaseInsensitive) == 0) return CTThemeMode::Light;
    return std::nullopt;
}

std::optional<CloseBehavior> parseCloseBehavior(const QString& raw)
{
    if (raw.compare(QLatin1String("keepPlaying"), Qt::CaseInsensitive) == 0) return CloseBehavior::KeepPlaying;
    if (raw.compare(QLatin1String("minimizeToMenuBar"), Qt::CaseInsensitive) == 0)
        return CloseBehavior::MinimizeToMenuBar;
    if (raw.compare(QLatin1String("quit"), Qt::CaseInsensitive) == 0) return CloseBehavior::Quit;
    return std::nullopt;
}

std::optional<PerformanceMode> parsePerformanceMode(const QString& raw)
{
    if (raw.compare(QLatin1String("auto"), Qt::CaseInsensitive) == 0) return PerformanceMode::Auto;
    if (raw.compare(QLatin1String("saver"), Qt::CaseInsensitive) == 0) return PerformanceMode::Saver;
    if (raw.compare(QLatin1String("quality"), Qt::CaseInsensitive) == 0) return PerformanceMode::Quality;
    if (raw.compare(QLatin1String("static"), Qt::CaseInsensitive) == 0) return PerformanceMode::Static;
    return std::nullopt;
}

std::optional<SpectrumMode> parseSpectrumMode(const QString& raw)
{
    if (raw.compare(QLatin1String("ambient"), Qt::CaseInsensitive) == 0) return SpectrumMode::Ambient;
    if (raw.compare(QLatin1String("off"), Qt::CaseInsensitive) == 0) return SpectrumMode::Off;
    return std::nullopt;
}

std::optional<double> lyricOffsetField(const QJsonObject& root)
{
    const QJsonValue value = root.value(QStringLiteral("lyricOffset"));
    if (value.isDouble()) return value.toDouble();
    if (value.isString()) {
        const QString raw = value.toString();
        if (raw == QLatin1String("NaN")) return std::numeric_limits<double>::quiet_NaN();
        if (raw == QLatin1String("Infinity")) return std::numeric_limits<double>::infinity();
        if (raw == QLatin1String("-Infinity")) return -std::numeric_limits<double>::infinity();
        bool ok = false;
        const double parsed = raw.toDouble(&ok);
        if (ok) return parsed;
    }
    return std::nullopt;
}

} // namespace

namespace closeBehavior {

QString displayName(CloseBehavior behavior)
{
    switch (behavior) {
    case CloseBehavior::KeepPlaying:
        return QStringLiteral("继续后台播放");
    case CloseBehavior::MinimizeToMenuBar:
        return QStringLiteral("缩到菜单栏");
    case CloseBehavior::Quit:
        return QStringLiteral("退出应用");
    }
    return QStringLiteral("退出应用");
}

QString help(CloseBehavior behavior)
{
    switch (behavior) {
    case CloseBehavior::KeepPlaying:
        return QStringLiteral("关闭窗口但继续在后台播放，菜单栏不出现图标");
    case CloseBehavior::MinimizeToMenuBar:
        return QStringLiteral("关闭窗口并在菜单栏显示图标，从那里控制播放");
    case CloseBehavior::Quit:
        return QStringLiteral("关闭窗口即完全退出");
    }
    return QString();
}

} // namespace closeBehavior

namespace performanceMode {

QString displayName(PerformanceMode mode)
{
    switch (mode) {
    case PerformanceMode::Auto:
        return QStringLiteral("自动");
    case PerformanceMode::Saver:
        return QStringLiteral("节能");
    case PerformanceMode::Quality:
        return QStringLiteral("高质量");
    case PerformanceMode::Static:
        return QStringLiteral("静态");
    }
    return QStringLiteral("自动");
}

} // namespace performanceMode

namespace spectrumMode {

QString displayName(SpectrumMode mode)
{
    return mode == SpectrumMode::Ambient ? QStringLiteral("环境动画") : QStringLiteral("关闭");
}

} // namespace spectrumMode

QJsonObject AppSettings::toJson() const
{
    QJsonObject object;
    object[QStringLiteral("themeMode")] = camelCase(QString::fromLatin1(
        [this] {
            switch (themeMode) {
            case CTThemeMode::System:
                return "System";
            case CTThemeMode::Dark:
                return "Dark";
            case CTThemeMode::Light:
                return "Light";
            }
            return "System";
        }()));
    object[QStringLiteral("resumePlaybackOnLaunch")] = resumePlaybackOnLaunch;
    object[QStringLiteral("closeBehavior")] = camelCase(QString::fromLatin1(
        [this] {
            switch (closeBehavior) {
            case CloseBehavior::KeepPlaying:
                return "KeepPlaying";
            case CloseBehavior::MinimizeToMenuBar:
                return "MinimizeToMenuBar";
            case CloseBehavior::Quit:
                return "Quit";
            }
            return "KeepPlaying";
        }()));
    object[QStringLiteral("menuBarAlwaysVisible")] = menuBarAlwaysVisible;
    object[QStringLiteral("miniPlayerAlwaysOnTop")] = miniPlayerAlwaysOnTop;
    object[QStringLiteral("performanceMode")] = camelCase(QString::fromLatin1(
        [this] {
            switch (performanceMode) {
            case PerformanceMode::Auto:
                return "Auto";
            case PerformanceMode::Saver:
                return "Saver";
            case PerformanceMode::Quality:
                return "Quality";
            case PerformanceMode::Static:
                return "Static";
            }
            return "Auto";
        }()));
    object[QStringLiteral("spectrumMode")] = camelCase(QString::fromLatin1(
        [this] {
            switch (spectrumMode) {
            case SpectrumMode::Ambient:
                return "Ambient";
            case SpectrumMode::Off:
                return "Off";
            }
            return "Ambient";
        }()));
    if (std::isfinite(lyricOffset)) {
        object[QStringLiteral("lyricOffset")] = lyricOffset;
    } else if (std::isnan(lyricOffset)) {
        object[QStringLiteral("lyricOffset")] = QStringLiteral("NaN");
    } else {
        object[QStringLiteral("lyricOffset")] =
            lyricOffset > 0 ? QStringLiteral("Infinity") : QStringLiteral("-Infinity");
    }
    object[QStringLiteral("preferredQuality")] = qualityLevelToJson(preferredQuality);
    object[QStringLiteral("audioCacheEnabled")] = audioCacheEnabled;
    return object;
}

AppSettings AppSettings::fromJson(const QJsonObject& root)
{
    AppSettings settings;
    settings.themeMode = enumField(root, QStringLiteral("themeMode"), CTThemeMode::System, parseThemeMode);
    settings.resumePlaybackOnLaunch =
        json::optionalBool(root.value(QStringLiteral("resumePlaybackOnLaunch"))).value_or(false);
    settings.closeBehavior = enumField(
        root, QStringLiteral("closeBehavior"), CloseBehavior::KeepPlaying, parseCloseBehavior);
    settings.menuBarAlwaysVisible =
        json::optionalBool(root.value(QStringLiteral("menuBarAlwaysVisible"))).value_or(false);
    settings.miniPlayerAlwaysOnTop =
        json::optionalBool(root.value(QStringLiteral("miniPlayerAlwaysOnTop"))).value_or(true);
    settings.performanceMode =
        enumField(root, QStringLiteral("performanceMode"), PerformanceMode::Auto, parsePerformanceMode);
    settings.spectrumMode =
        enumField(root, QStringLiteral("spectrumMode"), SpectrumMode::Ambient, parseSpectrumMode);
    settings.lyricOffset = lyricOffsetField(root).value_or(0);
    settings.preferredQuality =
        qualityLevelFromJson(root.value(QStringLiteral("preferredQuality")), QualityLevel::Unknown);
    settings.audioCacheEnabled =
        json::optionalBool(root.value(QStringLiteral("audioCacheEnabled"))).value_or(true);
    return settings;
}

} // namespace ct
