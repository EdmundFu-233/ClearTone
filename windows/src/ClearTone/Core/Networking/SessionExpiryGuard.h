#pragma once

namespace ct {

enum class SessionGuardDecision {
    Ignore,
    ProbeSession,
    SessionAlive,
    SessionExpired,
};

class SessionExpiryGuard {
public:
    static constexpr int suspicionThreshold = 2;

    int suspicionCount() const { return m_suspicionCount; }
    bool isProbing() const { return m_isProbing; }

    SessionGuardDecision noteRejection()
    {
        m_suspicionCount++;
        if (m_suspicionCount < suspicionThreshold || m_isProbing) return SessionGuardDecision::Ignore;
        m_isProbing = true;
        return SessionGuardDecision::ProbeSession;
    }

    SessionGuardDecision resolveProbe(bool succeeded)
    {
        m_isProbing = false;
        m_suspicionCount = 0;
        return succeeded ? SessionGuardDecision::SessionAlive : SessionGuardDecision::SessionExpired;
    }

    void reset()
    {
        m_suspicionCount = 0;
        m_isProbing = false;
    }

private:
    int m_suspicionCount = 0;
    bool m_isProbing = false;
};

} // namespace ct
