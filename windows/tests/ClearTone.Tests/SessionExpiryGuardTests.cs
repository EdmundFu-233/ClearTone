using ClearTone.Core.Models;
using ClearTone.Core.Networking;
using Xunit;

namespace ClearTone.Tests;

public class SessionExpiryGuardTests
{
    [Fact]
    public void TestSingleRejectionNeverDeclaresExpiry()
    {
        var guard = new SessionExpiryGuard();
        Assert.Equal(SessionGuardDecision.Ignore, guard.NoteRejection());
        Assert.Equal(1, guard.SuspicionCount);
    }

    [Fact]
    public void TestSecondRejectionAsksForProbe()
    {
        var guard = new SessionExpiryGuard();
        guard.NoteRejection();
        Assert.Equal(SessionGuardDecision.ProbeSession, guard.NoteRejection());
        Assert.True(guard.IsProbing);
    }

    [Fact]
    public void TestProbeSucceedingKeepsSessionAlive()
    {
        var guard = new SessionExpiryGuard();
        guard.NoteRejection();
        guard.NoteRejection();
        Assert.Equal(SessionGuardDecision.SessionAlive, guard.ResolveProbe(true));
    }

    [Fact]
    public void TestProbeFailingDeclaresExpiry()
    {
        var guard = new SessionExpiryGuard();
        guard.NoteRejection();
        guard.NoteRejection();
        Assert.Equal(SessionGuardDecision.SessionExpired, guard.ResolveProbe(false));
    }

    [Fact]
    public void TestProbeResetsSuspicionCount()
    {
        var guard = new SessionExpiryGuard();
        guard.NoteRejection();
        guard.NoteRejection();
        guard.ResolveProbe(true);
        Assert.Equal(0, guard.SuspicionCount);
        Assert.False(guard.IsProbing);
        Assert.Equal(SessionGuardDecision.Ignore, guard.NoteRejection());
    }

    [Fact]
    public void TestResetClearsSuspicionAndProbing()
    {
        var guard = new SessionExpiryGuard();
        guard.NoteRejection();
        guard.NoteRejection();
        Assert.True(guard.IsProbing);
        guard.Reset();
        Assert.Equal(0, guard.SuspicionCount);
        Assert.False(guard.IsProbing);
    }

    [Fact]
    public void TestProbeInFlightSuppressesFurtherProbes()
    {
        var guard = new SessionExpiryGuard();
        guard.NoteRejection();
        guard.NoteRejection();
        Assert.True(guard.IsProbing);
        Assert.Equal(SessionGuardDecision.Ignore, guard.NoteRejection());
        Assert.Equal(3, guard.SuspicionCount);
    }

    [Fact]
    public void TestThresholdIsTwo()
    {
        Assert.Equal(2, SessionExpiryGuard.SuspicionThreshold);
        Assert.True(SessionExpiryGuard.SuspicionThreshold > 1);
    }

    [Fact]
    public void TestHelperAuthFailureIsDistinctFromSessionExpiry()
    {
        Assert.NotEqual(MusicException.SessionExpired(), MusicException.HelperAuthFailed());
        Assert.False(MusicException.HelperAuthFailed().IsRetryable);
    }

    [Fact]
    public void TestRiskRejectionMessageDoesNotTellUserToRelogin()
    {
        var error = MusicException.ApiError(301, "网易云拒绝了这次请求（可能被风控），稍后重试");
        Assert.DoesNotContain("重新登录", error.UserFacingMessage);
        Assert.Contains("风控", error.UserFacingMessage);
    }
}
