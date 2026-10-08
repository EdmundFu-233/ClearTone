namespace ClearTone.Core.Networking;

public enum SessionGuardDecision
{
    Ignore,
    ProbeSession,
    SessionAlive,
    SessionExpired,
}

public sealed class SessionExpiryGuard
{
    public const int SuspicionThreshold = 2;

    private int _suspicionCount;
    private bool _isProbing;

    public int SuspicionCount => _suspicionCount;
    public bool IsProbing => _isProbing;

    public SessionGuardDecision NoteRejection()
    {
        _suspicionCount++;
        if (_suspicionCount < SuspicionThreshold || _isProbing) return SessionGuardDecision.Ignore;
        _isProbing = true;
        return SessionGuardDecision.ProbeSession;
    }

    public SessionGuardDecision ResolveProbe(bool succeeded)
    {
        _isProbing = false;
        _suspicionCount = 0;
        return succeeded ? SessionGuardDecision.SessionAlive : SessionGuardDecision.SessionExpired;
    }

    public void Reset()
    {
        _suspicionCount = 0;
        _isProbing = false;
    }
}
