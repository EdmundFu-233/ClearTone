namespace ClearTone.Rendering;

public sealed class InFlightGate
{
    private readonly object _gate = new();
    private int _count;

    public int MaxInFlight { get; }

    public InFlightGate(int maxInFlight)
    {
        MaxInFlight = maxInFlight;
    }

    public bool IsFull
    {
        get
        {
            lock (_gate)
            {
                return _count >= MaxInFlight;
            }
        }
    }

    public bool TryAcquire()
    {
        lock (_gate)
        {
            if (_count >= MaxInFlight) return false;
            _count += 1;
            return true;
        }
    }

    public void Release()
    {
        lock (_gate)
        {
            _count = Math.Max(0, _count - 1);
        }
    }

    public int InFlight
    {
        get
        {
            lock (_gate)
            {
                return _count;
            }
        }
    }
}
