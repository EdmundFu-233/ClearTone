#pragma once

#include <atomic>

namespace ct {

class InFlightGate {
public:
    explicit InFlightGate(int maxInFlight)
        : m_maxInFlight(maxInFlight)
    {
    }

    int maxInFlight() const { return m_maxInFlight; }
    bool isFull() const { return inFlight() >= m_maxInFlight; }
    int inFlight() const { return m_count.load(std::memory_order_relaxed); }

    bool tryAcquire()
    {
        int current = m_count.load(std::memory_order_relaxed);
        while (current < m_maxInFlight) {
            if (m_count.compare_exchange_weak(
                    current, current + 1, std::memory_order_relaxed)) {
                return true;
            }
        }
        return false;
    }

    void release()
    {
        int current = m_count.load(std::memory_order_relaxed);
        while (current > 0) {
            if (m_count.compare_exchange_weak(
                    current, current - 1, std::memory_order_relaxed)) {
                return;
            }
        }
    }

private:
    int m_maxInFlight;
    std::atomic<int> m_count{0};
};

} // namespace ct
