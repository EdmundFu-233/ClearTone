#pragma once

#include <QHash>

#include <functional>
#include <utility>

namespace ct {

// 多播事件：视图/托盘/媒体集成各自 subscribe，互不覆盖。
// 旧式单回调写法 `if (event) event(args...)` 仍然可用（单槽 + 多播列表）。
template <typename... Args>
class Event {
public:
    using Handler = std::function<void(Args...)>;

    int subscribe(Handler handler)
    {
        const int id = ++m_nextId;
        m_handlers.insert(id, std::move(handler));
        return id;
    }

    void unsubscribe(int id) { m_handlers.remove(id); }

    void setSingle(Handler handler) { m_single = std::move(handler); }

    void clearSingle() { m_single = nullptr; }

    bool hasHandlers() const { return m_single != nullptr || !m_handlers.isEmpty(); }

    explicit operator bool() const { return hasHandlers(); }

    void operator()(Args... args) const { publish(std::forward<Args>(args)...); }

    void publish(Args... args) const
    {
        if (m_single) m_single(args...);
        const auto handlers = m_handlers;
        for (const auto& handler : handlers) handler(args...);
    }

private:
    mutable int m_nextId = 0;
    std::function<void(Args...)> m_single;
    QHash<int, Handler> m_handlers;
};

} // namespace ct
