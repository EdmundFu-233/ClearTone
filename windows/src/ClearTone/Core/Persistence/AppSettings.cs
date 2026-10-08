using System.Text.Json;
using System.Text.Json.Serialization;
using ClearTone.Core.Models;
using ClearTone.Playback;

namespace ClearTone.Core.Persistence;

public enum CTThemeMode
{
    System,
    Dark,
    Light,
}

public enum CloseBehavior
{
    KeepPlaying,
    MinimizeToMenuBar,
    Quit,
}

public static class CloseBehaviorExtensions
{
    public static string DisplayName(this CloseBehavior behavior) => behavior switch
    {
        CloseBehavior.KeepPlaying => "继续后台播放",
        CloseBehavior.MinimizeToMenuBar => "缩到菜单栏",
        _ => "退出应用",
    };

    public static string Help(this CloseBehavior behavior) => behavior switch
    {
        CloseBehavior.KeepPlaying => "关闭窗口但继续在后台播放，菜单栏不出现图标",
        CloseBehavior.MinimizeToMenuBar => "关闭窗口并在菜单栏显示图标，从那里控制播放",
        _ => "关闭窗口即完全退出",
    };
}

public enum PerformanceMode
{
    Auto,
    Saver,
    Quality,
    Static,
}

public static class PerformanceModeExtensions
{
    public static string DisplayName(this PerformanceMode mode) => mode switch
    {
        PerformanceMode.Auto => "自动",
        PerformanceMode.Saver => "节能",
        PerformanceMode.Quality => "高质量",
        _ => "静态",
    };
}

public enum SpectrumMode
{
    Ambient,
    Off,
}

public static class SpectrumModeExtensions
{
    public static string DisplayName(this SpectrumMode mode) =>
        mode == SpectrumMode.Ambient ? "环境动画" : "关闭";
}

public sealed class AppSettings
{
    public CTThemeMode ThemeMode { get; set; } = CTThemeMode.System;
    public bool ResumePlaybackOnLaunch { get; set; }
    public CloseBehavior CloseBehavior { get; set; } = CloseBehavior.KeepPlaying;
    public bool MenuBarAlwaysVisible { get; set; }
    public bool MiniPlayerAlwaysOnTop { get; set; } = true;
    public PerformanceMode PerformanceMode { get; set; } = PerformanceMode.Auto;
    public SpectrumMode SpectrumMode { get; set; } = SpectrumMode.Ambient;
    public double LyricOffset { get; set; }
    public QualityLevel PreferredQuality { get; set; } = SongQualityPolicy.AutoLevel;
    public bool AudioCacheEnabled { get; set; } = true;
}

public sealed class AppSettingsJsonConverter : JsonConverter<AppSettings>
{
    public override AppSettings Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        var root = document.RootElement;
        var settings = new AppSettings();
        if (root.ValueKind != JsonValueKind.Object) return settings;

        settings.ThemeMode = Field(root, "themeMode", CTThemeMode.System);
        settings.ResumePlaybackOnLaunch = Field(root, "resumePlaybackOnLaunch", false);
        settings.CloseBehavior = Field(root, "closeBehavior", CloseBehavior.KeepPlaying);
        settings.MenuBarAlwaysVisible = Field(root, "menuBarAlwaysVisible", false);
        settings.MiniPlayerAlwaysOnTop = Field(root, "miniPlayerAlwaysOnTop", true);
        settings.PerformanceMode = Field(root, "performanceMode", PerformanceMode.Auto);
        settings.SpectrumMode = Field(root, "spectrumMode", SpectrumMode.Ambient);
        settings.LyricOffset = Field(root, "lyricOffset", 0.0);
        settings.PreferredQuality = Field(root, "preferredQuality", SongQualityPolicy.AutoLevel);
        settings.AudioCacheEnabled = Field(root, "audioCacheEnabled", true);
        return settings;
    }

    public override void Write(Utf8JsonWriter writer, AppSettings value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("themeMode", ToCamel(value.ThemeMode.ToString()));
        writer.WriteBoolean("resumePlaybackOnLaunch", value.ResumePlaybackOnLaunch);
        writer.WriteString("closeBehavior", ToCamel(value.CloseBehavior.ToString()));
        writer.WriteBoolean("menuBarAlwaysVisible", value.MenuBarAlwaysVisible);
        writer.WriteBoolean("miniPlayerAlwaysOnTop", value.MiniPlayerAlwaysOnTop);
        writer.WriteString("performanceMode", ToCamel(value.PerformanceMode.ToString()));
        writer.WriteString("spectrumMode", ToCamel(value.SpectrumMode.ToString()));
        if (double.IsFinite(value.LyricOffset))
        {
            writer.WriteNumber("lyricOffset", value.LyricOffset);
        }
        else
        {
            writer.WriteString("lyricOffset", double.IsNaN(value.LyricOffset) ? "NaN" : (value.LyricOffset > 0 ? "Infinity" : "-Infinity"));
        }
        writer.WriteString("preferredQuality", ToCamel(value.PreferredQuality.ToString()));
        writer.WriteBoolean("audioCacheEnabled", value.AudioCacheEnabled);
        writer.WriteEndObject();
    }

    private static string ToCamel(string value) =>
        string.IsNullOrEmpty(value) ? value : char.ToLowerInvariant(value[0]) + value[1..];

    private static T Field<T>(JsonElement root, string name, T fallback)
    {
        try
        {
            if (!root.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null) return fallback;
            if (typeof(T).IsEnum)
            {
                if (value.ValueKind != JsonValueKind.String) return fallback;
                var text = value.GetString();
                if (text is null) return fallback;
                if (Enum.TryParse(typeof(T), text, ignoreCase: true, out var parsed) &&
                    parsed is T typed && Enum.IsDefined(typeof(T), typed))
                {
                    return typed;
                }
                if (typeof(T) == typeof(QualityLevel) && QualityLevelExtensions.FromPersistedName(text) is { } level)
                {
                    return (T)(object)level;
                }
                return fallback;
            }
            return JsonSerializer.Deserialize<T>(value.GetRawText(), JsonDefaults.Options) ?? fallback;
        }
        catch
        {
            return fallback;
        }
    }
}
