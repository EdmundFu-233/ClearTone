using ClearTone.Rendering;
using Xunit;

namespace ClearTone.Tests;

public class InFlightGateTests
{
    [Fact]
    public void TestAcquireSucceedsUntilFull()
    {
        var gate = new InFlightGate(2);
        Assert.True(gate.TryAcquire());
        Assert.True(gate.TryAcquire());
        Assert.False(gate.TryAcquire());
        Assert.True(gate.IsFull);
    }

    [Fact]
    public void TestReleaseUnblocksSubsequentFrames()
    {
        var gate = new InFlightGate(2);
        gate.TryAcquire();
        gate.TryAcquire();
        Assert.False(gate.TryAcquire());

        gate.Release();
        Assert.False(gate.IsFull);
        Assert.True(gate.TryAcquire());
    }

    [Fact]
    public void TestReleaseNeverGoesNegative()
    {
        var gate = new InFlightGate(2);
        gate.Release();
        gate.Release();
        Assert.Equal(0, gate.InFlight);
        Assert.True(gate.TryAcquire());
        Assert.Equal(1, gate.InFlight);
    }

    [Fact]
    public void TestConcurrentAcquireNeverExceedsMax()
    {
        var gate = new InFlightGate(2);

        Parallel.For(0, 16, _ =>
        {
            for (var iteration = 0; iteration < 500; iteration++)
            {
                gate.TryAcquire();
            }
        });

        Assert.Equal(gate.MaxInFlight, gate.InFlight);
        gate.Release();
        gate.Release();
        Assert.Equal(0, gate.InFlight);
        Assert.True(gate.TryAcquire());
    }

    [Fact]
    public void TestBalancedTrafficAlwaysReturnsToZero()
    {
        var gate = new InFlightGate(4);

        Parallel.For(0, 8, _ =>
        {
            for (var iteration = 0; iteration < 1_000; iteration++)
            {
                if (gate.TryAcquire()) gate.Release();
            }
        });

        Assert.Equal(0, gate.InFlight);
        Assert.True(gate.TryAcquire());
    }
}
