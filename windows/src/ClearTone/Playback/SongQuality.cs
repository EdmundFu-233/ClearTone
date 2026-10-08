using ClearTone.Core.Models;

namespace ClearTone.Playback;

public sealed class SongQualityOverride : IEquatable<SongQualityOverride>
{
    public string SongID { get; set; } = "";
    public QualityLevel Level { get; set; } = QualityLevel.Unknown;
    public DateTimeOffset UpdatedAt { get; set; } = DateTimeOffset.Now;

    public string Id => SongID;

    public bool Equals(SongQualityOverride? other) =>
        other is not null && SongID == other.SongID && Level == other.Level && UpdatedAt == other.UpdatedAt;

    public override bool Equals(object? obj) => Equals(obj as SongQualityOverride);

    public override int GetHashCode() => HashCode.Combine(SongID, Level, UpdatedAt);
}

public static class SongQualityPolicy
{
    public static IReadOnlyList<QualityLevel> SelectableLevels { get; } = new[]
    {
        QualityLevel.Standard,
        QualityLevel.Higher,
        QualityLevel.ExHigh,
        QualityLevel.Lossless,
        QualityLevel.HiRes,
    };

    public const QualityLevel AutoLevel = QualityLevel.Unknown;

    public static QualityLevel DefaultLevel(bool isVIP) =>
        isVIP ? QualityLevel.Lossless : QualityLevel.ExHigh;

    public static QualityLevel EffectiveGlobalLevel(QualityLevel preference, bool isVIP) =>
        preference == AutoLevel ? DefaultLevel(isVIP) : preference;

    public static QualityLevel EffectiveLevel(QualityLevel? overridden, QualityLevel global) =>
        overridden ?? global;

    public static bool UseLocalCache(bool hasOverride) => !hasOverride;

    public static bool ShouldWriteCache(bool hasOverride, bool isPreview) => !hasOverride && !isPreview;

    public static int? DerivedBitrateKbps(long? sizeBytes, double duration)
    {
        if (sizeBytes is not > 0 || duration <= 1) return null;
        var kbps = sizeBytes.Value * 8 / duration / 1000;
        if (!double.IsFinite(kbps) || kbps < 1) return null;
        return (int)Math.Round(kbps);
    }
}
