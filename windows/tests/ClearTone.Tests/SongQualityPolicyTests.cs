using ClearTone.Core.Models;
using ClearTone.Playback;
using Xunit;

namespace ClearTone.Tests;

public class SongQualityPolicyTests
{
    [Fact]
    public void TestOverrideWinsOverGlobal()
    {
        Assert.Equal(QualityLevel.Lossless, SongQualityPolicy.EffectiveLevel(QualityLevel.Lossless, QualityLevel.ExHigh));
        Assert.Equal(QualityLevel.ExHigh, SongQualityPolicy.EffectiveLevel(null, QualityLevel.ExHigh));
    }

    [Fact]
    public void TestCacheIsUsedOnlyWithoutOverride()
    {
        Assert.True(SongQualityPolicy.UseLocalCache(false));
        Assert.False(SongQualityPolicy.UseLocalCache(true));
    }

    [Fact]
    public void TestNoCacheWriteWhenOverridden()
    {
        Assert.False(SongQualityPolicy.ShouldWriteCache(true, false));
        Assert.False(SongQualityPolicy.ShouldWriteCache(false, true));
        Assert.True(SongQualityPolicy.ShouldWriteCache(false, false));
    }

    [Fact]
    public void TestSelectableLevelsExcludeUnknownPlaceholder()
    {
        Assert.DoesNotContain(QualityLevel.Unknown, SongQualityPolicy.SelectableLevels);
        Assert.Equal(5, SongQualityPolicy.SelectableLevels.Count);
        Assert.Contains(QualityLevel.Lossless, SongQualityPolicy.SelectableLevels);
        Assert.Contains(QualityLevel.HiRes, SongQualityPolicy.SelectableLevels);
    }

    [Fact]
    public void TestDefaultLevelDependsOnVIP()
    {
        Assert.Equal(QualityLevel.Lossless, SongQualityPolicy.DefaultLevel(true));
        Assert.Equal(QualityLevel.ExHigh, SongQualityPolicy.DefaultLevel(false));
    }

    [Fact]
    public void TestAutoResolvesByVIPButExplicitChoiceIsUntouched()
    {
        Assert.Equal(QualityLevel.Lossless, SongQualityPolicy.EffectiveGlobalLevel(QualityLevel.Unknown, true));
        Assert.Equal(QualityLevel.ExHigh, SongQualityPolicy.EffectiveGlobalLevel(QualityLevel.Unknown, false));
        foreach (var explicitLevel in SongQualityPolicy.SelectableLevels)
        {
            Assert.Equal(explicitLevel, SongQualityPolicy.EffectiveGlobalLevel(explicitLevel, true));
            Assert.Equal(explicitLevel, SongQualityPolicy.EffectiveGlobalLevel(explicitLevel, false));
        }
    }

    [Fact]
    public void TestAutoSentinelIsTheUnknownPlaceholder()
    {
        Assert.Equal(QualityLevel.Unknown, SongQualityPolicy.AutoLevel);
        Assert.DoesNotContain(SongQualityPolicy.AutoLevel, SongQualityPolicy.SelectableLevels);
    }

    [Fact]
    public void TestGlobalLevelFollowsVIPChangeBackAndForth()
    {
        var preference = SongQualityPolicy.AutoLevel;
        Assert.Equal(QualityLevel.Lossless, SongQualityPolicy.EffectiveGlobalLevel(preference, true));
        Assert.Equal(QualityLevel.ExHigh, SongQualityPolicy.EffectiveGlobalLevel(preference, false));
    }

    [Fact]
    public void TestDerivedBitrateFromSizeAndDuration()
    {
        var kbps = SongQualityPolicy.DerivedBitrateKbps(3_900_000, 30);
        Assert.NotNull(kbps);
        Assert.InRange(kbps.Value, 1035, 1045);
    }

    [Fact]
    public void TestDerivedBitrateReturnsNilWhenDataInsufficient()
    {
        Assert.Null(SongQualityPolicy.DerivedBitrateKbps(null, 30));
        Assert.Null(SongQualityPolicy.DerivedBitrateKbps(0, 30));
        Assert.Null(SongQualityPolicy.DerivedBitrateKbps(3_900_000, 0));
        Assert.Null(SongQualityPolicy.DerivedBitrateKbps(3_900_000, 0.5));
    }

    [Fact]
    public void TestOverrideLifecycleOnController()
    {
        var player = PlayerController.Shared;
        var songID = "test-quality-override-" + Guid.NewGuid().ToString("N");
        var originalGlobal = player.PreferredQuality;
        try
        {
            player.SetRequestedQuality(QualityLevel.ExHigh);
            Assert.Null(player.QualityOverrideFor(songID));
            Assert.Equal(QualityLevel.ExHigh, player.EffectiveQualityFor(songID));

            player.SetQualityOverride(QualityLevel.Lossless, songID);
            Assert.Equal(QualityLevel.Lossless, player.QualityOverrideFor(songID));
            Assert.Equal(QualityLevel.Lossless, player.EffectiveQualityFor(songID));
            Assert.Contains(player.SongQualityOverrides, entry => entry.SongID == songID);

            player.SetQualityOverride(QualityLevel.HiRes, songID);
            Assert.Equal(QualityLevel.HiRes, player.QualityOverrideFor(songID));
            Assert.Equal(1, player.SongQualityOverrides.Count(entry => entry.SongID == songID));

            player.SetQualityOverride(QualityLevel.Unknown, songID);
            Assert.Null(player.QualityOverrideFor(songID));
            Assert.Equal(QualityLevel.ExHigh, player.EffectiveQualityFor(songID));

            player.SetQualityOverride(QualityLevel.Higher, songID);
            Assert.NotNull(player.QualityOverrideFor(songID));
            player.SetQualityOverride(null, songID);
            Assert.Null(player.QualityOverrideFor(songID));
            Assert.DoesNotContain(player.SongQualityOverrides, entry => entry.SongID == songID);
        }
        finally
        {
            player.SetQualityOverride(null, songID);
            player.SetRequestedQuality(originalGlobal);
        }
    }

    [Fact]
    public void TestGlobalChangeDoesNotOverrideSongOverride()
    {
        var player = PlayerController.Shared;
        var songID = "test-quality-global-" + Guid.NewGuid().ToString("N");
        var originalGlobal = player.PreferredQuality;
        try
        {
            player.SetQualityOverride(QualityLevel.Lossless, songID);
            player.SetRequestedQuality(QualityLevel.Standard);
            Assert.Equal(QualityLevel.Lossless, player.EffectiveQualityFor(songID));
            Assert.Equal(QualityLevel.Standard, player.EffectiveQualityFor("some-other-song"));
        }
        finally
        {
            player.SetQualityOverride(null, songID);
            player.SetRequestedQuality(originalGlobal);
        }
    }

    [Fact]
    public void TestOverrideTableIsTrimmed()
    {
        var player = PlayerController.Shared;
        var ids = Enumerable.Range(0, 260).Select(index => $"trim-{index}-{Guid.NewGuid():N}").ToList();
        try
        {
            foreach (var id in ids) player.SetQualityOverride(QualityLevel.Lossless, id);
            Assert.True(player.SongQualityOverrides.Count <= 200);
            Assert.NotNull(player.QualityOverrideFor(ids[259]));
            Assert.Null(player.QualityOverrideFor(ids[0]));
        }
        finally
        {
            foreach (var id in ids) player.SetQualityOverride(null, id);
        }
    }
}
